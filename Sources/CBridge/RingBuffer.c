// RingBuffer.c — lock-free SPSC ring buffer implementation

#include "RingBuffer.h"

void ring_init(RingBuffer *r, uint32_t minSize) {
    uint32_t p2 = 1;
    while (p2 < minSize) p2 <<= 1;
    r->buf  = (float *)calloc(p2, sizeof(float));
    r->size = p2;
    r->mask = p2 - 1;
    atomic_init(&r->write_pos, 0);
    atomic_init(&r->read_pos, 0);
}

void ring_destroy(RingBuffer *r) {
    free(r->buf);
    r->buf = NULL;
    r->size = 0;
    r->mask = 0;
    atomic_store_explicit(&r->write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&r->read_pos, 0, memory_order_relaxed);
}

uint32_t ring_available(const RingBuffer *r) {
    uint32_t wp = atomic_load_explicit(&r->write_pos, memory_order_acquire);
    uint32_t rp = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
    return wp - rp;
}

void ring_write(RingBuffer *r, const float *samples, uint32_t count) {
    uint32_t wp = atomic_load_explicit(&r->write_pos, memory_order_relaxed);
    uint32_t rp = atomic_load_explicit(&r->read_pos, memory_order_acquire);
    uint32_t filled = wp - rp;
    uint32_t avail  = r->size - filled;
    uint32_t n      = (count < avail) ? count : avail;

    for (uint32_t i = 0; i < n; i++)
        r->buf[(wp + i) & r->mask] = samples[i];

    atomic_store_explicit(&r->write_pos, wp + n, memory_order_release);
}

uint32_t ring_read(RingBuffer *r, float *samples, uint32_t maxCount) {
    uint32_t rp = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
    uint32_t wp = atomic_load_explicit(&r->write_pos, memory_order_acquire);
    uint32_t n  = (maxCount < (wp - rp)) ? maxCount : (wp - rp);

    for (uint32_t i = 0; i < n; i++)
        samples[i] = r->buf[(rp + i) & r->mask];

    atomic_store_explicit(&r->read_pos, rp + n, memory_order_release);
    return n;
}
