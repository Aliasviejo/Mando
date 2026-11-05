// Real-time audio forwarding: Mando loopback input -> target (HDMI) output.
//
// Runs on a private aggregate device whose clock master is the target device
// and whose Mando sub-device has drift compensation, so CoreAudio keeps the
// two clocks in sync for us. The IO proc only copies samples.
//
// SPDX-License-Identifier: MIT

#include "Mando-Bridging-Header.h"
#include <stdlib.h>
#include <string.h>

struct MandoRouter {
    AudioObjectID aggregate;
    AudioDeviceIOProcID procID;
    UInt32 targetInputBuffers;   // aggregate input buffers belonging to the target (skipped)
    UInt32 targetOutputBuffers;  // aggregate output buffers belonging to the target (written)
};

static OSStatus RouterIOProc(AudioObjectID device, const AudioTimeStamp *now,
                             const AudioBufferList *input, const AudioTimeStamp *inputTime,
                             AudioBufferList *output, const AudioTimeStamp *outputTime, void *ctx) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    MandoRouter *r = ctx;
    if (!output) return 0;

    // Source: Mando's loopback input, interleaved stereo float32.
    const Float32 *src = NULL;
    UInt32 srcChannels = 0, srcFrames = 0;
    if (input && input->mNumberBuffers > r->targetInputBuffers) {
        const AudioBuffer *b = &input->mBuffers[r->targetInputBuffers];
        if (b->mData && b->mNumberChannels > 0) {
            src = b->mData;
            srcChannels = b->mNumberChannels;
            srcFrames = b->mDataByteSize / (srcChannels * sizeof(Float32));
        }
    }

    // Destination: target output buffers. Map L/R onto the first two channels
    // across however the device lays out its buffers; silence everything else.
    UInt32 globalChannel = 0;
    for (UInt32 bi = 0; bi < output->mNumberBuffers; bi++) {
        AudioBuffer *b = &output->mBuffers[bi];
        if (!b->mData) continue;
        if (bi >= r->targetOutputBuffers || b->mNumberChannels == 0) {
            memset(b->mData, 0, b->mDataByteSize); // Mando's own output in the aggregate
            continue;
        }
        UInt32 ch = b->mNumberChannels;
        UInt32 frames = b->mDataByteSize / (ch * sizeof(Float32));
        Float32 *dst = b->mData;
        for (UInt32 c = 0; c < ch; c++, globalChannel++) {
            UInt32 sc = globalChannel; // 0 = L, 1 = R
            for (UInt32 f = 0; f < frames; f++) {
                Float32 v = 0;
                if (src && sc < 2 && f < srcFrames) v = src[f * srcChannels + (sc < srcChannels ? sc : 0)];
                dst[f * ch + c] = v;
            }
        }
    }
    return 0;
}

MandoRouter *MandoRouterStart(AudioObjectID aggregate, UInt32 targetInputBuffers, UInt32 targetOutputBuffers, OSStatus *outError) {
    MandoRouter *r = calloc(1, sizeof(*r));
    if (!r) { if (outError) *outError = -1; return NULL; }
    r->aggregate = aggregate;
    r->targetInputBuffers = targetInputBuffers;
    r->targetOutputBuffers = targetOutputBuffers;
    OSStatus err = AudioDeviceCreateIOProcID(aggregate, RouterIOProc, r, &r->procID);
    if (!err) err = AudioDeviceStart(aggregate, r->procID);
    if (err) {
        if (r->procID) AudioDeviceDestroyIOProcID(aggregate, r->procID);
        free(r);
        if (outError) *outError = err;
        return NULL;
    }
    if (outError) *outError = 0;
    return r;
}

void MandoRouterStop(MandoRouter *r) {
    if (!r) return;
    AudioDeviceStop(r->aggregate, r->procID);
    AudioDeviceDestroyIOProcID(r->aggregate, r->procID);
    free(r);
}
