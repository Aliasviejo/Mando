// SPDX-License-Identifier: MIT
#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/CoreAudio.h>
#include <IOKit/IOKitLib.h>
#include <stdbool.h>

// Private IOKit symbols used for DDC/CI on Apple Silicon (same ones
// MonitorControl, m1ddc and BetterDisplay rely on).
typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);

// Router.c — real-time copy from the Mando loopback to the HDMI device.
typedef struct MandoRouter MandoRouter;
MandoRouter *MandoRouterStart(AudioObjectID aggregate, UInt32 targetInputBuffers, UInt32 targetOutputBuffers, OSStatus *outError);
void MandoRouterStop(MandoRouter *router);

// OSD.m — native macOS on-screen display (private OSD.framework).
bool MandoShowOSD(uint32_t displayID, long long image, uint32_t filledChiclets, uint32_t totalChiclets);
