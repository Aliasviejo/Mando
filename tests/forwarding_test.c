// Simulates Mando's clients and a target device whose clock is off by some
// ppm, in virtual time, and checks that after settling the target plays every
// frame exactly once: no silence, no jump.
//
//   clang -O2 -framework CoreFoundation -framework CoreAudio tests/forwarding_test.c -o build/forwarding_test && build/forwarding_test
//
// SPDX-License-Identifier: MIT

#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t gNow = 1000000000ull;
static uint64_t TestNow(void) { return gNow; }
#define mach_absolute_time TestNow
#include "../Driver/MandoDriver.c"
#undef mach_absolute_time

enum { kBlock = 512, kWarmupSeconds = 60, kRunSeconds = 600 };

// Returns the glitches (silence or discontinuity) heard after the warm-up.
static int Run(double ppm, int *warmupGlitches) {
    gNow = 1000000000ull;
    gSampleRate = 48000.0;
    UpdateTicksPerFrame();
    atomic_store(&gVolumeScalar, 1.0f);
    atomic_store(&gRateTrim, 0.0f);
    atomic_store(&gWriteHead, kNoWrite);
    gIORunning = 0;
    gReaderSynced = false;
    gReadMargin = kMarginStep;
    Mando_StartIO(gDriverRef, kObjDevice, 0);

    const double tick = gHostTicksPerFrame;
    const double targetBlock = kBlock * tick * (1.0 + ppm * 1e-6);
    double nextRead = (double)gNow + targetBlock;
    SInt64 written = 0;
    Float32 in[kBlock * 2], out[kBlock * 2];
    AudioBufferList abl = { 1, { { 2, sizeof(out), out } } };
    int glitches = 0, last = -1;
    *warmupGlitches = 0;

    for (SInt64 step = 0; step < (SInt64)kRunSeconds * 48000 / 32; step++) {
        gNow += (uint64_t)(32 * tick);
        Boolean warm = step > (SInt64)kWarmupSeconds * 48000 / 32;

        // The HAL: asks for the clock and mixes each block just before it is due.
        Float64 zeroSample; UInt64 zeroHost, seed;
        Mando_GetZeroTimeStamp(gDriverRef, kObjDevice, 0, &zeroSample, &zeroHost, &seed);
        Float64 position = zeroSample + ((Float64)gNow - (Float64)zeroHost) / (gPeriodTicks / kRingFrames);
        while (position >= (Float64)(written - 64)) {
            for (int i = 0; i < kBlock; i++) in[i * 2] = in[i * 2 + 1] = (Float32)((written + i) & 0xFFFF);
            AudioServerPlugInIOCycleInfo info = { 0 };
            info.mOutputTime.mSampleTime = (Float64)written;
            Mando_DoIOOperation(gDriverRef, kObjDevice, kObjStreamOut, 0, kAudioServerPlugInIOOperationWriteMix, kBlock, &info, in, NULL);
            written += kBlock;
        }

        // The target: one block per period of its own clock, due one block from now.
        while ((double)gNow >= nextRead) {
            AudioTimeStamp now = { 0 }, due = { 0 };
            now.mHostTime = gNow; now.mFlags = kAudioTimeStampHostTimeValid;
            due.mHostTime = gNow + (UInt64)targetBlock; due.mFlags = kAudioTimeStampHostTimeValid;
            SInt64 cursor = gReadCursor;
            ForwardIOProc(1, &now, NULL, &now, &abl, &due, NULL);
            Boolean played = (gReadCursor != cursor);
            int first = (int)out[0];
            Boolean ok = played && (last < 0 || first == ((last + 1) & 0xFFFF)) && out[1] == out[0];
            for (int i = 1; ok && i < kBlock; i++) ok = ((int)out[i * 2] == ((first + i) & 0xFFFF));
            if (!ok) { if (warm) glitches++; else (*warmupGlitches)++; }
            last = played ? (int)out[(kBlock - 1) * 2] : -1;
            nextRead += targetBlock;
        }
    }
    printf("%+6.0f ppm: trim %+.0f ppm, margin %.0f frames, %d glitches while settling, %d after\n",
           ppm, atomic_load(&gRateTrim) * 1e6, gReadMargin, *warmupGlitches, glitches);
    Mando_StopIO(gDriverRef, kObjDevice, 0);
    return glitches;
}

int main(void) {
    gRing = calloc(kRingFrames, kBytesPerFrame);
    const double cases[] = { 0, 20, -20, 100, -100, 300, -300 };
    int failed = 0, warmup;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (Run(cases[i], &warmup) != 0) failed = 1;
        if (warmup > 20) failed = 1;
    }
    puts(failed ? "FAIL" : "PASS");
    return failed;
}
