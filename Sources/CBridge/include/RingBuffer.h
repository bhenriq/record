// RingBuffer.h — lock-free SPSC ring buffer for audio samples
//
// Single producer (real-time IOProc thread), single consumer (write thread).
// Uses C11 atomics for lock-free operation.

#ifndef RINGBUFFER_H
#define RINGBUFFER_H

#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float           *buf;
    uint32_t         size;
    uint32_t         mask;
    _Atomic uint32_t write_pos;
    _Atomic uint32_t read_pos;
} RingBuffer;

void ring_init(RingBuffer *r, uint32_t minSize);
void ring_destroy(RingBuffer *r);
uint32_t ring_available(const RingBuffer *r);
void ring_write(RingBuffer *r, const float *samples, uint32_t count);
uint32_t ring_read(RingBuffer *r, float *samples, uint32_t maxCount);

#ifdef __cplusplus
}
#endif

#endif /* RINGBUFFER_H */
