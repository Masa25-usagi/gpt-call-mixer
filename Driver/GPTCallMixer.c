/*
    GPT Call Mixer AudioServerPlugIn

    This file is deliberately kept as one source file so it can be compiled twice:

        -DGPT_CALL_MIXER_ROUTE=1   GPT Call Mixer → ChatGPT
        -DGPT_CALL_MIXER_ROUTE=2   GPT Call Mixer → Call

    The object/property scaffolding follows Apple's NullAudio AudioServerPlugIn
    sample.  The sample's license is retained in LICENSE.txt in this directory.
    This driver adds a lock-free single-producer/multi-reader stereo loopback
    ring buffer to the sample's input/output operations.

    No installation, privileged operation, recording, or external network access
    is performed by this source file.
*/

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef GPT_CALL_MIXER_ROUTE
#define GPT_CALL_MIXER_ROUTE 1
#endif

#if GPT_CALL_MIXER_ROUTE == 1
#define GPT_CALL_MIXER_DEVICE_NAME       "GPT Call Mixer → ChatGPT"
#define GPT_CALL_MIXER_BOX_NAME          "GPT Call Mixer → ChatGPT Box"
#define GPT_CALL_MIXER_DEVICE_UID        "jp.local.gptcallmixer.to-chatgpt.device"
#define GPT_CALL_MIXER_MODEL_UID         "jp.local.gptcallmixer.to-chatgpt.model"
#define GPT_CALL_MIXER_BOX_UID           "jp.local.gptcallmixer.to-chatgpt.box"
#define GPT_CALL_MIXER_BUNDLE_ID         "jp.local.gptcallmixer.driver.to-chatgpt"
#elif GPT_CALL_MIXER_ROUTE == 2
#define GPT_CALL_MIXER_DEVICE_NAME       "GPT Call Mixer → Call"
#define GPT_CALL_MIXER_BOX_NAME          "GPT Call Mixer → Call Box"
#define GPT_CALL_MIXER_DEVICE_UID        "jp.local.gptcallmixer.to-call.device"
#define GPT_CALL_MIXER_MODEL_UID         "jp.local.gptcallmixer.to-call.model"
#define GPT_CALL_MIXER_BOX_UID           "jp.local.gptcallmixer.to-call.box"
#define GPT_CALL_MIXER_BUNDLE_ID         "jp.local.gptcallmixer.driver.to-call"
#else
#error "GPT_CALL_MIXER_ROUTE must be 1 (ChatGPT) or 2 (Call)"
#endif

#define GPT_CALL_MIXER_SAMPLE_RATE             48000.0
#define GPT_CALL_MIXER_CHANNELS                2u
#define GPT_CALL_MIXER_BYTES_PER_SAMPLE        4u
#define GPT_CALL_MIXER_BYTES_PER_FRAME         (GPT_CALL_MIXER_CHANNELS * GPT_CALL_MIXER_BYTES_PER_SAMPLE)
#define GPT_CALL_MIXER_RING_FRAMES             65536u
/* AudioServerPlugIn.h requires a zero-timestamp period of at least 10923 frames. */
#define GPT_CALL_MIXER_TIMESTAMP_PERIOD        16384u
#define GPT_CALL_MIXER_DEVICE_LATENCY          256u
#define GPT_CALL_MIXER_STREAM_LATENCY            0u

_Static_assert((GPT_CALL_MIXER_RING_FRAMES & (GPT_CALL_MIXER_RING_FRAMES - 1u)) == 0u,
               "the loopback ring must have a power-of-two frame count");

enum
{
    kGPTObjectID_PlugIn       = kAudioObjectPlugInObject,
    kGPTObjectID_Box          = 2,
    kGPTObjectID_Device       = 3,
    kGPTObjectID_StreamInput  = 4,
    kGPTObjectID_StreamOutput = 5
};

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t gReferenceCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static uint64_t gDeviceIOIsRunning = 0;
static const bool gStreamInputIsActive = true;
static const bool gStreamOutputIsActive = true;
static double gHostTicksPerFrame = 0.0;
static _Atomic(uint64_t) gNumberOfZeroTimestamps = 0;
static _Atomic(uint64_t) gAnchorHostTime = 0;
static _Atomic(uint64_t) gTimelineSeed = 1;

/*
    The ring is indexed by absolute AudioTimeStamp sample time rather than by a
    consuming head/tail.  This matters because the HAL may invoke input clients
    in a different order, or may start one side before the other.  Each slot is
    tagged with the absolute frame number it contains.  A reader only accepts a
    slot when the tag exactly matches its requested frame; unwritten and stale
    turns are therefore silence.

    The write-mix callback is the producer.  Input callbacks are non-consuming
    readers, so multiple input clients can observe the same timeline.  No mutex,
    malloc, logging, Core Foundation, dispatch, or blocking call is used on the
    IO path.
*/
static _Alignas(64) _Atomic(uint64_t) gLoopbackTags[GPT_CALL_MIXER_RING_FRAMES];
static _Alignas(64) _Atomic(uint32_t) gLoopbackSamples[
    GPT_CALL_MIXER_RING_FRAMES * GPT_CALL_MIXER_CHANNELS];

static void GPT_ResetRing(void)
{
    for (UInt32 slot = 0; slot < GPT_CALL_MIXER_RING_FRAMES; ++slot)
    {
        atomic_store_explicit(&gLoopbackTags[slot], UINT64_MAX, memory_order_relaxed);
    }
}

static bool GPT_SampleTimeToFrame(Float64 sampleTime, uint64_t *frame)
{
    /* Check before conversion: a negative sample time must never become UINT64_MAX. */
    if (!isfinite(sampleTime) || (sampleTime < 0.0) ||
        (sampleTime >= (Float64)UINT64_MAX) || (frame == NULL))
    {
        return false;
    }
    *frame = (uint64_t)sampleTime;
    return true;
}

static bool GPT_HasValidSampleTime(const AudioTimeStamp *timestamp)
{
    uint64_t frame = 0;
    return (timestamp != NULL) &&
           ((timestamp->mFlags & kAudioTimeStampSampleTimeValid) != 0) &&
           GPT_SampleTimeToFrame(timestamp->mSampleTime, &frame);
}

static void GPT_StoreSample(UInt32 slot, UInt32 channel, Float32 sample)
{
    uint32_t bits = 0;
    memcpy(&bits, &sample, sizeof(bits));
    atomic_store_explicit(&gLoopbackSamples[(slot * GPT_CALL_MIXER_CHANNELS) + channel],
                          bits, memory_order_relaxed);
}

static Float32 GPT_LoadSample(UInt32 slot, UInt32 channel)
{
    const uint32_t bits = atomic_load_explicit(
        &gLoopbackSamples[(slot * GPT_CALL_MIXER_CHANNELS) + channel],
        memory_order_relaxed);
    Float32 sample = 0.0f;
    memcpy(&sample, &bits, sizeof(sample));
    return sample;
}

static void GPT_RingWrite(const Float32 *source, UInt32 frameCount, Float64 sampleTime)
{
    uint64_t absoluteFrame = 0;
    if (!GPT_SampleTimeToFrame(sampleTime, &absoluteFrame))
    {
        return;
    }

    for (UInt32 frame = 0; frame < frameCount; ++frame)
    {
        if (absoluteFrame == UINT64_MAX)
        {
            break;
        }
        const UInt32 slot = (UInt32)(absoluteFrame & (GPT_CALL_MIXER_RING_FRAMES - 1u));
        /* Invalidate the old generation before replacing either channel. */
        atomic_store_explicit(&gLoopbackTags[slot], UINT64_MAX, memory_order_release);
        GPT_StoreSample(slot, 0u, source[(frame * GPT_CALL_MIXER_CHANNELS) + 0u]);
        GPT_StoreSample(slot, 1u, source[(frame * GPT_CALL_MIXER_CHANNELS) + 1u]);
        /* Publish the new tag only after both channel samples are stored. */
        atomic_store_explicit(&gLoopbackTags[slot], absoluteFrame, memory_order_release);
        ++absoluteFrame;
    }
}

static void GPT_RingRead(Float32 *destination, UInt32 frameCount, Float64 sampleTime)
{
    uint64_t absoluteFrame = 0;
    if (!GPT_SampleTimeToFrame(sampleTime, &absoluteFrame))
    {
        memset(destination, 0, frameCount * GPT_CALL_MIXER_BYTES_PER_FRAME);
        return;
    }

    for (UInt32 frame = 0; frame < frameCount; ++frame)
    {
        Float32 left = 0.0f;
        Float32 right = 0.0f;
        if (absoluteFrame != UINT64_MAX)
        {
            const UInt32 slot = (UInt32)(absoluteFrame & (GPT_CALL_MIXER_RING_FRAMES - 1u));
            const uint64_t firstTag = atomic_load_explicit(&gLoopbackTags[slot],
                                                            memory_order_acquire);
            if (firstTag == absoluteFrame)
            {
                left = GPT_LoadSample(slot, 0u);
                right = GPT_LoadSample(slot, 1u);
                /* If a wrap replaced the slot during the read, return silence. */
                const uint64_t secondTag = atomic_load_explicit(&gLoopbackTags[slot],
                                                                 memory_order_acquire);
                if (secondTag != absoluteFrame)
                {
                    left = 0.0f;
                    right = 0.0f;
                }
            }
        }
        destination[(frame * GPT_CALL_MIXER_CHANNELS) + 0u] = left;
        destination[(frame * GPT_CALL_MIXER_CHANNELS) + 1u] = right;
        if (absoluteFrame != UINT64_MAX)
        {
            ++absoluteFrame;
        }
    }

}

static bool GPT_IsDriver(AudioServerPlugInDriverRef driver)
{
    extern AudioServerPlugInDriverRef gGPTCallMixerDriverRef;
    return driver == gGPTCallMixerDriverRef;
}

static OSStatus GPT_CopyPropertyData(UInt32 inputDataSize,
                                     UInt32 *outputDataSize,
                                     void *outputData,
                                     const void *sourceData,
                                     UInt32 sourceDataSize)
{
    if ((outputDataSize == NULL) || (outputData == NULL) || (sourceData == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }
    if (inputDataSize < sourceDataSize)
    {
        return kAudioHardwareBadPropertySizeError;
    }
    memcpy(outputData, sourceData, sourceDataSize);
    *outputDataSize = sourceDataSize;
    return kAudioHardwareNoError;
}

static void GPT_FillFormat(AudioStreamBasicDescription *format)
{
    memset(format, 0, sizeof(*format));
    format->mSampleRate = GPT_CALL_MIXER_SAMPLE_RATE;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat |
                            kAudioFormatFlagsNativeEndian |
                            kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = GPT_CALL_MIXER_BYTES_PER_FRAME;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = GPT_CALL_MIXER_BYTES_PER_FRAME;
    format->mChannelsPerFrame = GPT_CALL_MIXER_CHANNELS;
    format->mBitsPerChannel = 32;
}

static bool GPT_FormatIsSupported(const AudioStreamBasicDescription *format)
{
    AudioStreamBasicDescription expected;
    GPT_FillFormat(&expected);
    return (format->mSampleRate == expected.mSampleRate) &&
           (format->mFormatID == expected.mFormatID) &&
           (format->mFormatFlags == expected.mFormatFlags) &&
           (format->mBytesPerPacket == expected.mBytesPerPacket) &&
           (format->mFramesPerPacket == expected.mFramesPerPacket) &&
           (format->mBytesPerFrame == expected.mBytesPerFrame) &&
           (format->mChannelsPerFrame == expected.mChannelsPerFrame) &&
           (format->mBitsPerChannel == expected.mBitsPerChannel);
}

static void GPT_UpdateHostClock(void)
{
    mach_timebase_info_data_t timebase = { 0, 0 };
    mach_timebase_info(&timebase);
    if ((timebase.numer != 0u) && (timebase.denom != 0u))
    {
        const double hostTicksPerSecond =
            ((double)timebase.denom / (double)timebase.numer) * 1000000000.0;
        gHostTicksPerFrame = hostTicksPerSecond / GPT_CALL_MIXER_SAMPLE_RATE;
    }
    else
    {
        gHostTicksPerFrame = 0.0;
    }
}

/* Forward declarations for the AudioServerPlugIn interface. */
void *GPTCallMixer_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
static HRESULT GPT_QueryInterface(void *driver, REFIID uuid, LPVOID *interfaceOut);
static ULONG GPT_AddRef(void *driver);
static ULONG GPT_Release(void *driver);
static OSStatus GPT_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host);
static OSStatus GPT_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description,
                                 const AudioServerPlugInClientInfo *clientInfo,
                                 AudioObjectID *deviceObjectID);
static OSStatus GPT_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID);
static OSStatus GPT_AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                    const AudioServerPlugInClientInfo *clientInfo);
static OSStatus GPT_RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                       const AudioServerPlugInClientInfo *clientInfo);
static OSStatus GPT_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                                     AudioObjectID deviceObjectID,
                                                     UInt64 changeAction, void *changeInfo);
static OSStatus GPT_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                                   AudioObjectID deviceObjectID,
                                                   UInt64 changeAction, void *changeInfo);
static Boolean GPT_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                               pid_t clientProcessID, const AudioObjectPropertyAddress *address);
static OSStatus GPT_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                       pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                       Boolean *isSettable);
static OSStatus GPT_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                        pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                        UInt32 qualifierDataSize, const void *qualifierData,
                                        UInt32 *dataSize);
static OSStatus GPT_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                    pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize, const void *qualifierData,
                                    UInt32 dataSize, UInt32 *dataSizeOut, void *dataOut);
static OSStatus GPT_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                    pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize, const void *qualifierData,
                                    UInt32 dataSize, const void *data);
static OSStatus GPT_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                            UInt32 clientID);
static OSStatus GPT_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                           UInt32 clientID);
static OSStatus GPT_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                     UInt32 clientID, Float64 *sampleTime, UInt64 *hostTime,
                                     UInt64 *seed);
static OSStatus GPT_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                      UInt32 clientID, UInt32 operationID, Boolean *willDo,
                                      Boolean *willDoInPlace);
static OSStatus GPT_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                     UInt32 clientID, UInt32 operationID, UInt32 frameCount,
                                     const AudioServerPlugInIOCycleInfo *cycleInfo);
static OSStatus GPT_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                  AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID,
                                  UInt32 frameCount, const AudioServerPlugInIOCycleInfo *cycleInfo,
                                  void *mainBuffer, void *secondaryBuffer);
static OSStatus GPT_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                   UInt32 clientID, UInt32 operationID, UInt32 frameCount,
                                   const AudioServerPlugInIOCycleInfo *cycleInfo);

AudioServerPlugInDriverInterface gGPTCallMixerDriverInterface =
{
    NULL,
    GPT_QueryInterface,
    GPT_AddRef,
    GPT_Release,
    GPT_Initialize,
    GPT_CreateDevice,
    GPT_DestroyDevice,
    GPT_AddDeviceClient,
    GPT_RemoveDeviceClient,
    GPT_PerformDeviceConfigurationChange,
    GPT_AbortDeviceConfigurationChange,
    GPT_HasProperty,
    GPT_IsPropertySettable,
    GPT_GetPropertyDataSize,
    GPT_GetPropertyData,
    GPT_SetPropertyData,
    GPT_StartIO,
    GPT_StopIO,
    GPT_GetZeroTimeStamp,
    GPT_WillDoIOOperation,
    GPT_BeginIOOperation,
    GPT_DoIOOperation,
    GPT_EndIOOperation
};

AudioServerPlugInDriverInterface *gGPTCallMixerDriverInterfacePtr =
    &gGPTCallMixerDriverInterface;
AudioServerPlugInDriverRef gGPTCallMixerDriverRef =
    &gGPTCallMixerDriverInterfacePtr;

__attribute__((visibility("default")))
void *GPTCallMixer_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;
    if ((requestedTypeUUID != NULL) && CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
        return gGPTCallMixerDriverRef;
    }
    return NULL;
}

static HRESULT GPT_QueryInterface(void *driver, REFIID uuid, LPVOID *interfaceOut)
{
    /* REFIID is the CFUUIDBytes value type, not a nullable pointer. */
    if (!GPT_IsDriver((AudioServerPlugInDriverRef)driver) || (interfaceOut == NULL))
    {
        return kAudioHardwareBadObjectError;
    }

    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    if (requestedUUID == NULL)
    {
        return kAudioHardwareIllegalOperationError;
    }

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requestedUUID, IUnknownUUID) ||
        CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        pthread_mutex_lock(&gStateMutex);
        if (gReferenceCount < UINT32_MAX)
        {
            ++gReferenceCount;
        }
        pthread_mutex_unlock(&gStateMutex);
        *interfaceOut = gGPTCallMixerDriverRef;
        result = kAudioHardwareNoError;
    }

    CFRelease(requestedUUID);
    return result;
}

static ULONG GPT_AddRef(void *driver)
{
    if (!GPT_IsDriver((AudioServerPlugInDriverRef)driver))
    {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gReferenceCount < UINT32_MAX)
    {
        ++gReferenceCount;
    }
    const ULONG result = gReferenceCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static ULONG GPT_Release(void *driver)
{
    if (!GPT_IsDriver((AudioServerPlugInDriverRef)driver))
    {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gReferenceCount > 0u)
    {
        --gReferenceCount;
    }
    const ULONG result = gReferenceCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static OSStatus GPT_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host)
{
    if (!GPT_IsDriver(driver))
    {
        return kAudioHardwareBadObjectError;
    }
    gHost = host;
    GPT_UpdateHostClock();
    GPT_ResetRing();
    atomic_store_explicit(&gNumberOfZeroTimestamps, 0u, memory_order_relaxed);
    atomic_store_explicit(&gAnchorHostTime, mach_absolute_time(), memory_order_release);
    return kAudioHardwareNoError;
}

static OSStatus GPT_CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef description,
                                 const AudioServerPlugInClientInfo *clientInfo,
                                 AudioObjectID *deviceObjectID)
{
    (void)description;
    (void)clientInfo;
    (void)deviceObjectID;
    return GPT_IsDriver(driver) ? kAudioHardwareUnsupportedOperationError
                                : kAudioHardwareBadObjectError;
}

static OSStatus GPT_DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID)
{
    (void)deviceObjectID;
    return GPT_IsDriver(driver) ? kAudioHardwareUnsupportedOperationError
                                : kAudioHardwareBadObjectError;
}

static OSStatus GPT_AddDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                    const AudioServerPlugInClientInfo *clientInfo)
{
    (void)clientInfo;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
    {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static OSStatus GPT_RemoveDeviceClient(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                       const AudioServerPlugInClientInfo *clientInfo)
{
    (void)clientInfo;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
    {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static OSStatus GPT_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                                     AudioObjectID deviceObjectID,
                                                     UInt64 changeAction, void *changeInfo)
{
    (void)changeInfo;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
    {
        return kAudioHardwareBadObjectError;
    }
    return (changeAction == (UInt64)GPT_CALL_MIXER_SAMPLE_RATE)
        ? kAudioHardwareNoError
        : kAudioHardwareUnsupportedOperationError;
}

static OSStatus GPT_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef driver,
                                                   AudioObjectID deviceObjectID,
                                                   UInt64 changeAction, void *changeInfo)
{
    (void)changeAction;
    (void)changeInfo;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
    {
        return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareNoError;
}

static Boolean GPT_HasPlugInProperty(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static Boolean GPT_HasBoxProperty(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
            return true;
        default:
            return false;
    }
}

static Boolean GPT_HasDeviceProperty(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return true;
        case kAudioObjectPropertyElementName:
            return address->mElement <= 2u;
        default:
            return false;
    }
}

static Boolean GPT_HasStreamProperty(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean GPT_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                               pid_t clientProcessID, const AudioObjectPropertyAddress *address)
{
    (void)clientProcessID;
    if (!GPT_IsDriver(driver) || (address == NULL))
    {
        return false;
    }
    switch (objectID)
    {
        case kGPTObjectID_PlugIn:
            return GPT_HasPlugInProperty(address);
        case kGPTObjectID_Box:
            return GPT_HasBoxProperty(address);
        case kGPTObjectID_Device:
            return GPT_HasDeviceProperty(address);
        case kGPTObjectID_StreamInput:
        case kGPTObjectID_StreamOutput:
            return GPT_HasStreamProperty(address);
        default:
            return false;
    }
}

static Boolean GPT_IsKnownPlugInProperty(AudioObjectPropertySelector selector)
{
    return GPT_HasPlugInProperty(&(AudioObjectPropertyAddress){ selector,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain });
}

static Boolean GPT_IsKnownBoxProperty(AudioObjectPropertySelector selector)
{
    return GPT_HasBoxProperty(&(AudioObjectPropertyAddress){ selector,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain });
}

static Boolean GPT_IsKnownDeviceProperty(AudioObjectPropertySelector selector)
{
    return GPT_HasDeviceProperty(&(AudioObjectPropertyAddress){ selector,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain });
}

static Boolean GPT_IsKnownStreamProperty(AudioObjectPropertySelector selector)
{
    return GPT_HasStreamProperty(&(AudioObjectPropertyAddress){ selector,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain });
}

static OSStatus GPT_IsPropertySettable(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                       pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                       Boolean *isSettable)
{
    (void)clientProcessID;
    if (!GPT_IsDriver(driver) || (address == NULL) || (isSettable == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }
    *isSettable = false;

    switch (objectID)
    {
        case kGPTObjectID_PlugIn:
            return GPT_IsKnownPlugInProperty(address->mSelector)
                ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
        case kGPTObjectID_Box:
            return GPT_IsKnownBoxProperty(address->mSelector)
                ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
        case kGPTObjectID_Device:
            return GPT_IsKnownDeviceProperty(address->mSelector)
                ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
        case kGPTObjectID_StreamInput:
        case kGPTObjectID_StreamOutput:
            if (!GPT_IsKnownStreamProperty(address->mSelector))
            {
                return kAudioHardwareUnknownPropertyError;
            }
            *isSettable = (address->mSelector == kAudioStreamPropertyVirtualFormat) ||
                          (address->mSelector == kAudioStreamPropertyPhysicalFormat);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus GPT_GetPlugInPropertyDataSize(const AudioObjectPropertyAddress *address,
                                              UInt32 *dataSize)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *dataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *dataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
            *dataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *dataSize = 2u * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GPT_GetPlugInPropertyData(const AudioObjectPropertyAddress *address,
                                           UInt32 qualifierDataSize, const void *qualifierData,
                                           UInt32 inputDataSize, UInt32 *outputDataSize,
                                           void *outputData)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        {
            const AudioClassID value = kAudioObjectClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyClass:
        {
            const AudioClassID value = kAudioPlugInClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwner:
        {
            const AudioObjectID value = kAudioObjectUnknown;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyManufacturer:
        {
            CFStringRef value = CFSTR("GPT");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwnedObjects:
        {
            AudioObjectID values[2] = { kGPTObjectID_Box, kGPTObjectID_Device };
            UInt32 count = inputDataSize / sizeof(AudioObjectID);
            if (count > 2u)
            {
                count = 2u;
            }
            memcpy(outputData, values, count * sizeof(AudioObjectID));
            *outputDataSize = count * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioPlugInPropertyBoxList:
        {
            const AudioObjectID value = kGPTObjectID_Box;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioPlugInPropertyDeviceList:
        {
            const AudioObjectID value = kGPTObjectID_Device;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        {
            const bool isBox = address->mSelector == kAudioPlugInPropertyTranslateUIDToBox;
            CFStringRef expectedUID = isBox ? CFSTR(GPT_CALL_MIXER_BOX_UID)
                                            : CFSTR(GPT_CALL_MIXER_DEVICE_UID);
            AudioObjectID value = kAudioObjectUnknown;
            if ((qualifierDataSize == sizeof(CFStringRef)) && (qualifierData != NULL))
            {
                CFStringRef requestedUID = *((const CFStringRef *)qualifierData);
                if ((requestedUID != NULL) &&
                    (CFStringCompare(requestedUID, expectedUID, 0) == kCFCompareEqualTo))
                {
                    value = isBox ? kGPTObjectID_Box : kGPTObjectID_Device;
                }
            }
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioPlugInPropertyResourceBundle:
        {
            CFStringRef value = CFSTR("");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GPT_GetBoxPropertyDataSize(const AudioObjectPropertyAddress *address,
                                           UInt32 *dataSize)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *dataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *dataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
            *dataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *dataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyIdentify:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
            *dataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioBoxPropertyDeviceList:
            *dataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GPT_GetBoxPropertyData(const AudioObjectPropertyAddress *address,
                                       UInt32 inputDataSize, UInt32 *outputDataSize,
                                       void *outputData)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        {
            const AudioClassID value = kAudioObjectClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyClass:
        {
            const AudioClassID value = kAudioBoxClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwner:
        {
            const AudioObjectID value = kGPTObjectID_PlugIn;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyName:
        {
            CFStringRef value = CFSTR(GPT_CALL_MIXER_BOX_NAME);
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyModelName:
        {
            CFStringRef value = CFSTR("GPT Call Mixer Model");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyManufacturer:
        {
            CFStringRef value = CFSTR("GPT");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwnedObjects:
            *outputDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyIdentify:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquisitionFailed:
        {
            const UInt32 value = 0;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyAcquired:
        {
            const UInt32 value = 1;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertySerialNumber:
        {
            CFStringRef value = CFSTR("GPT-0001");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyFirmwareVersion:
        {
            CFStringRef value = CFSTR("1.0");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioBoxPropertyBoxUID:
        {
            CFStringRef value = CFSTR(GPT_CALL_MIXER_BOX_UID);
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioBoxPropertyTransportType:
        {
            const UInt32 value = kAudioDeviceTransportTypeVirtual;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioBoxPropertyDeviceList:
        {
            const AudioObjectID value = kGPTObjectID_Device;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static UInt32 GPT_StreamCountForScope(AudioObjectPropertyScope scope)
{
    if (scope == kAudioObjectPropertyScopeGlobal)
    {
        return 2u;
    }
    if ((scope == kAudioObjectPropertyScopeInput) ||
        (scope == kAudioObjectPropertyScopeOutput))
    {
        return 1u;
    }
    return 0u;
}

static OSStatus GPT_GetDevicePropertyDataSize(const AudioObjectPropertyAddress *address,
                                              UInt32 *dataSize)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *dataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyRelatedDevices:
            *dataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyElementName:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *dataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            *dataSize = GPT_StreamCountForScope(address->mScope) * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
            *dataSize = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *dataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
            *dataSize = sizeof(Float64);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *dataSize = sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            *dataSize = 2u * sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelLayout:
            *dataSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                        (2u * sizeof(AudioChannelDescription));
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GPT_GetDevicePropertyData(const AudioObjectPropertyAddress *address,
                                          UInt32 inputDataSize, UInt32 *outputDataSize,
                                          void *outputData)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        {
            const AudioClassID value = kAudioObjectClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyClass:
        {
            const AudioClassID value = kAudioDeviceClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwner:
        {
            const AudioObjectID value = kGPTObjectID_PlugIn;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyName:
        {
            CFStringRef value = CFSTR(GPT_CALL_MIXER_DEVICE_NAME);
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyManufacturer:
        {
            CFStringRef value = CFSTR("GPT");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyElementName:
        {
            CFStringRef value = CFSTR("Master");
            if (address->mElement == 1u)
            {
                value = CFSTR("Left");
            }
            else if (address->mElement == 2u)
            {
                value = CFSTR("Right");
            }
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
        {
            AudioObjectID values[2] = { kGPTObjectID_StreamInput, kGPTObjectID_StreamOutput };
            UInt32 count = inputDataSize / sizeof(AudioObjectID);
            const UInt32 available = GPT_StreamCountForScope(address->mScope);
            if (count > available)
            {
                count = available;
            }
            if (address->mScope == kAudioObjectPropertyScopeInput)
            {
                values[0] = kGPTObjectID_StreamInput;
            }
            else if (address->mScope == kAudioObjectPropertyScopeOutput)
            {
                values[0] = kGPTObjectID_StreamOutput;
            }
            memcpy(outputData, values, count * sizeof(AudioObjectID));
            *outputDataSize = count * sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList:
            *outputDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
        {
            CFStringRef value = CFSTR(GPT_CALL_MIXER_DEVICE_UID);
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyModelUID:
        {
            CFStringRef value = CFSTR(GPT_CALL_MIXER_MODEL_UID);
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyTransportType:
        {
            const UInt32 value = kAudioDeviceTransportTypeVirtual;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyRelatedDevices:
        {
            const AudioObjectID value = kGPTObjectID_Device;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyIsHidden:
        {
            const UInt32 value = 0;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        {
            /*
                The public side of this loopback is a virtual microphone.  It
                must explicitly opt in as a default input candidate; returning
                zero makes AudioObjectSetPropertyData appear to succeed while
                HAL keeps the previous default input.
            */
            const UInt32 value =
                address->mScope == kAudioObjectPropertyScopeInput ? 1u : 0u;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        {
            /* There is no default-system-input role; never offer this as a system output. */
            const UInt32 value = 0;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyDeviceIsAlive:
        {
            const UInt32 value = 1;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyDeviceIsRunning:
        {
            UInt32 value;
            pthread_mutex_lock(&gStateMutex);
            value = (gDeviceIOIsRunning > 0u) ? 1u : 0u;
            pthread_mutex_unlock(&gStateMutex);
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyLatency:
        {
            const UInt32 value = GPT_CALL_MIXER_DEVICE_LATENCY;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyNominalSampleRate:
        {
            const Float64 value = GPT_CALL_MIXER_SAMPLE_RATE;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioDevicePropertyAvailableNominalSampleRates:
        {
            AudioValueRange value = { GPT_CALL_MIXER_SAMPLE_RATE, GPT_CALL_MIXER_SAMPLE_RATE };
            UInt32 count = inputDataSize / sizeof(AudioValueRange);
            if (count > 1u)
            {
                count = 1u;
            }
            if (count != 0u)
            {
                memcpy(outputData, &value, sizeof(value));
            }
            *outputDataSize = count * sizeof(AudioValueRange);
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo:
        {
            const UInt32 values[2] = { 1u, 2u };
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        values, sizeof(values));
        }
        case kAudioDevicePropertyPreferredChannelLayout:
        {
            const UInt32 layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                                       (2u * sizeof(AudioChannelDescription));
            if (inputDataSize < layoutSize)
            {
                return kAudioHardwareBadPropertySizeError;
            }
            AudioChannelLayout *layout = (AudioChannelLayout *)outputData;
            memset(layout, 0, layoutSize);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = 2u;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outputDataSize = layoutSize;
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod:
        {
            const UInt32 value = GPT_CALL_MIXER_TIMESTAMP_PERIOD;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GPT_GetStreamPropertyDataSize(const AudioObjectPropertyAddress *address,
                                              UInt32 *dataSize)
{
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *dataSize = sizeof(AudioClassID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwner:
            *dataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
            *dataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
            *dataSize = sizeof(CFStringRef);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *dataSize = sizeof(UInt32);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *dataSize = sizeof(AudioStreamBasicDescription);
            return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *dataSize = sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GPT_GetStreamPropertyData(AudioObjectID objectID,
                                          const AudioObjectPropertyAddress *address,
                                          UInt32 inputDataSize, UInt32 *outputDataSize,
                                          void *outputData)
{
    const bool isInput = objectID == kGPTObjectID_StreamInput;
    switch (address->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
        {
            const AudioClassID value = kAudioObjectClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyClass:
        {
            const AudioClassID value = kAudioStreamClassID;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwner:
        {
            const AudioObjectID value = kGPTObjectID_Device;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioObjectPropertyOwnedObjects:
            *outputDataSize = 0;
            return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        {
            CFStringRef value = isInput ? CFSTR("GPT Call Mixer Input")
                                        : CFSTR("GPT Call Mixer Output");
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioStreamPropertyIsActive:
        {
            const UInt32 value = (isInput ? gStreamInputIsActive : gStreamOutputIsActive)
                ? 1u : 0u;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioStreamPropertyDirection:
        {
            const UInt32 value = isInput ? 1u : 0u;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioStreamPropertyTerminalType:
        {
            const UInt32 value = isInput ? kAudioStreamTerminalTypeMicrophone
                                         : kAudioStreamTerminalTypeSpeaker;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioStreamPropertyStartingChannel:
        {
            const UInt32 value = 1u;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioStreamPropertyLatency:
        {
            const UInt32 value = GPT_CALL_MIXER_STREAM_LATENCY;
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        {
            AudioStreamBasicDescription value;
            GPT_FillFormat(&value);
            return GPT_CopyPropertyData(inputDataSize, outputDataSize, outputData,
                                        &value, sizeof(value));
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        {
            AudioStreamRangedDescription value;
            memset(&value, 0, sizeof(value));
            GPT_FillFormat(&value.mFormat);
            value.mSampleRateRange.mMinimum = GPT_CALL_MIXER_SAMPLE_RATE;
            value.mSampleRateRange.mMaximum = GPT_CALL_MIXER_SAMPLE_RATE;
            UInt32 count = inputDataSize / sizeof(AudioStreamRangedDescription);
            if (count > 1u)
            {
                count = 1u;
            }
            if (count != 0u)
            {
                memcpy(outputData, &value, sizeof(value));
            }
            *outputDataSize = count * sizeof(AudioStreamRangedDescription);
            return kAudioHardwareNoError;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GPT_GetPropertyDataSize(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                        pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                        UInt32 qualifierDataSize, const void *qualifierData,
                                        UInt32 *dataSize)
{
    (void)clientProcessID;
    (void)qualifierDataSize;
    (void)qualifierData;
    if (!GPT_IsDriver(driver) || (address == NULL) || (dataSize == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }
    switch (objectID)
    {
        case kGPTObjectID_PlugIn:
            return GPT_GetPlugInPropertyDataSize(address, dataSize);
        case kGPTObjectID_Box:
            return GPT_GetBoxPropertyDataSize(address, dataSize);
        case kGPTObjectID_Device:
            return GPT_GetDevicePropertyDataSize(address, dataSize);
        case kGPTObjectID_StreamInput:
        case kGPTObjectID_StreamOutput:
            return GPT_GetStreamPropertyDataSize(address, dataSize);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus GPT_GetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                    pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize, const void *qualifierData,
                                    UInt32 dataSize, UInt32 *dataSizeOut, void *dataOut)
{
    (void)clientProcessID;
    if (!GPT_IsDriver(driver) || (address == NULL) ||
        (dataSizeOut == NULL) || (dataOut == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }
    switch (objectID)
    {
        case kGPTObjectID_PlugIn:
            return GPT_GetPlugInPropertyData(address, qualifierDataSize, qualifierData,
                                             dataSize, dataSizeOut, dataOut);
        case kGPTObjectID_Box:
            return GPT_GetBoxPropertyData(address, dataSize, dataSizeOut, dataOut);
        case kGPTObjectID_Device:
            return GPT_GetDevicePropertyData(address, dataSize, dataSizeOut, dataOut);
        case kGPTObjectID_StreamInput:
        case kGPTObjectID_StreamOutput:
            return GPT_GetStreamPropertyData(objectID, address, dataSize, dataSizeOut, dataOut);
        default:
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus GPT_SetPropertyData(AudioServerPlugInDriverRef driver, AudioObjectID objectID,
                                    pid_t clientProcessID, const AudioObjectPropertyAddress *address,
                                    UInt32 qualifierDataSize, const void *qualifierData,
                                    UInt32 dataSize, const void *data)
{
    (void)clientProcessID;
    (void)qualifierDataSize;
    (void)qualifierData;
    if (!GPT_IsDriver(driver) || (address == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }
    if (objectID == kGPTObjectID_StreamInput || objectID == kGPTObjectID_StreamOutput)
    {
        if ((address->mSelector == kAudioStreamPropertyVirtualFormat) ||
            (address->mSelector == kAudioStreamPropertyPhysicalFormat))
        {
            if ((data == NULL) || (dataSize != sizeof(AudioStreamBasicDescription)))
            {
                return kAudioHardwareBadPropertySizeError;
            }
            AudioStreamBasicDescription requested;
            memcpy(&requested, data, sizeof(requested));
            return GPT_FormatIsSupported(&requested)
                ? kAudioHardwareNoError : kAudioHardwareUnsupportedOperationError;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    if (objectID == kGPTObjectID_Device &&
        (address->mSelector == kAudioDevicePropertyNominalSampleRate))
    {
        if ((data == NULL) || (dataSize != sizeof(Float64)))
        {
            return kAudioHardwareBadPropertySizeError;
        }
        Float64 requestedRate;
        memcpy(&requestedRate, data, sizeof(requestedRate));
        return (requestedRate == GPT_CALL_MIXER_SAMPLE_RATE)
            ? kAudioHardwareNoError : kAudioHardwareUnsupportedOperationError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus GPT_StartIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                            UInt32 clientID)
{
    (void)clientID;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
    {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gDeviceIOIsRunning == 0u)
    {
        GPT_ResetRing();
        atomic_store_explicit(&gNumberOfZeroTimestamps, 0u, memory_order_relaxed);
        atomic_store_explicit(&gAnchorHostTime, mach_absolute_time(), memory_order_release);
        const uint64_t oldSeed = atomic_load_explicit(&gTimelineSeed, memory_order_relaxed);
        if (oldSeed == UINT64_MAX)
        {
            atomic_store_explicit(&gTimelineSeed, 1u, memory_order_release);
        }
        else
        {
            atomic_store_explicit(&gTimelineSeed, oldSeed + 1u, memory_order_release);
        }
    }
    if (gDeviceIOIsRunning == UINT64_MAX)
    {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    ++gDeviceIOIsRunning;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus GPT_StopIO(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                           UInt32 clientID)
{
    (void)clientID;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
    {
        return kAudioHardwareBadObjectError;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gDeviceIOIsRunning == 0u)
    {
        pthread_mutex_unlock(&gStateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    --gDeviceIOIsRunning;
    if (gDeviceIOIsRunning == 0u)
    {
        GPT_ResetRing();
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus GPT_GetZeroTimeStamp(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                     UInt32 clientID, Float64 *sampleTime, UInt64 *hostTime,
                                     UInt64 *seed)
{
    (void)clientID;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device) ||
        (sampleTime == NULL) || (hostTime == NULL) || (seed == NULL))
    {
        return kAudioHardwareIllegalOperationError;
    }

    UInt64 anchorHostTime = atomic_load_explicit(&gAnchorHostTime, memory_order_acquire);
    if (anchorHostTime == 0u)
    {
        const UInt64 candidateAnchor = mach_absolute_time();
        if (!atomic_compare_exchange_strong_explicit(&gAnchorHostTime, &anchorHostTime,
                                                     candidateAnchor,
                                                     memory_order_acq_rel,
                                                     memory_order_acquire))
        {
            /* Another caller published the anchor; use its value. */
        }
        else
        {
            anchorHostTime = candidateAnchor;
        }
    }
    const double hostTicksPerPeriod =
        gHostTicksPerFrame * (double)GPT_CALL_MIXER_TIMESTAMP_PERIOD;
    const UInt64 currentHostTime = mach_absolute_time();
    uint64_t timestampNumber = atomic_load_explicit(&gNumberOfZeroTimestamps,
                                                    memory_order_acquire);
    if ((hostTicksPerPeriod > 0.0) && (currentHostTime >= anchorHostTime))
    {
        /* Catch up directly if the host did not ask for timestamps for a while. */
        const UInt64 elapsedHostTicks = currentHostTime - anchorHostTime;
        const uint64_t elapsedPeriods =
            (uint64_t)((double)elapsedHostTicks / hostTicksPerPeriod);
        while ((elapsedPeriods > timestampNumber) &&
               !atomic_compare_exchange_weak_explicit(&gNumberOfZeroTimestamps,
                                                       &timestampNumber,
                                                       elapsedPeriods,
                                                       memory_order_acq_rel,
                                                       memory_order_acquire))
        {
            /* timestampNumber was refreshed by the failed compare-exchange. */
        }
        timestampNumber = atomic_load_explicit(&gNumberOfZeroTimestamps, memory_order_acquire);
    }
    *sampleTime = (Float64)timestampNumber * GPT_CALL_MIXER_TIMESTAMP_PERIOD;
    *hostTime = anchorHostTime +
        (UInt64)(((double)timestampNumber) * hostTicksPerPeriod);
    *seed = atomic_load_explicit(&gTimelineSeed, memory_order_acquire);
    return kAudioHardwareNoError;
}

static OSStatus GPT_WillDoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                      UInt32 clientID, UInt32 operationID, Boolean *willDo,
                                      Boolean *willDoInPlace)
{
    (void)clientID;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
    {
        return kAudioHardwareBadObjectError;
    }
    Boolean supported = false;
    if ((operationID == kAudioServerPlugInIOOperationReadInput) ||
        (operationID == kAudioServerPlugInIOOperationWriteMix))
    {
        supported = true;
    }
    if (willDo != NULL)
    {
        *willDo = supported;
    }
    if (willDoInPlace != NULL)
    {
        *willDoInPlace = supported;
    }
    return kAudioHardwareNoError;
}

static OSStatus GPT_BeginIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                     UInt32 clientID, UInt32 operationID, UInt32 frameCount,
                                     const AudioServerPlugInIOCycleInfo *cycleInfo)
{
    (void)clientID;
    (void)operationID;
    (void)frameCount;
    (void)cycleInfo;
    return (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
        ? kAudioHardwareBadObjectError : kAudioHardwareNoError;
}

static OSStatus GPT_DoIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                  AudioObjectID streamObjectID, UInt32 clientID, UInt32 operationID,
                                  UInt32 frameCount, const AudioServerPlugInIOCycleInfo *cycleInfo,
                                  void *mainBuffer, void *secondaryBuffer)
{
    (void)clientID;
    (void)cycleInfo;
    (void)secondaryBuffer;
    if (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device) ||
        (mainBuffer == NULL))
    {
        return kAudioHardwareBadObjectError;
    }
    if (operationID == kAudioServerPlugInIOOperationReadInput)
    {
        if (streamObjectID != kGPTObjectID_StreamInput)
        {
            return kAudioHardwareBadStreamError;
        }
        if ((cycleInfo == NULL) || !GPT_HasValidSampleTime(&cycleInfo->mInputTime))
        {
            memset(mainBuffer, 0, frameCount * GPT_CALL_MIXER_BYTES_PER_FRAME);
            return kAudioHardwareNoError;
        }
        GPT_RingRead((Float32 *)mainBuffer, frameCount,
                     cycleInfo->mInputTime.mSampleTime);
        return kAudioHardwareNoError;
    }
    if (operationID == kAudioServerPlugInIOOperationWriteMix)
    {
        if (streamObjectID != kGPTObjectID_StreamOutput)
        {
            return kAudioHardwareBadStreamError;
        }
        if ((cycleInfo == NULL) || !GPT_HasValidSampleTime(&cycleInfo->mOutputTime))
        {
            return kAudioHardwareNoError;
        }
        GPT_RingWrite((const Float32 *)mainBuffer, frameCount,
                      cycleInfo->mOutputTime.mSampleTime);
        return kAudioHardwareNoError;
    }
    return kAudioHardwareNoError;
}

static OSStatus GPT_EndIOOperation(AudioServerPlugInDriverRef driver, AudioObjectID deviceObjectID,
                                   UInt32 clientID, UInt32 operationID, UInt32 frameCount,
                                   const AudioServerPlugInIOCycleInfo *cycleInfo)
{
    (void)clientID;
    (void)operationID;
    (void)frameCount;
    (void)cycleInfo;
    return (!GPT_IsDriver(driver) || (deviceObjectID != kGPTObjectID_Device))
        ? kAudioHardwareBadObjectError : kAudioHardwareNoError;
}
