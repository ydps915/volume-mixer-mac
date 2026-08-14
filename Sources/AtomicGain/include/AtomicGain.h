#ifndef VOLUME_MIXER_ATOMIC_GAIN_H
#define VOLUME_MIXER_ATOMIC_GAIN_H

typedef struct VMAtomicGain VMAtomicGain;

VMAtomicGain *VMAtomicGainCreate(float initialValue);
void VMAtomicGainStore(VMAtomicGain *gain, float value);
float VMAtomicGainLoad(const VMAtomicGain *gain);
void VMAtomicGainDestroy(VMAtomicGain *gain);

#endif
