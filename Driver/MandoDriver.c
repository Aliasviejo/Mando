// Mando — virtual audio output with a real volume control.
//
// macOS gives HDMI / DisplayPort outputs a fixed volume, so the keyboard
// volume keys do nothing. This AudioServerPlugIn publishes an output device
// ("Mando") that HAS a volume and mute control. Whatever apps play into it is
// scaled by that volume and played on the real device (the "target"), which
// the Mando app chooses through a custom property of the device.
//
// The driver plays on the target as an ordinary CoreAudio client. Mando has no
// input side, so nothing ever records: no microphone permission, no indicator.
//
// Objects:  1 plug-in, 2 device, 3 output stream, 4 volume control, 5 mute control.
//
// SPDX-License-Identifier: MIT

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#pragma mark - Constants

enum {
    kObjPlugIn = kAudioObjectPlugInObject, // 1
    kObjDevice = 2,
    kObjStreamOut = 3,
    kObjVolume = 4,
    kObjMute = 5,
};

// Custom device property (CFString). Write: UID of the device to play on, ""
// for none. Read: UID of the device actually being played on, "" if none.
// Every write is answered with a change notification once it has taken effect.
enum { kMandoPropertyTarget = 'mtgt' };

#define kManufacturer       "Aliasviejo"
#define kDeviceName         "Mando"
#define kDeviceUID          "MandoDevice_UID"
#define kDeviceModelUID     "MandoDevice_ModelUID"
#define kChannels           2
#define kBitsPerChannel     32
#define kBytesPerFrame      (kChannels * sizeof(Float32))
#define kRingFrames         16384           // power of two; also the zero-timestamp period
#define kMaxUIDLength       256
#define kNoWrite            INT64_MIN       // write head while no client is playing
#define kMarginStep         256             // frames kept between the reader and the write head
#define kMaxMargin          4096
#define kResyncFrames       1024.0          // reader error beyond which it repositions
#define kMaxRateTrim        1e-3f
#define kMinDB              (-96.0f)
#define kStorageVolumeKey   CFSTR("volume")
#define kStorageMuteKey     CFSTR("mute")

static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kNumSampleRates (sizeof(kSampleRates) / sizeof(kSampleRates[0]))

#pragma mark - State

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

static Float64 gSampleRate = 48000.0;
static Float64 gPendingSampleRate = 48000.0;
static UInt32 gIORunning = 0;

// Mando's clock: the zero timestamp advances one period at a time, and each
// period is stretched by gRateTrim so Mando runs at the target's real speed.
static os_unfair_lock gClockLock = OS_UNFAIR_LOCK_INIT;
static Float64 gHostTicksPerFrame = 0;  // nominal
static Float64 gZeroHost = 0;
static SInt64 gZeroSample = 0;
static Float64 gPeriodTicks = 0;
static _Atomic float gRateTrim = 0.0f;

static _Atomic float gVolumeScalar = 0.5f;
static _Atomic int gMuted = 0;

static Float32 *gRing = NULL;                 // kRingFrames * kChannels, by Mando sample time
static _Atomic SInt64 gWriteHead = kNoWrite;   // sample time just past the last frame written

// Forwarding to the target. Touched only on gForwardQueue, except gTargetUID (gMutex).
static dispatch_queue_t gForwardQueue = NULL;
static AudioObjectID gTargetDevice = kAudioObjectUnknown;
static AudioDeviceIOProcID gTargetProc = NULL;
static CFStringRef gTargetUID = NULL;

// Reader state: the target's IO thread only (reset while its IO proc is stopped).
static Boolean gReaderSynced = false;
static SInt64 gReadCursor = 0;
static Float64 gReadLead = 0;
static Float64 gReadMargin = kMarginStep;
static Float64 gReadErrAvg = 0;

#pragma mark - Helpers

static inline float ScalarToGain(float s) {
    if (s <= 0.0f) return 0.0f;
    if (s >= 1.0f) return 1.0f;
    return s * s; // gentle, perceptually reasonable curve
}

static inline Float32 ScalarToDB(Float32 s) {
    float g = ScalarToGain(s);
    if (g <= 0.0f) return kMinDB;
    Float32 db = 20.0f * log10f(g);
    return db < kMinDB ? kMinDB : db;
}

static inline Float32 DBToScalar(Float32 db) {
    if (db <= kMinDB) return 0.0f;
    if (db >= 0.0f) return 1.0f;
    return sqrtf(powf(10.0f, db / 20.0f));
}

static void FillASBD(AudioStreamBasicDescription *d, Float64 rate) {
    memset(d, 0, sizeof(*d));
    d->mSampleRate = rate;
    d->mFormatID = kAudioFormatLinearPCM;
    d->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    d->mBytesPerPacket = kBytesPerFrame;
    d->mFramesPerPacket = 1;
    d->mBytesPerFrame = kBytesPerFrame;
    d->mChannelsPerFrame = kChannels;
    d->mBitsPerChannel = kBitsPerChannel;
}

static void NotifyChanged(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    if (!gHost) return;
    AudioObjectPropertyAddress a = { sel, scope, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, obj, 1, &a);
}

static void SaveSettings(void) {
    if (!gHost) return;
    float v = atomic_load(&gVolumeScalar);
    int m = atomic_load(&gMuted);
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberFloatType, &v);
    CFNumberRef nm = CFNumberCreate(NULL, kCFNumberIntType, &m);
    if (nv) { gHost->WriteToStorage(gHost, kStorageVolumeKey, nv); CFRelease(nv); }
    if (nm) { gHost->WriteToStorage(gHost, kStorageMuteKey, nm); CFRelease(nm); }
}

static void LoadSettings(void) {
    if (!gHost) return;
    CFPropertyListRef p = NULL;
    if (gHost->CopyFromStorage(gHost, kStorageVolumeKey, &p) == 0 && p) {
        if (CFGetTypeID(p) == CFNumberGetTypeID()) {
            float v; CFNumberGetValue((CFNumberRef)p, kCFNumberFloatType, &v);
            if (v >= 0.0f && v <= 1.0f) atomic_store(&gVolumeScalar, v);
        }
        CFRelease(p);
    }
    p = NULL;
    if (gHost->CopyFromStorage(gHost, kStorageMuteKey, &p) == 0 && p) {
        if (CFGetTypeID(p) == CFNumberGetTypeID()) {
            int m; CFNumberGetValue((CFNumberRef)p, kCFNumberIntType, &m);
            atomic_store(&gMuted, m ? 1 : 0);
        }
        CFRelease(p);
    }
}

#define CHECK_SIZE(n) do { if (inDataSize < (n)) return kAudioHardwareBadPropertySizeError; } while (0)

#pragma mark - Forward declarations

static HRESULT  Mando_QueryInterface(void*, REFIID, LPVOID*);
static ULONG    Mando_AddRef(void*);
static ULONG    Mando_Release(void*);
static OSStatus Mando_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus Mando_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus Mando_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus Mando_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus Mando_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus Mando_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus Mando_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  Mando_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus Mando_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus Mando_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus Mando_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus Mando_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus Mando_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus Mando_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus Mando_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus Mando_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus Mando_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus Mando_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus Mando_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Mando_QueryInterface, Mando_AddRef, Mando_Release,
    Mando_Initialize, Mando_CreateDevice, Mando_DestroyDevice,
    Mando_AddDeviceClient, Mando_RemoveDeviceClient,
    Mando_PerformDeviceConfigurationChange, Mando_AbortDeviceConfigurationChange,
    Mando_HasProperty, Mando_IsPropertySettable, Mando_GetPropertyDataSize,
    Mando_GetPropertyData, Mando_SetPropertyData,
    Mando_StartIO, Mando_StopIO, Mando_GetZeroTimeStamp,
    Mando_WillDoIOOperation, Mando_BeginIOOperation, Mando_DoIOOperation, Mando_EndIOOperation
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

#pragma mark - Factory

void *Mando_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

#pragma mark - IUnknown

static HRESULT Mando_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (!req) return kAudioHardwareIllegalOperationError;
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex); gRefCount++; pthread_mutex_unlock(&gMutex);
        *outInterface = gDriverRef;
        r = S_OK;
    }
    CFRelease(req);
    return r;
}

static ULONG Mando_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex); ULONG r = ++gRefCount; pthread_mutex_unlock(&gMutex);
    return r;
}

static ULONG Mando_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex); if (gRefCount > 0) gRefCount--; ULONG r = gRefCount; pthread_mutex_unlock(&gMutex);
    return r;
}

#pragma mark - Basic operations

static void UpdateTicksPerFrame(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    Float64 ticksPerSec = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    os_unfair_lock_lock(&gClockLock);
    gHostTicksPerFrame = ticksPerSec / gSampleRate;
    os_unfair_lock_unlock(&gClockLock);
}

static OSStatus Mando_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    LoadSettings();
    UpdateTicksPerFrame();
    if (!gRing) gRing = calloc(kRingFrames * kChannels, sizeof(Float32));
    if (!gForwardQueue) gForwardQueue = dispatch_queue_create("mando.forward", DISPATCH_QUEUE_SERIAL);
    return (gRing && gForwardQueue) ? 0 : kAudioHardwareUnspecifiedError;
}

static OSStatus Mando_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out) {
    (void)d; (void)desc; (void)ci; (void)out; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Mando_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Mando_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)ci; return (d == gDriverRef && id == kObjDevice) ? 0 : kAudioHardwareBadObjectError;
}
static OSStatus Mando_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *ci) {
    (void)ci; return (d == gDriverRef && id == kObjDevice) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Mando_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)action; (void)info;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    gSampleRate = gPendingSampleRate;
    UpdateTicksPerFrame();
    pthread_mutex_unlock(&gMutex);
    return 0;
}
static OSStatus Mando_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)d; (void)id; (void)action; (void)info; return 0;
}

#pragma mark - Forwarding to the target

// The target's IO proc: plays what Mando's clients wrote, a fixed distance
// behind Mando's clock. The two devices run on different clocks, so the error
// in that distance steers Mando's rate (gRateTrim) until they agree.
static OSStatus ForwardIOProc(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                              const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *ctx) {
    (void)device; (void)input; (void)inputTime; (void)ctx;
    if (!output || output->mNumberBuffers == 0) return 0;
    const AudioBuffer *first = &output->mBuffers[0];
    SInt64 frames = first->mNumberChannels ? first->mDataByteSize / (first->mNumberChannels * sizeof(Float32)) : 0;

    SInt64 head = atomic_load(&gWriteHead);
    Boolean play = (head != kNoWrite && frames > 0);
    if (play) {
        os_unfair_lock_lock(&gClockLock);
        Float64 nominal = gHostTicksPerFrame, zeroHost = gZeroHost, ticksPerFrame = gPeriodTicks / kRingFrames;
        SInt64 zeroSample = gZeroSample;
        os_unfair_lock_unlock(&gClockLock);

        UInt64 outHost = (outputTime->mFlags & kAudioTimeStampHostTimeValid) ? outputTime->mHostTime : now->mHostTime;
        Float64 position = (Float64)zeroSample + ((Float64)outHost - zeroHost) / ticksPerFrame; // Mando's sample time at outHost
        Float64 err = position - gReadLead - (Float64)gReadCursor;
        if (!gReaderSynced || fabs(err) > kResyncFrames) {
            Float64 ahead = outHost > now->mHostTime ? (Float64)(outHost - now->mHostTime) / nominal : 0;
            gReadLead = ahead + (Float64)frames + gReadMargin;
            gReadCursor = (SInt64)floor(position - gReadLead);
            gReadErrAvg = 0;
            gReaderSynced = true;
            err = 0;
        }
        if (gReadCursor + frames > head) {
            // The clients have not written this far yet: play silence and keep more distance.
            // ponytail: the margin only grows (up to 85 ms at 48 kHz) until the target is set again.
            play = false;
            gReaderSynced = false;
            if (gReadMargin < kMaxMargin) gReadMargin += kMarginStep;
        } else {
            // err > 0: Mando runs fast, so its periods get longer.
            gReadErrAvg += (err - gReadErrAvg) * 0.01;
            Float64 trim = gReadErrAvg * 1e-6;
            atomic_store(&gRateTrim, (float)fmax(-kMaxRateTrim, fmin(kMaxRateTrim, trim)));
        }
    } else {
        gReaderSynced = false;
    }

    // L/R go to the target's first two channels, however it lays out its buffers; silence elsewhere.
    UInt32 channel = 0;
    for (UInt32 bi = 0; bi < output->mNumberBuffers; bi++) {
        AudioBuffer *b = &output->mBuffers[bi];
        UInt32 ch = b->mNumberChannels;
        if (!b->mData || ch == 0) continue;
        Float32 *dst = b->mData;
        SInt64 n = b->mDataByteSize / (ch * sizeof(Float32));
        for (UInt32 c = 0; c < ch; c++, channel++) {
            Boolean copy = play && channel < kChannels;
            for (SInt64 f = 0; f < n; f++) {
                // The mask also wraps cursors below zero (kRingFrames is a power of two).
                dst[f * ch + c] = (copy && f < frames) ? gRing[((UInt64)(gReadCursor + f) & (kRingFrames - 1)) * kChannels + channel] : 0;
            }
        }
    }
    if (play) gReadCursor += frames;
    return 0;
}

// gForwardQueue only.
static void StopForwarding(void) {
    if (gTargetProc) {
        AudioDeviceStop(gTargetDevice, gTargetProc);
        AudioDeviceDestroyIOProcID(gTargetDevice, gTargetProc);
        gTargetProc = NULL;
    }
    gTargetDevice = kAudioObjectUnknown;
    pthread_mutex_lock(&gMutex);
    if (gTargetUID) { CFRelease(gTargetUID); gTargetUID = NULL; }
    pthread_mutex_unlock(&gMutex);
    atomic_store(&gRateTrim, 0.0f);
}

// gForwardQueue only. Plays on the device with that UID ("" = none) and tells the app the outcome.
static void SetTarget(CFStringRef uid) {
    StopForwarding();
    if (CFStringGetLength(uid) > 0) {
        AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectID dev = kAudioObjectUnknown;
        UInt32 size = sizeof(dev);
        OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &size, &dev);
        if (!err && dev == kAudioObjectUnknown) err = kAudioHardwareBadDeviceError;
        if (!err) {
            gReaderSynced = false;
            gReadMargin = kMarginStep;
            err = AudioDeviceCreateIOProcID(dev, ForwardIOProc, NULL, &gTargetProc);
        }
        if (!err) {
            gTargetDevice = dev;
            err = AudioDeviceStart(dev, gTargetProc);
            if (err) {
                StopForwarding();
            } else {
                pthread_mutex_lock(&gMutex);
                gTargetUID = CFRetain(uid);
                pthread_mutex_unlock(&gMutex);
            }
        }
    }
    NotifyChanged(kObjDevice, kMandoPropertyTarget, kAudioObjectPropertyScopeGlobal);
}

#pragma mark - Property dispatch

static Boolean IsKnownObject(AudioObjectID id) { return id >= kObjPlugIn && id <= kObjMute; }

static Boolean Mando_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    UInt32 size = 0;
    if (d != gDriverRef || !a || !IsKnownObject(obj)) return false;
    // A property exists if we can compute its size (qualifier-free probe).
    if (a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) return obj == kObjPlugIn;
    return Mando_GetPropertyDataSize(d, obj, pid, a, 0, NULL, &size) == 0;
}

static OSStatus Mando_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    if (!Mando_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    Boolean s = false;
    switch (obj) {
        case kObjDevice: s = (a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == kMandoPropertyTarget); break;
        case kObjStreamOut:
            s = (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat ||
                 a->mSelector == kAudioStreamPropertyIsActive); break;
        case kObjVolume: s = (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue); break;
        case kObjMute: s = (a->mSelector == kAudioBooleanControlPropertyValue); break;
    }
    *out = s;
    return 0;
}

static OSStatus Mando_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *out) {
    (void)pid; (void)qs; (void)q;
    if (d != gDriverRef || !a || !out) return kAudioHardwareBadObjectError;
    const UInt32 kCF = sizeof(CFStringRef), kID = sizeof(AudioObjectID), kU = sizeof(UInt32);
    const Boolean isInput = (a->mScope == kAudioObjectPropertyScopeInput); // Mando has no input side
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: *out = sizeof(AudioClassID); return 0;
        case kAudioObjectPropertyOwner: *out = kID; return 0;
    }
    switch (obj) {
        case kObjPlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyManufacturer: case kAudioPlugInPropertyResourceBundle: *out = kCF; return 0;
                case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: *out = kID; return 0;
                case kAudioPlugInPropertyTranslateUIDToDevice: *out = kID; return 0;
            }
            break;
        case kObjDevice:
            switch (a->mSelector) {
                case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:
                case kMandoPropertyTarget: *out = kCF; return 0;
                case kAudioObjectPropertyCustomPropertyInfoList: *out = sizeof(AudioServerPlugInCustomPropertyInfo); return 0;
                case kAudioObjectPropertyOwnedObjects: *out = (isInput ? 0 : 3) * kID; return 0;
                case kAudioDevicePropertyTransportType: case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyClockIsStable:
                    *out = kU; return 0;
                case kAudioDevicePropertyRelatedDevices: *out = kID; return 0;
                case kAudioDevicePropertyStreams: *out = (isInput ? 0 : 1) * kID; return 0;
                case kAudioObjectPropertyControlList: *out = 2 * kID; return 0;
                case kAudioDevicePropertyNominalSampleRate: *out = sizeof(Float64); return 0;
                case kAudioDevicePropertyAvailableNominalSampleRates: *out = kNumSampleRates * sizeof(AudioValueRange); return 0;
                case kAudioDevicePropertyPreferredChannelsForStereo: *out = 2 * kU; return 0;
                case kAudioDevicePropertyPreferredChannelLayout:
                    *out = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription); return 0;
            }
            break;
        case kObjStreamOut:
            switch (a->mSelector) {
                case kAudioObjectPropertyOwnedObjects: *out = 0; return 0;
                case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection: case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency: *out = kU; return 0;
                case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: *out = sizeof(AudioStreamBasicDescription); return 0;
                case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
                    *out = kNumSampleRates * sizeof(AudioStreamRangedDescription); return 0;
            }
            break;
        case kObjVolume:
            switch (a->mSelector) {
                case kAudioObjectPropertyOwnedObjects: *out = 0; return 0;
                case kAudioControlPropertyScope: *out = sizeof(AudioObjectPropertyScope); return 0;
                case kAudioControlPropertyElement: *out = sizeof(AudioObjectPropertyElement); return 0;
                case kAudioLevelControlPropertyScalarValue: case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyConvertScalarToDecibels: case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    *out = sizeof(Float32); return 0;
                case kAudioLevelControlPropertyDecibelRange: *out = sizeof(AudioValueRange); return 0;
            }
            break;
        case kObjMute:
            switch (a->mSelector) {
                case kAudioObjectPropertyOwnedObjects: *out = 0; return 0;
                case kAudioControlPropertyScope: *out = sizeof(AudioObjectPropertyScope); return 0;
                case kAudioControlPropertyElement: *out = sizeof(AudioObjectPropertyElement); return 0;
                case kAudioBooleanControlPropertyValue: *out = kU; return 0;
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Mando_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                      UInt32 qs, const void *q, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    if (d != gDriverRef || !a || !outSize || !outData) return kAudioHardwareBadObjectError;
    UInt32 need = 0;
    OSStatus err = Mando_GetPropertyDataSize(d, obj, pid, a, qs, q, &need);
    if (err) return err;

    // Variable-length list properties may be truncated to the caller's buffer.
    #define RETURN_IDS(...) do { AudioObjectID ids[] = { __VA_ARGS__ }; UInt32 n = sizeof(ids)/sizeof(ids[0]); \
        UInt32 fit = inDataSize / sizeof(AudioObjectID); if (fit < n) n = fit; \
        memcpy(outData, ids, n * sizeof(AudioObjectID)); *outSize = n * sizeof(AudioObjectID); return 0; } while (0)

    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: {
            CHECK_SIZE(sizeof(AudioClassID));
            AudioClassID c = kAudioObjectClassID;
            if (obj == kObjVolume) c = kAudioLevelControlClassID;
            else if (obj == kObjMute) c = kAudioBooleanControlClassID;
            *(AudioClassID *)outData = c; *outSize = sizeof(c); return 0;
        }
        case kAudioObjectPropertyClass: {
            CHECK_SIZE(sizeof(AudioClassID));
            AudioClassID c = kAudioPlugInClassID;
            switch (obj) {
                case kObjDevice: c = kAudioDeviceClassID; break;
                case kObjStreamOut: c = kAudioStreamClassID; break;
                case kObjVolume: c = kAudioVolumeControlClassID; break;
                case kObjMute: c = kAudioMuteControlClassID; break;
            }
            *(AudioClassID *)outData = c; *outSize = sizeof(c); return 0;
        }
        case kAudioObjectPropertyOwner: {
            CHECK_SIZE(sizeof(AudioObjectID));
            *(AudioObjectID *)outData = obj == kObjPlugIn ? kAudioObjectUnknown : (obj == kObjDevice ? kObjPlugIn : kObjDevice);
            *outSize = sizeof(AudioObjectID); return 0;
        }
    }

    switch (obj) {
        case kObjPlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyManufacturer:
                    CHECK_SIZE(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(kManufacturer); *outSize = sizeof(CFStringRef); return 0;
                case kAudioPlugInPropertyResourceBundle:
                    CHECK_SIZE(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(""); *outSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
                    RETURN_IDS(kObjDevice);
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    CHECK_SIZE(sizeof(AudioObjectID));
                    AudioObjectID r = kAudioObjectUnknown;
                    if (qs == sizeof(CFStringRef) && q && *(CFStringRef *)q && CFEqual(*(CFStringRef *)q, CFSTR(kDeviceUID))) r = kObjDevice;
                    *(AudioObjectID *)outData = r; *outSize = sizeof(r); return 0;
                }
            }
            break;

        case kObjDevice:
            switch (a->mSelector) {
                case kAudioObjectPropertyName:
                    CHECK_SIZE(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(kDeviceName); *outSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyManufacturer:
                    CHECK_SIZE(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(kManufacturer); *outSize = sizeof(CFStringRef); return 0;
                case kAudioDevicePropertyDeviceUID:
                    CHECK_SIZE(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(kDeviceUID); *outSize = sizeof(CFStringRef); return 0;
                case kAudioDevicePropertyModelUID:
                    CHECK_SIZE(sizeof(CFStringRef)); *(CFStringRef *)outData = CFSTR(kDeviceModelUID); *outSize = sizeof(CFStringRef); return 0;
                case kMandoPropertyTarget:
                    CHECK_SIZE(sizeof(CFStringRef));
                    pthread_mutex_lock(&gMutex);
                    *(CFStringRef *)outData = gTargetUID ? CFRetain(gTargetUID) : CFSTR(""); // the caller releases it
                    pthread_mutex_unlock(&gMutex);
                    *outSize = sizeof(CFStringRef); return 0;
                case kAudioObjectPropertyCustomPropertyInfoList: {
                    CHECK_SIZE(sizeof(AudioServerPlugInCustomPropertyInfo));
                    AudioServerPlugInCustomPropertyInfo *i = outData;
                    i->mSelector = kMandoPropertyTarget;
                    i->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFString;
                    i->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
                    *outSize = sizeof(*i); return 0;
                }
                case kAudioObjectPropertyOwnedObjects:
                    if (need == 0) { *outSize = 0; return 0; }
                    RETURN_IDS(kObjStreamOut, kObjVolume, kObjMute);
                case kAudioDevicePropertyStreams:
                    if (need == 0) { *outSize = 0; return 0; }
                    RETURN_IDS(kObjStreamOut);
                case kAudioObjectPropertyControlList:
                    RETURN_IDS(kObjVolume, kObjMute);
                case kAudioDevicePropertyRelatedDevices:
                    RETURN_IDS(kObjDevice);
                case kAudioDevicePropertyTransportType:
                    CHECK_SIZE(4); *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual; *outSize = 4; return 0;
                case kAudioDevicePropertyClockDomain:
                    CHECK_SIZE(4); *(UInt32 *)outData = 0; *outSize = 4; return 0;
                case kAudioDevicePropertyDeviceIsAlive:
                    CHECK_SIZE(4); *(UInt32 *)outData = 1; *outSize = 4; return 0;
                case kAudioDevicePropertyDeviceIsRunning:
                    CHECK_SIZE(4); pthread_mutex_lock(&gMutex); *(UInt32 *)outData = gIORunning > 0; pthread_mutex_unlock(&gMutex); *outSize = 4; return 0;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    CHECK_SIZE(4); *(UInt32 *)outData = (a->mScope == kAudioObjectPropertyScopeInput) ? 0 : 1; *outSize = 4; return 0;
                case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
                    CHECK_SIZE(4); *(UInt32 *)outData = 0; *outSize = 4; return 0;
                case kAudioDevicePropertyIsHidden:
                    CHECK_SIZE(4); *(UInt32 *)outData = 0; *outSize = 4; return 0;
                case kAudioDevicePropertyClockIsStable:
                    CHECK_SIZE(4); *(UInt32 *)outData = 1; *outSize = 4; return 0;
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    CHECK_SIZE(4); *(UInt32 *)outData = kRingFrames; *outSize = 4; return 0;
                case kAudioDevicePropertyNominalSampleRate:
                    CHECK_SIZE(sizeof(Float64)); pthread_mutex_lock(&gMutex); *(Float64 *)outData = gSampleRate; pthread_mutex_unlock(&gMutex);
                    *outSize = sizeof(Float64); return 0;
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    UInt32 n = inDataSize / sizeof(AudioValueRange); if (n > kNumSampleRates) n = kNumSampleRates;
                    AudioValueRange *r = outData;
                    for (UInt32 i = 0; i < n; i++) { r[i].mMinimum = kSampleRates[i]; r[i].mMaximum = kSampleRates[i]; }
                    *outSize = n * sizeof(AudioValueRange); return 0;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    CHECK_SIZE(8); ((UInt32 *)outData)[0] = 1; ((UInt32 *)outData)[1] = 2; *outSize = 8; return 0;
                case kAudioDevicePropertyPreferredChannelLayout: {
                    CHECK_SIZE(need);
                    AudioChannelLayout *l = outData; memset(l, 0, need);
                    l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    l->mNumberChannelDescriptions = kChannels;
                    l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                    l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                    *outSize = need; return 0;
                }
            }
            break;

        case kObjStreamOut:
            switch (a->mSelector) {
                case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
                case kAudioStreamPropertyIsActive: CHECK_SIZE(4); *(UInt32 *)outData = 1; *outSize = 4; return 0;
                case kAudioStreamPropertyDirection: CHECK_SIZE(4); *(UInt32 *)outData = 0; *outSize = 4; return 0;
                case kAudioStreamPropertyTerminalType:
                    CHECK_SIZE(4); *(UInt32 *)outData = kAudioStreamTerminalTypeSpeaker; *outSize = 4; return 0;
                case kAudioStreamPropertyStartingChannel: CHECK_SIZE(4); *(UInt32 *)outData = 1; *outSize = 4; return 0;
                case kAudioStreamPropertyLatency: CHECK_SIZE(4); *(UInt32 *)outData = 0; *outSize = 4; return 0;
                case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
                    CHECK_SIZE(sizeof(AudioStreamBasicDescription));
                    pthread_mutex_lock(&gMutex); FillASBD(outData, gSampleRate); pthread_mutex_unlock(&gMutex);
                    *outSize = sizeof(AudioStreamBasicDescription); return 0;
                case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
                    UInt32 n = inDataSize / sizeof(AudioStreamRangedDescription); if (n > kNumSampleRates) n = kNumSampleRates;
                    AudioStreamRangedDescription *r = outData;
                    for (UInt32 i = 0; i < n; i++) {
                        FillASBD(&r[i].mFormat, kSampleRates[i]);
                        r[i].mSampleRateRange.mMinimum = kSampleRates[i];
                        r[i].mSampleRateRange.mMaximum = kSampleRates[i];
                    }
                    *outSize = n * sizeof(AudioStreamRangedDescription); return 0;
                }
            }
            break;

        case kObjVolume:
            switch (a->mSelector) {
                case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
                case kAudioControlPropertyScope: CHECK_SIZE(4); *(AudioObjectPropertyScope *)outData = kAudioObjectPropertyScopeOutput; *outSize = 4; return 0;
                case kAudioControlPropertyElement: CHECK_SIZE(4); *(AudioObjectPropertyElement *)outData = kAudioObjectPropertyElementMain; *outSize = 4; return 0;
                case kAudioLevelControlPropertyScalarValue: CHECK_SIZE(4); *(Float32 *)outData = atomic_load(&gVolumeScalar); *outSize = 4; return 0;
                case kAudioLevelControlPropertyDecibelValue: CHECK_SIZE(4); *(Float32 *)outData = ScalarToDB(atomic_load(&gVolumeScalar)); *outSize = 4; return 0;
                case kAudioLevelControlPropertyDecibelRange: {
                    CHECK_SIZE(sizeof(AudioValueRange));
                    AudioValueRange *r = outData; r->mMinimum = kMinDB; r->mMaximum = 0; *outSize = sizeof(AudioValueRange); return 0;
                }
                case kAudioLevelControlPropertyConvertScalarToDecibels: {
                    CHECK_SIZE(4); Float32 v = *(Float32 *)outData; *(Float32 *)outData = ScalarToDB(v); *outSize = 4; return 0;
                }
                case kAudioLevelControlPropertyConvertDecibelsToScalar: {
                    CHECK_SIZE(4); Float32 v = *(Float32 *)outData; *(Float32 *)outData = DBToScalar(v); *outSize = 4; return 0;
                }
            }
            break;

        case kObjMute:
            switch (a->mSelector) {
                case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
                case kAudioControlPropertyScope: CHECK_SIZE(4); *(AudioObjectPropertyScope *)outData = kAudioObjectPropertyScopeOutput; *outSize = 4; return 0;
                case kAudioControlPropertyElement: CHECK_SIZE(4); *(AudioObjectPropertyElement *)outData = kAudioObjectPropertyElementMain; *outSize = 4; return 0;
                case kAudioBooleanControlPropertyValue: CHECK_SIZE(4); *(UInt32 *)outData = atomic_load(&gMuted) ? 1 : 0; *outSize = 4; return 0;
            }
            break;
    }
    #undef RETURN_IDS
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Mando_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                      UInt32 qs, const void *q, UInt32 inDataSize, const void *inData) {
    (void)pid; (void)qs; (void)q;
    if (d != gDriverRef || !a || !inData) return kAudioHardwareBadObjectError;

    switch (obj) {
        case kObjDevice:
            if (a->mSelector == kAudioDevicePropertyNominalSampleRate) {
                CHECK_SIZE(sizeof(Float64));
                Float64 r = *(const Float64 *)inData;
                Boolean ok = false;
                for (UInt32 i = 0; i < kNumSampleRates; i++) if (kSampleRates[i] == r) ok = true;
                if (!ok) return kAudioHardwareIllegalOperationError;
                pthread_mutex_lock(&gMutex);
                Boolean changed = (r != gSampleRate);
                gPendingSampleRate = r;
                pthread_mutex_unlock(&gMutex);
                if (changed && gHost) gHost->RequestDeviceConfigurationChange(gHost, kObjDevice, 0, NULL);
                return 0;
            }
            if (a->mSelector == kMandoPropertyTarget) {
                CHECK_SIZE(sizeof(CFStringRef));
                CFStringRef uid = *(const CFStringRef *)inData;
                if (!uid || CFGetTypeID(uid) != CFStringGetTypeID() || CFStringGetLength(uid) > kMaxUIDLength ||
                    CFEqual(uid, CFSTR(kDeviceUID)))
                    return kAudioHardwareIllegalOperationError;
                CFStringRef copy = CFStringCreateCopy(NULL, uid);
                if (!copy) return kAudioHardwareUnspecifiedError;
                // Being a client of another device is not allowed on this thread.
                dispatch_async(gForwardQueue, ^{ SetTarget(copy); CFRelease(copy); });
                return 0;
            }
            break;

        case kObjStreamOut:
            if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) {
                CHECK_SIZE(sizeof(AudioStreamBasicDescription));
                const AudioStreamBasicDescription *f = inData;
                if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != kChannels || f->mBitsPerChannel != kBitsPerChannel)
                    return kAudioDeviceUnsupportedFormatError;
                AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                return Mando_SetPropertyData(d, kObjDevice, pid, &ra, 0, NULL, sizeof(Float64), &f->mSampleRate);
            }
            if (a->mSelector == kAudioStreamPropertyIsActive) return 0;
            break;

        case kObjVolume:
            if (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue) {
                CHECK_SIZE(sizeof(Float32));
                Float32 v = *(const Float32 *)inData;
                if (a->mSelector == kAudioLevelControlPropertyDecibelValue) v = DBToScalar(v);
                if (v < 0) v = 0; if (v > 1) v = 1;
                if (v != atomic_load(&gVolumeScalar)) {
                    atomic_store(&gVolumeScalar, v);
                    SaveSettings();
                    NotifyChanged(kObjVolume, kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
                    NotifyChanged(kObjVolume, kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal);
                }
                return 0;
            }
            break;

        case kObjMute:
            if (a->mSelector == kAudioBooleanControlPropertyValue) {
                CHECK_SIZE(sizeof(UInt32));
                int m = *(const UInt32 *)inData ? 1 : 0;
                if (m != atomic_load(&gMuted)) {
                    atomic_store(&gMuted, m);
                    SaveSettings();
                    NotifyChanged(kObjMute, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
                }
                return 0;
            }
            break;
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - IO

static OSStatus Mando_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIORunning == 0) {
        memset(gRing, 0, kRingFrames * kBytesPerFrame);
        os_unfair_lock_lock(&gClockLock);
        gZeroHost = (Float64)mach_absolute_time();
        gZeroSample = 0;
        gPeriodTicks = gHostTicksPerFrame * kRingFrames;
        os_unfair_lock_unlock(&gClockLock);
    }
    gIORunning++;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus Mando_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIORunning > 0 && --gIORunning == 0) atomic_store(&gWriteHead, kNoWrite);
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus Mando_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    os_unfair_lock_lock(&gClockLock);
    if ((Float64)mach_absolute_time() >= gZeroHost + gPeriodTicks) {
        gZeroHost += gPeriodTicks;
        gZeroSample += kRingFrames;
        gPeriodTicks = gHostTicksPerFrame * kRingFrames * (1.0 + (Float64)atomic_load(&gRateTrim));
    }
    *outSampleTime = (Float64)gZeroSample;
    *outHostTime = (UInt64)gZeroHost;
    *outSeed = 1;
    os_unfair_lock_unlock(&gClockLock);
    return 0;
}

static OSStatus Mando_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op, Boolean *outWill, Boolean *outInPlace) {
    (void)client;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    *outWill = (op == kAudioServerPlugInIOOperationWriteMix);
    *outInPlace = true;
    return 0;
}

static OSStatus Mando_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjDevice) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Mando_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjDevice) ? 0 : kAudioHardwareBadObjectError;
}

static inline Float32 *RingFrame(SInt64 sampleTime) {
    return &gRing[((UInt64)sampleTime & (kRingFrames - 1)) * kChannels];
}

static OSStatus Mando_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 op,
                                    UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *mainBuf, void *secondaryBuf) {
    (void)client; (void)secondaryBuf;
    if (d != gDriverRef || id != kObjDevice) return kAudioHardwareBadObjectError;
    if (op != kAudioServerPlugInIOOperationWriteMix || stream != kObjStreamOut || !mainBuf) return 0;
    const Float32 *buf = mainBuf;
    float g = atomic_load(&gMuted) ? 0.0f : ScalarToGain(atomic_load(&gVolumeScalar));
    SInt64 start = (SInt64)info->mOutputTime.mSampleTime;

    // The reader does not erase what it plays, so a skipped stretch is silenced here.
    SInt64 head = atomic_load(&gWriteHead);
    if (head != kNoWrite && start > head) {
        SInt64 gap = start - head < kRingFrames ? start - head : kRingFrames;
        for (SInt64 i = 0; i < gap; i++) { Float32 *f = RingFrame(head + i); f[0] = 0; f[1] = 0; }
    }
    for (UInt32 i = 0; i < frames; i++) {
        Float32 *f = RingFrame(start + i);
        f[0] = buf[i * kChannels]     * g;
        f[1] = buf[i * kChannels + 1] * g;
    }
    atomic_store(&gWriteHead, start + (SInt64)frames);
    return 0;
}
