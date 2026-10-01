#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <stdio.h>

static AudioObjectID DeviceForUID(CFStringRef uid)
{
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    const OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        sizeof(uid),
        &uid,
        &size,
        &deviceID
    );
    return status == noErr ? deviceID : kAudioObjectUnknown;
}

static UInt32 UInt32Property(
    AudioObjectID deviceID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope
)
{
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 value = UINT32_MAX;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &value) != noErr)
    {
        return UINT32_MAX;
    }
    return value;
}

static void PrintDevice(const char *label, CFStringRef uid)
{
    const AudioObjectID deviceID = DeviceForUID(uid);
    printf(
        "%s: id=%u alive=%u running=%u hidden=%u canDefaultInput=%u\n",
        label,
        deviceID,
        UInt32Property(deviceID, kAudioDevicePropertyDeviceIsAlive,
                       kAudioObjectPropertyScopeGlobal),
        UInt32Property(deviceID, kAudioDevicePropertyDeviceIsRunning,
                       kAudioObjectPropertyScopeGlobal),
        UInt32Property(deviceID, kAudioDevicePropertyIsHidden,
                       kAudioObjectPropertyScopeGlobal),
        UInt32Property(deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                       kAudioObjectPropertyScopeInput)
    );
}

int main(void)
{
    AudioObjectPropertyAddress defaultAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID defaultInput = kAudioObjectUnknown;
    UInt32 defaultSize = sizeof(defaultInput);
    (void)AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultAddress,
                                     0, NULL, &defaultSize, &defaultInput);
    printf("default-input: id=%u\n", defaultInput);
    PrintDevice("to-chatgpt", CFSTR("jp.local.gptcallmixer.to-chatgpt.device"));
    PrintDevice("to-call", CFSTR("jp.local.gptcallmixer.to-call.device"));
    return 0;
}
