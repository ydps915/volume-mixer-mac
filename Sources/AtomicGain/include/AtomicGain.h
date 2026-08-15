#ifndef VOLUME_MIXER_ATOMIC_GAIN_H
#define VOLUME_MIXER_ATOMIC_GAIN_H

typedef struct VMAtomicGain VMAtomicGain;

VMAtomicGain *VMAtomicGainCreate(float initialValue);
void VMAtomicGainStore(VMAtomicGain *gain, float value);
float VMAtomicGainLoad(const VMAtomicGain *gain);

/// Atomically raises the stored value to `value` when `value` is larger.
/// Lock-free, so it is safe to call from the audio render thread.
void VMAtomicGainStoreMax(VMAtomicGain *gain, float value);

/// Atomically reads the stored value and replaces it with `newValue`.
/// Lets the meter drain a peak without racing the render thread.
float VMAtomicGainExchange(VMAtomicGain *gain, float newValue);

void VMAtomicGainDestroy(VMAtomicGain *gain);

#endif
