/*
* Copyright (c) 2018, NVIDIA CORPORATION.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

#include "gpuinflate.h"

#if (__CUDACC_VER_MAJOR__ >= 9)
#define SHFL0(v)    __shfl_sync(~0, v, 0)
#define SHFL(v, t)  __shfl_sync(~0, v, t)
#define SYNCWARP()  __syncwarp()
#define BALLOT(v)   __ballot_sync(~0, v)
#else
#define SHFL0(v)    __shfl(v, 0)
#define SHFL(v, t)  __shfl(v, t)
#define SYNCWARP()
#define BALLOT(v)   __ballot(v)
#endif

#if (__CUDA_ARCH__ >= 700)
#define NANOSLEEP(d)  __nanosleep(d)
#else
#define NANOSLEEP(d)  clock()
#endif

#define LOG2_BATCH_SIZE     4
#define BATCH_SIZE          (1 << LOG2_BATCH_SIZE)
#define LOG2_BATCH_COUNT    2
#define BATCH_COUNT         (1 << LOG2_BATCH_COUNT)

struct unsnap_batch_s
{
    int32_t len;        // 1..64 = Number of bytes to copy at given offset, 65..97 = Number of literal bytes
    uint32_t offset;    // copy distance or absolute literal offset in byte stream
};


struct unsnap_queue_s
{
    int32_t batch_len[BATCH_COUNT];     // Length of each batch - <0:end, 0:not ready, >0:symbol count
    unsnap_batch_s batch[BATCH_COUNT * BATCH_SIZE];
};


struct unsnap_state_s
{
    const uint8_t *base;
    const uint8_t *end;
    uint32_t uncompressed_size;
    uint32_t bytes_left;
    int32_t error;
    volatile unsnap_queue_s q;
    gpu_inflate_input_s in;
};


__device__ uint32_t snappy_decode_symbols(unsnap_state_s *s)
{
    const uint8_t *bs = s->base;
    uint32_t cur = 0;
    uint32_t end = (uint32_t)min((size_t)(s->end - bs), (size_t)0xffffffffu);
    uint32_t bytes_left = s->uncompressed_size;
    uint32_t is_literal = 0;
    uint32_t dst_pos = 0;
    int32_t batch = 0;
    uint32_t lit_len = 0;
    for (;;)
    {
        volatile unsnap_batch_s *b = &s->q.batch[batch * BATCH_SIZE];
        int32_t batch_len = 0;

        while (bytes_left > 0)
        {
            uint32_t blen;

            if (lit_len == 0)
            {
                if (cur >= end)
                    break;
                blen = bs[cur++];
                if (blen & 2)
                {
                    uint32_t offset;
                    // xxxxxx1x: copy with 6-bit length, 2-byte or 4-byte offset
                    if (2 * (1 + (blen & 1)) > end - cur)
                        break;
                    offset = bs[cur] + (bs[cur+1] << 8);
                    cur += 2;
                    if (blen & 1) // 4-byte offset
                    {
                        offset |= (bs[cur] << 16) | (bs[cur+1] << 24);
                        cur += 2;
                    }
                    blen = (blen >> 2) + 1;
                    is_literal = 0;
                    if (offset - 1u >= dst_pos)
                        break;
                    b->offset = offset;
                }
                else
                {
                    if (blen & 1)
                    {
                        uint32_t offset;
                        // xxxxxx01.oooooooo: copy with 3-bit length, 11-bit offset
                        if (cur >= end)
                            break;
                        offset = ((blen & 0xe0) << 3) | bs[cur++];
                        blen = ((blen >> 2) & 7) + 4;
                        is_literal = 0;
                        if (offset - 1u >= dst_pos)
                            break;
                        b->offset = offset;
                    }
                    else
                    {
                        // xxxxxx00: literal
                        blen >>= 2;
                        if (blen >= 60)
                        {
                            uint32_t num_bytes = blen - 59;
                            if (num_bytes >= end - cur)
                                break;
                            blen = bs[cur++];
                            if (num_bytes > 1)
                            {
                                blen |= bs[cur++] << 8;
                                if (num_bytes > 2)
                                {
                                    blen |= bs[cur++] << 16;
                                    if (num_bytes > 3)
                                    {
                                        blen |= bs[cur++] << 24;
                                        if (blen >= end)
                                            break;
                                    }
                                }
                            }
                        }
                        blen += 1;
                        if (blen > end - cur)
                            break;
                        lit_len = blen;
                    }
                }
            }
            if (lit_len != 0)
            {
                blen = min(lit_len, 32);
                lit_len -= blen;
                is_literal = 64;
                b->offset = cur;
                cur += blen;
            }
            dst_pos += blen;
            if (bytes_left < blen)
            {
                break;
            }
            bytes_left -= blen;
            b->len = blen + is_literal;
            b++;
            if (++batch_len == BATCH_SIZE)
                break;
        }
        if (batch_len != 0)
        {
            s->q.batch_len[batch] = batch_len;
            batch = (batch + 1) & (BATCH_COUNT - 1);
        }
        while (s->q.batch_len[batch] != 0)
        {
            NANOSLEEP(100);
        }
        if (batch_len != BATCH_SIZE || bytes_left == 0)
        {
            break;
        }
    }
    s->q.batch_len[batch] = -1;
    return bytes_left;
}


// WARP1: process symbols and output uncompressed stream
// NOTE: No error checks at this stage (WARP0 responsible for not sending offsets and lengths that would result in out-of-bounds accesses)
__device__ void snappy_process_symbols(unsnap_state_s *s, int t)
{
    const uint8_t *literal_base = s->base;
    uint8_t *out = reinterpret_cast<uint8_t *>(s->in.dstDevice);
    int batch = 0;

    do
    {
        volatile unsnap_batch_s *b = &s->q.batch[batch * BATCH_SIZE];
        int32_t batch_len;

        if (t == 0)
        {
            while ((batch_len = s->q.batch_len[batch]) == 0)
            {
                NANOSLEEP(100);
            }
        }
        else
        {
            batch_len = 0;
        }
        batch_len = SHFL0(batch_len);
        if (batch_len <= 0)
        {
            break;
        }
        for (int i = 0; i < batch_len; i++, b++)
        {
            int blen = b->len;
            uint32_t dist = b->offset;
            if (blen <= 64)
            {
                // Copy
                if (t < blen)
                {
                    uint32_t pos = t;
                    const uint8_t *src = out + ((pos >= dist) ? (pos % dist) : pos) - dist;
                    out[t] = *src;
                }
                SYNCWARP();
                if (32 + t < blen)
                {
                    uint32_t pos = 32 + t;
                    const uint8_t *src = out + ((pos >= dist) ? (pos % dist) : pos) - dist;
                    out[32 + t] = *src;
                }
                SYNCWARP();
            }
            else
            {
                // Literal
                blen -= 64;
                if (t < blen)
                {
                    out[t] = literal_base[dist + t];
                }
            }
            out += blen;
        }
        SYNCWARP();
        if (t == 0)
        {
            s->q.batch_len[batch] = 0;
        }
        batch = (batch + 1) & (BATCH_COUNT - 1);
    } while (1);
}


// blockDim {128,1,1}
extern "C" __global__ void __launch_bounds__(128)
unsnap_kernel(gpu_inflate_input_s *inputs, gpu_inflate_status_s *outputs, int count)
{
    __shared__ __align__(16) unsnap_state_s state_g;

    int t = threadIdx.x;
    unsnap_state_s *s = &state_g;
    int strm_id = blockIdx.x;

    if (strm_id < count && t < sizeof(gpu_inflate_input_s) / sizeof(uint32_t))
    {
        reinterpret_cast<uint32_t *>(&s->in)[t] = reinterpret_cast<const uint32_t *>(&inputs[strm_id])[t];
        __threadfence_block();
    }
    if (t < BATCH_COUNT)
    {
        s->q.batch_len[t] = 0;
    }
    __syncthreads();
    if (!t && strm_id < count)
    {
        const uint8_t *cur = reinterpret_cast<const uint8_t *>(s->in.srcDevice);
        const uint8_t *end = cur + s->in.srcSize;
        s->error = 0;
        if (cur < end)
        {
            // Read uncompressed size (varint), limited to 32-bit
            uint32_t uncompressed_size = *cur++;
            if (uncompressed_size > 0x7f)
            {
                uint32_t c = (cur < end) ? *cur++ : 0;
                uncompressed_size = (uncompressed_size & 0x7f) | (c << 7);
                if (uncompressed_size >= (0x80 << 7))
                {
                    c = (cur < end) ? *cur++ : 0;
                    uncompressed_size = (uncompressed_size & ((0x7f << 7) | 0x7f)) | (c << 14);
                    if (uncompressed_size >= (0x80 << 14))
                    {
                        c = (cur < end) ? *cur++ : 0;
                        uncompressed_size = (uncompressed_size & ((0x7f << 14) | (0x7f << 7) | 0x7f)) | (c << 21);
                        if (uncompressed_size >= (0x80 << 21))
                        {
                            c = (cur < end) ? *cur++ : 0;
                            if (c <= 0xf)
                                uncompressed_size = (uncompressed_size & ((0x7f << 21) | (0x7f << 14) | (0x7f << 7) | 0x7f)) | (c << 28);
                            else
                                s->error = -1;
                        }
                    }
                }
            }
            s->uncompressed_size = uncompressed_size;
            s->bytes_left = uncompressed_size;
            s->base = cur;
            s->end = end;
            if ((cur >= end && uncompressed_size != 0) || (uncompressed_size > s->in.dstSize))
            {
                s->error = -1;
            }
        }
        else
        {
            s->error = -1;
        }
    }
    __syncthreads();
    if (strm_id < count && !s->error)
    {
        if (t < 32)
        {
            // WARP0: decode lengths and offsets
            if (!t)
            {
                s->bytes_left = snappy_decode_symbols(s);
                if (s->bytes_left != 0)
                {
                    s->error = -2;
                }
            }
        }
        else if (t < 64)
        {
            // WARP1: LZ77
            snappy_process_symbols(s, t & 0x1f);
        }
    }
    __syncthreads();
    if (!t && strm_id < count)
    {
        outputs[strm_id].bytes_written = s->uncompressed_size - s->bytes_left;
        outputs[strm_id].status = s->error;
        outputs[strm_id].reserved = 0;
    }
}


cudaError_t __host__ gpu_unsnap(gpu_inflate_input_s *inputs, gpu_inflate_status_s *outputs, int count, cudaStream_t stream)
{
    uint32_t count32 = (count > 0) ? count : 0;
    dim3 dim_block(128, 1);     // 4 warps per stream, 1 stream per block
    dim3 dim_grid(count32, 1);  // TODO: Check max grid dimensions vs max expected count

    unsnap_kernel << < dim_grid, dim_block, 0, stream >> >(inputs, outputs, count32);

    return cudaSuccess;
}

