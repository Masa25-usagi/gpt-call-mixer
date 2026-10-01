#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

static NSArray<NSNumber *> *AudioObjectIDList(AudioObjectID objectID,
                                               AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(objectID, &address, 0, NULL, &size);
    if (status != noErr || size == 0) {
        return @[];
    }

    NSUInteger count = size / sizeof(AudioObjectID);
    AudioObjectID *values = calloc(count, sizeof(AudioObjectID));
    status = AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, values);
    if (status != noErr) {
        free(values);
        return @[];
    }

    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [result addObject:@(values[index])];
    }
    free(values);
    return result;
}

static id CopyObjectProperty(AudioObjectID objectID,
                             AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(CFTypeRef);
    CFTypeRef value = NULL;
    OSStatus status = AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, &value);
    if (status != noErr || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static AudioStreamBasicDescription TapFormat(AudioObjectID tapID) {
    AudioObjectPropertyAddress address = {
        kAudioTapPropertyFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    AudioObjectGetPropertyData(tapID, &address, 0, NULL, &size, &format);
    return format;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL removeOrphans = argc == 2 && strcmp(argv[1], "--remove-orphans") == 0;
        NSArray<NSNumber *> *tapIDs = AudioObjectIDList(
            kAudioObjectSystemObject,
            kAudioHardwarePropertyTapList
        );
        NSArray<NSNumber *> *deviceIDs = AudioObjectIDList(
            kAudioObjectSystemObject,
            kAudioHardwarePropertyDevices
        );
        NSMutableSet<NSString *> *activeTapUIDs = [NSMutableSet set];
        for (NSNumber *deviceNumber in deviceIDs) {
            AudioObjectID deviceID = deviceNumber.unsignedIntValue;
            NSString *deviceUID = CopyObjectProperty(deviceID, kAudioDevicePropertyDeviceUID);
            if (![deviceUID hasPrefix:@"jp.local.meetvoicebridge."]) {
                continue;
            }
            NSArray<NSString *> *tapUIDs = CopyObjectProperty(
                deviceID,
                kAudioAggregateDevicePropertyTapList
            );
            if ([tapUIDs isKindOfClass:NSArray.class]) {
                [activeTapUIDs addObjectsFromArray:tapUIDs];
            }
        }
        printf("tap-count=%lu\n", (unsigned long)tapIDs.count);

        for (NSNumber *tapNumber in tapIDs) {
            AudioObjectID tapID = tapNumber.unsignedIntValue;
            CATapDescription *description = CopyObjectProperty(
                tapID,
                kAudioTapPropertyDescription
            );
            NSString *uid = CopyObjectProperty(tapID, kAudioTapPropertyUID);
            AudioStreamBasicDescription format = TapFormat(tapID);

            printf("tap=%u uid=%s name=%s\n",
                   tapID,
                   uid.UTF8String ?: "",
                   description.name.UTF8String ?: "");
            printf("  processes=%s\n", description.processes.description.UTF8String ?: "[]");
            if (@available(macOS 26.0, *)) {
                printf("  bundleIDs=%s restore=%d\n",
                       description.bundleIDs.description.UTF8String ?: "[]",
                       description.isProcessRestoreEnabled);
            }
            printf("  exclusive=%d mixdown=%d mono=%d private=%d mute=%ld\n",
                   description.isExclusive,
                   description.isMixdown,
                   description.isMono,
                   description.isPrivate,
                   (long)description.muteBehavior);
            printf("  format=%.0fHz channels=%u flags=0x%x bytesPerFrame=%u\n",
                   format.mSampleRate,
                   format.mChannelsPerFrame,
                   format.mFormatFlags,
                   format.mBytesPerFrame);

            if (removeOrphans
                && [description.name hasPrefix:@"MVB "]
                && ![activeTapUIDs containsObject:uid]) {
                OSStatus status = AudioHardwareDestroyProcessTap(tapID);
                printf("  remove-orphan status=%d\n", status);
            }
        }

        puts("MVB aggregate devices:");
        for (NSNumber *deviceNumber in deviceIDs) {
            AudioObjectID deviceID = deviceNumber.unsignedIntValue;
            NSString *uid = CopyObjectProperty(deviceID, kAudioDevicePropertyDeviceUID);
            if (![uid hasPrefix:@"jp.local.meetvoicebridge."]) {
                continue;
            }
            NSString *name = CopyObjectProperty(deviceID, kAudioObjectPropertyName);
            NSArray<NSNumber *> *subTaps = AudioObjectIDList(
                deviceID,
                kAudioAggregateDevicePropertySubTapList
            );
            id tapUIDs = CopyObjectProperty(
                deviceID,
                kAudioAggregateDevicePropertyTapList
            );
            printf("  device=%u uid=%s name=%s subtaps=%s tapUIDs=%s\n",
                   deviceID,
                   uid.UTF8String ?: "",
                   name.UTF8String ?: "",
                   subTaps.description.UTF8String ?: "[]",
                   [tapUIDs description].UTF8String ?: "[]");
        }
    }
    return 0;
}
