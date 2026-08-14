#include "AtomicGain.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct VMAtomicGain {
    _Atomic uint32_t bits;
};

static uint32_t bits_from_float(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float float_from_bits(uint32_t bits) {
    float value = 0;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

VMAtomicGain *VMAtomicGainCreate(float initialValue) {
    VMAtomicGain *gain = calloc(1, sizeof(VMAtomicGain));
    if (gain == NULL) {
        return NULL;
    }
    atomic_init(&gain->bits, bits_from_float(initialValue));
    return gain;
}

void VMAtomicGainStore(VMAtomicGain *gain, float value) {
    if (gain == NULL) {
        return;
    }
    atomic_store_explicit(&gain->bits, bits_from_float(value), memory_order_relaxed);
}

float VMAtomicGainLoad(const VMAtomicGain *gain) {
    if (gain == NULL) {
        return 1.0f;
    }
    return float_from_bits(atomic_load_explicit(&gain->bits, memory_order_relaxed));
}

void VMAtomicGainDestroy(VMAtomicGain *gain) {
    free(gain);
}
