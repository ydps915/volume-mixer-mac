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

/// A free-running counter the audio render thread can bump so another thread can
/// tell whether rendering is still happening.
typedef struct VMAtomicCounter VMAtomicCounter;

VMAtomicCounter *VMAtomicCounterCreate(void);
void VMAtomicCounterIncrement(VMAtomicCounter *counter);
unsigned long long VMAtomicCounterLoad(const VMAtomicCounter *counter);
void VMAtomicCounterDestroy(VMAtomicCounter *counter);

#endif
