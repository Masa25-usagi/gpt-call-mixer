#import "GPTCallMixerEngine.h"
#import "AudioRingBuffer.hpp"

#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <libproc.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <unistd.h>
#include <vector>

static NSString *const GPTCallMixerErrorDomain = @"jp.local.gptcallmixer";
static constexpr double kMixerSampleRate = 48000.0;
static constexpr UInt32 kMaximumCallbackFrames = 8192;
static constexpr UInt32 kMaximumResampledFrames = 16384;

@implementation GPTAudioCandidate
@end

namespace {

NSError *MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:GPTCallMixerErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

std::string FourCC(OSStatus status) {
    UInt32 value = static_cast<UInt32>(status);
    char text[5] = {
        static_cast<char>((value >> 24) & 0xff),
        static_cast<char>((value >> 16) & 0xff),
        static_cast<char>((value >> 8) & 0xff),
        static_cast<char>(value & 0xff),
        0
    };
    for (int index = 0; index < 4; ++index) {
        if (text[index] < 32 || text[index] > 126) return std::to_string(status);
    }
    return std::to_string(status) + " ('" + text + "')";
}

template <typename T>
bool GetScalar(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    T &value
) {
    AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(objectID, &address, 0, nullptr, &size, &value) == noErr;
}

std::vector<AudioObjectID> GetObjectIDArray(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal
) {
    AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(objectID, &address, 0, nullptr, &size) != noErr || size == 0) {
        return {};
    }
    std::vector<AudioObjectID> values(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(objectID, &address, 0, nullptr, &size, values.data()) != noErr) {
        return {};
    }
    return values;
}

NSString *GetString(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(objectID, &address, 0, nullptr, &size, &value) != noErr || value == nullptr) {
        return @"";
    }
    return CFBridgingRelease(value);
}

UInt32 ChannelCount(AudioObjectID deviceID, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &address, 0, nullptr, &size) != noErr || size == 0) {
        return 0;
    }
    std::vector<std::byte> storage(size);
    auto *list = reinterpret_cast<AudioBufferList *>(storage.data());
    if (AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, list) != noErr) return 0;
    UInt32 count = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; ++index) {
        count += list->mBuffers[index].mNumberChannels;
    }
    return count;
}

OSStatus SetIOProcStreamUsage(
    AudioObjectID deviceID,
    AudioDeviceIOProcID ioProcID,
    AudioObjectPropertyScope scope,
    bool enabled
) {
    const auto streams = GetObjectIDArray(
        deviceID,
        kAudioDevicePropertyStreams,
        scope
    );
    if (streams.empty()) return noErr;

    const size_t byteCount = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn)
        + streams.size() * sizeof(UInt32);
    std::vector<std::byte> storage(byteCount);
    auto *usage = reinterpret_cast<AudioHardwareIOProcStreamUsage *>(storage.data());
    usage->mIOProc = reinterpret_cast<void *>(ioProcID);
    usage->mNumberStreams = static_cast<UInt32>(streams.size());
    for (size_t index = 0; index < streams.size(); ++index) {
        usage->mStreamIsOn[index] = enabled ? 1u : 0u;
    }

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyIOProcStreamUsage,
        scope,
        kAudioObjectPropertyElementMain
    };
    return AudioObjectSetPropertyData(
        deviceID,
        &address,
        0,
        nullptr,
        static_cast<UInt32>(byteCount),
        usage
    );
}

AudioObjectID DeviceForUID(NSString *targetUID) {
    for (auto deviceID : GetObjectIDArray(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)) {
        if ([GetString(deviceID, kAudioDevicePropertyDeviceUID) isEqualToString:targetUID]) return deviceID;
    }
    return kAudioObjectUnknown;
}

NSString *ProcessFamilyKey(GPTAudioCandidate *candidate) {
    NSString *value = [NSString stringWithFormat:@"%@ %@ %@", candidate.bundleID, candidate.name, candidate.detail].lowercaseString;
    if ([value containsString:@"com.google.chrome"] || [value containsString:@"/google chrome.app/"]
        || [value containsString:@"google chrome helper"]) return @"browser.chrome";
    if ([value containsString:@"com.apple.safari"] || [value containsString:@"/safari.app/"]
        || [value containsString:@"safari webkit"]
        || [candidate.name.lowercaseString isEqualToString:@"safari graphics and media"]) return @"browser.safari";
    if ([value containsString:@"org.mozilla.firefox"] || [value containsString:@"/firefox.app/"]) return @"browser.firefox";
    if ([value containsString:@"com.microsoft.edgemac"] || [value containsString:@"/microsoft edge.app/"]) return @"browser.edge";
    if ([value containsString:@"com.brave.browser"] || [value containsString:@"/brave browser.app/"]) return @"browser.brave";
    if ([value containsString:@"company.thebrowser.browser"] || [value containsString:@"/arc.app/"]) return @"browser.arc";
    if ([value containsString:@"com.operasoftware.opera"] || [value containsString:@"/opera.app/"]) return @"browser.opera";
    if ([value containsString:@"com.vivaldi.vivaldi"] || [value containsString:@"/vivaldi.app/"]) return @"browser.vivaldi";
    if ([value containsString:@"com.hnc.discord"] || [value containsString:@"com.discordapp.discord"]
        || [value containsString:@"com.discord.discord"] || [value containsString:@"/discord.app/"]) return @"call.discord";
    if ([value containsString:@"com.tinyspeck.slackmacgap"] || [value containsString:@"/slack.app/"]
        || [value containsString:@"slack helper"]) return @"call.slack";
    if ([value containsString:@"com.openai.codex"] || [value containsString:@"com.openai.chatgpt"]
        || [value containsString:@"com.openai.chat"] || [value containsString:@"/chatgpt.app/"]
        || [value containsString:@"/codex.app/"]) return @"gpt.desktop";
    return @"";
}

NSString *ProcessFamilyName(NSString *key, NSString *fallback) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"browser.chrome": @"Google Chrome（ブラウザ全体）",
        @"browser.safari": @"Safari（ブラウザ全体）",
        @"browser.firefox": @"Firefox（ブラウザ全体）",
        @"browser.edge": @"Microsoft Edge（ブラウザ全体）",
        @"browser.brave": @"Brave（ブラウザ全体）",
        @"browser.arc": @"Arc（ブラウザ全体）",
        @"browser.opera": @"Opera（ブラウザ全体）",
        @"browser.vivaldi": @"Vivaldi（ブラウザ全体）",
        @"call.discord": @"Discord（アプリ全体）",
        @"call.slack": @"Slack（アプリ全体・ハドル）",
        @"gpt.desktop": @"ChatGPT / Codex（アプリ全体）"
    };
    return names[key] ?: fallback;
}

NSArray<NSNumber *> *CurrentProcessObjectIDsForFamily(
    NSString *targetFamily,
    NSArray<NSNumber *> *fallbackObjectIDs
) {
    NSMutableArray<NSNumber *> *matches = [NSMutableArray array];
    NSSet<NSNumber *> *fallback = [NSSet setWithArray:fallbackObjectIDs ?: @[]];
    for (auto processID : GetObjectIDArray(
        kAudioObjectSystemObject,
        kAudioHardwarePropertyProcessObjectList
    )) {
        pid_t pid = -1;
        if (!GetScalar(processID, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid)
            || pid <= 0) continue;

        GPTAudioCandidate *candidate = [GPTAudioCandidate new];
        candidate.objectID = processID;
        candidate.pid = pid;
        candidate.bundleID = GetString(processID, kAudioProcessPropertyBundleID);
        NSRunningApplication *application =
            [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        candidate.name = application.localizedName ?: [NSString stringWithFormat:@"PID %d", pid];
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {};
        const int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
        candidate.detail = pathLength > 0
            ? [NSString stringWithUTF8String:pathBuffer]
            : @"";

        NSString *family = ProcessFamilyKey(candidate);
        NSString *resolvedFamily = family.length
            ? family
            : [NSString stringWithFormat:@"process.%u", processID];
        if ((targetFamily.length > 0 && [resolvedFamily isEqualToString:targetFamily])
            || (targetFamily.length == 0 && [fallback containsObject:@(processID)])) {
            [matches addObject:@(processID)];
        }
    }
    return matches;
}

bool ValidateDeviceBufferSize(AudioObjectID deviceID, NSString *label, NSError **error) {
    UInt32 frames = 0;
    if (!GetScalar(
        deviceID,
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        frames
    )) {
        if (error) *error = MakeError(33, [NSString stringWithFormat:@"%@のバッファサイズを取得できません", label]);
        return false;
    }
    if (frames == 0 || frames > kMaximumCallbackFrames) {
        if (error) *error = MakeError(34, [NSString stringWithFormat:@"%@のバッファは%u framesです。対応上限は%u framesです。", label, frames, kMaximumCallbackFrames]);
        return false;
    }
    return true;
}

bool ValidateFloatDeviceFormat(
    AudioObjectID deviceID,
    AudioObjectPropertyScope scope,
    NSString *label,
    bool requireMixerRate,
    NSError **error
) {
    AudioStreamBasicDescription format{};
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamFormat, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(format);
    const OSStatus status = AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, &format);
    if (status != noErr) {
        if (error) *error = MakeError(30, [NSString stringWithFormat:@"%@の音声形式を取得できません（%s）", label, FourCC(status).c_str()]);
        return false;
    }
    const bool isNonInterleaved =
        (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const UInt32 expectedBytesPerFrame = static_cast<UInt32>(sizeof(float))
        * (isNonInterleaved ? 1U : format.mChannelsPerFrame);
    const bool isFloat32PCM = format.mFormatID == kAudioFormatLinearPCM
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0
        && (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
        && (format.mFormatFlags & kAudioFormatFlagsNativeEndian) == kAudioFormatFlagsNativeEndian
        && format.mBitsPerChannel == 32
        && format.mChannelsPerFrame > 0
        && format.mFramesPerPacket == 1
        && format.mBytesPerFrame == expectedBytesPerFrame
        && format.mBytesPerPacket == expectedBytesPerFrame;
    if (!isFloat32PCM) {
        if (error) *error = MakeError(31, [NSString stringWithFormat:@"%@は対応するFloat32 PCM形式ではありません。32-bit packed native-endian PCMが必要です。", label]);
        return false;
    }
    if (requireMixerRate && std::fabs(format.mSampleRate - kMixerSampleRate) > 1.0) {
        if (error) *error = MakeError(32, [NSString stringWithFormat:@"%@は%.0f Hzです。Audio MIDI設定で48,000 Hzへ変更してください。", label, format.mSampleRate]);
        return false;
    }
    return true;
}

struct SourceCapture {
    AudioObjectID deviceID = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProcID = nullptr;
    std::vector<AudioRingBuffer *> destinations;
    double sourceSampleRate = kMixerSampleRate;
    double nextSourceFrame = 0.0;
    std::array<float, kMaximumCallbackFrames * 2> inputScratch{};
    std::array<float, kMaximumResampledFrames * 2> outputScratch{};

    static OSStatus Callback(
        AudioObjectID,
        const AudioTimeStamp *,
        const AudioBufferList *input,
        const AudioTimeStamp *,
        AudioBufferList *,
        const AudioTimeStamp *,
        void *context
    ) {
        auto *self = static_cast<SourceCapture *>(context);
        if (self == nullptr || input == nullptr || input->mNumberBuffers == 0) return noErr;

        const AudioBuffer &first = input->mBuffers[0];
        UInt32 frames = 0;
        if (input->mNumberBuffers >= 2
            && input->mBuffers[0].mNumberChannels == 1
            && input->mBuffers[1].mNumberChannels == 1) {
            const AudioBuffer &leftBuffer = input->mBuffers[0];
            const AudioBuffer &rightBuffer = input->mBuffers[1];
            if (leftBuffer.mData == nullptr || rightBuffer.mData == nullptr
                || leftBuffer.mDataByteSize % sizeof(float) != 0
                || rightBuffer.mDataByteSize % sizeof(float) != 0) return noErr;
            const UInt32 leftFrames = leftBuffer.mDataByteSize / sizeof(float);
            const UInt32 rightFrames = rightBuffer.mDataByteSize / sizeof(float);
            frames = std::min(leftFrames, rightFrames);
            if (frames == 0 || frames > kMaximumCallbackFrames) return noErr;
            const auto *left = static_cast<const float *>(leftBuffer.mData);
            const auto *right = static_cast<const float *>(rightBuffer.mData);
            for (UInt32 frame = 0; frame < frames; ++frame) {
                self->inputScratch[frame * 2] = left[frame];
                self->inputScratch[frame * 2 + 1] = right[frame];
            }
        } else {
            if (first.mData == nullptr || first.mNumberChannels == 0) return noErr;
            const UInt32 bytesPerFrame = static_cast<UInt32>(sizeof(float))
                * first.mNumberChannels;
            if (first.mDataByteSize % bytesPerFrame != 0) return noErr;
            frames = first.mDataByteSize / bytesPerFrame;
            if (frames == 0 || frames > kMaximumCallbackFrames) return noErr;
            const auto *samples = static_cast<const float *>(first.mData);
            for (UInt32 frame = 0; frame < frames; ++frame) {
                const float left = samples[frame * first.mNumberChannels];
                const float right = first.mNumberChannels > 1
                    ? samples[frame * first.mNumberChannels + 1]
                    : left;
                self->inputScratch[frame * 2] = left;
                self->inputScratch[frame * 2 + 1] = right;
            }
        }

        UInt32 outputFrames = frames;
        const float *output = self->inputScratch.data();
        if (std::fabs(self->sourceSampleRate - kMixerSampleRate) > 1.0) {
            const double step = self->sourceSampleRate / kMixerSampleRate;
            double position = self->nextSourceFrame;
            outputFrames = 0;
            while (position < static_cast<double>(frames)
                   && outputFrames < kMaximumResampledFrames) {
                const UInt32 sourceFrame = std::min<UInt32>(
                    static_cast<UInt32>(position), frames - 1);
                self->outputScratch[outputFrames * 2] =
                    self->inputScratch[sourceFrame * 2];
                self->outputScratch[outputFrames * 2 + 1] =
                    self->inputScratch[sourceFrame * 2 + 1];
                ++outputFrames;
                position += step;
            }
            self->nextSourceFrame = position - static_cast<double>(frames);
            output = self->outputScratch.data();
        }

        for (auto *destination : self->destinations) {
            destination->writeInterleaved(output, outputFrames, 2);
        }
        return noErr;
    }

    bool start(AudioObjectID newDeviceID, std::vector<AudioRingBuffer *> rings, NSError **error) {
        deviceID = newDeviceID;
        destinations = std::move(rings);
        AudioStreamBasicDescription format{};
        if (GetScalar(deviceID, kAudioDevicePropertyStreamFormat,
                      kAudioObjectPropertyScopeInput, format)
            && format.mSampleRate > 1.0) {
            sourceSampleRate = format.mSampleRate;
        } else {
            sourceSampleRate = kMixerSampleRate;
        }
        nextSourceFrame = 0.0;
        OSStatus status = AudioDeviceCreateIOProcID(deviceID, Callback, this, &ioProcID);
        NSString *failureStage = @"入力IOProcの作成";
        if (status == noErr) {
            failureStage = @"入力IOProcの出力ストリーム無効化";
            status = SetIOProcStreamUsage(
                deviceID,
                ioProcID,
                kAudioObjectPropertyScopeOutput,
                false
            );
        }
        if (status == noErr) {
            failureStage = @"入力IOProcの開始";
            status = AudioDeviceStart(deviceID, ioProcID);
        }
        if (status != noErr) {
            if (ioProcID != nullptr) {
                const OSStatus cleanupStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID);
                if (cleanupStatus != noErr) {
                    if (error) *error = MakeError(42, [NSString stringWithFormat:@"入力IOProcの後始末に失敗しました（%s）", FourCC(cleanupStatus).c_str()]);
                    return false;
                }
                ioProcID = nullptr;
            }
            deviceID = kAudioObjectUnknown;
            destinations.clear();
            sourceSampleRate = kMixerSampleRate;
            nextSourceFrame = 0.0;
            if (error) *error = MakeError(40, [NSString stringWithFormat:@"%@に失敗しました（%s）", failureStage, FourCC(status).c_str()]);
            return false;
        }
        return true;
    }

    bool stop(NSError **error = nullptr, bool *quiesced = nullptr) {
        if (quiesced) *quiesced = false;
        OSStatus stopStatus = noErr;
        if (ioProcID != nullptr && deviceID != kAudioObjectUnknown) {
            stopStatus = AudioDeviceStop(deviceID, ioProcID);
            const OSStatus destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID);
            if (destroyStatus != noErr) {
                if (error) *error = MakeError(43, [NSString stringWithFormat:@"入力IOProcを破棄できません（%s）", FourCC(destroyStatus).c_str()]);
                return false;
            }
        }
        ioProcID = nullptr;
        deviceID = kAudioObjectUnknown;
        destinations.clear();
        sourceSampleRate = kMixerSampleRate;
        nextSourceFrame = 0.0;
        if (quiesced) *quiesced = true;
        if (stopStatus != noErr) {
            if (error) *error = MakeError(46, [NSString stringWithFormat:@"入力IOProcの停止でエラーが発生しました（%s）。IOProc自体は破棄済みです。", FourCC(stopStatus).c_str()]);
            return false;
        }
        return true;
    }
};

struct TargetOutput {
    AudioObjectID deviceID = kAudioObjectUnknown;
    AudioDeviceIOProcID ioProcID = nullptr;
    AudioRingBuffer *first = nullptr;
    AudioRingBuffer *second = nullptr;
    std::array<float, kMaximumCallbackFrames * 2> scratch{};

    static void Silence(AudioBufferList *output) noexcept {
        if (output == nullptr) return;
        for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
            AudioBuffer &buffer = output->mBuffers[index];
            if (buffer.mData != nullptr && buffer.mDataByteSize > 0) {
                std::memset(buffer.mData, 0, buffer.mDataByteSize);
            }
        }
    }

    static OSStatus Callback(
        AudioObjectID,
        const AudioTimeStamp *,
        const AudioBufferList *,
        const AudioTimeStamp *,
        AudioBufferList *output,
        const AudioTimeStamp *,
        void *context
    ) {
        auto *self = static_cast<TargetOutput *>(context);
        if (self == nullptr || output == nullptr || output->mNumberBuffers == 0) return noErr;
        Silence(output);

        AudioBuffer &firstBuffer = output->mBuffers[0];
        UInt32 frames = 0;
        const bool isPlanarStereo = output->mNumberBuffers >= 2
            && output->mBuffers[0].mNumberChannels == 1
            && output->mBuffers[1].mNumberChannels == 1;
        if (isPlanarStereo) {
            const AudioBuffer &secondBuffer = output->mBuffers[1];
            if (firstBuffer.mData == nullptr || secondBuffer.mData == nullptr
                || firstBuffer.mDataByteSize % sizeof(float) != 0
                || secondBuffer.mDataByteSize % sizeof(float) != 0) return noErr;
            frames = std::min(
                firstBuffer.mDataByteSize / static_cast<UInt32>(sizeof(float)),
                secondBuffer.mDataByteSize / static_cast<UInt32>(sizeof(float))
            );
        } else {
            if (firstBuffer.mData == nullptr || firstBuffer.mNumberChannels == 0) return noErr;
            const UInt32 bytesPerFrame = static_cast<UInt32>(sizeof(float))
                * firstBuffer.mNumberChannels;
            if (firstBuffer.mDataByteSize % bytesPerFrame != 0) return noErr;
            frames = firstBuffer.mDataByteSize / bytesPerFrame;
        }
        if (frames == 0 || frames > kMaximumCallbackFrames) return noErr;

        std::fill_n(self->scratch.data(), frames * 2, 0.0f);
        if (self->first) self->first->addToInterleaved(self->scratch.data(), frames);
        if (self->second) self->second->addToInterleaved(self->scratch.data(), frames);

        // Conservative headroom for two summed sources.
        for (UInt32 index = 0; index < frames * 2; ++index) {
            self->scratch[index] = std::clamp(self->scratch[index] * 0.7f, -1.0f, 1.0f);
        }

        if (isPlanarStereo) {
            auto *left = static_cast<float *>(output->mBuffers[0].mData);
            auto *right = static_cast<float *>(output->mBuffers[1].mData);
            for (UInt32 frame = 0; frame < frames; ++frame) {
                left[frame] = self->scratch[frame * 2];
                right[frame] = self->scratch[frame * 2 + 1];
            }
        } else if (firstBuffer.mData != nullptr) {
            auto *destination = static_cast<float *>(firstBuffer.mData);
            const UInt32 channels = firstBuffer.mNumberChannels;
            for (UInt32 frame = 0; frame < frames; ++frame) {
                destination[frame * channels] = self->scratch[frame * 2];
                if (channels > 1) destination[frame * channels + 1] = self->scratch[frame * 2 + 1];
                for (UInt32 channel = 2; channel < channels; ++channel) {
                    destination[frame * channels + channel] = 0.0f;
                }
            }
        }
        return noErr;
    }

    bool start(AudioObjectID newDeviceID, AudioRingBuffer *a, AudioRingBuffer *b, NSError **error) {
        deviceID = newDeviceID;
        first = a;
        second = b;
        OSStatus status = AudioDeviceCreateIOProcID(deviceID, Callback, this, &ioProcID);
        NSString *failureStage = @"仮想出力IOProcの作成";
        if (status == noErr) {
            failureStage = @"仮想出力IOProcの入力ストリーム無効化";
            status = SetIOProcStreamUsage(
                deviceID,
                ioProcID,
                kAudioObjectPropertyScopeInput,
                false
            );
        }
        if (status == noErr) {
            failureStage = @"仮想出力IOProcの開始";
            status = AudioDeviceStart(deviceID, ioProcID);
        }
        if (status != noErr) {
            if (ioProcID != nullptr) {
                const OSStatus cleanupStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID);
                if (cleanupStatus != noErr) {
                    if (error) *error = MakeError(44, [NSString stringWithFormat:@"出力IOProcの後始末に失敗しました（%s）", FourCC(cleanupStatus).c_str()]);
                    return false;
                }
                ioProcID = nullptr;
            }
            deviceID = kAudioObjectUnknown;
            first = nullptr;
            second = nullptr;
            if (error) *error = MakeError(41, [NSString stringWithFormat:@"%@に失敗しました（%s）", failureStage, FourCC(status).c_str()]);
            return false;
        }
        return true;
    }

    bool stop(NSError **error = nullptr, bool *quiesced = nullptr) {
        if (quiesced) *quiesced = false;
        OSStatus stopStatus = noErr;
        if (ioProcID != nullptr && deviceID != kAudioObjectUnknown) {
            stopStatus = AudioDeviceStop(deviceID, ioProcID);
            const OSStatus destroyStatus = AudioDeviceDestroyIOProcID(deviceID, ioProcID);
            if (destroyStatus != noErr) {
                if (error) *error = MakeError(45, [NSString stringWithFormat:@"出力IOProcを破棄できません（%s）", FourCC(destroyStatus).c_str()]);
                return false;
            }
        }
        ioProcID = nullptr;
        deviceID = kAudioObjectUnknown;
        first = nullptr;
        second = nullptr;
        if (quiesced) *quiesced = true;
        if (stopStatus != noErr) {
            if (error) *error = MakeError(47, [NSString stringWithFormat:@"出力IOProcの停止でエラーが発生しました（%s）。IOProc自体は破棄済みです。", FourCC(stopStatus).c_str()]);
            return false;
        }
        return true;
    }
};

struct TapCapture {
    AudioObjectID tapID = kAudioObjectUnknown;
    AudioObjectID aggregateID = kAudioObjectUnknown;
    SourceCapture source;

    bool create(NSArray<NSNumber *> *processObjectIDs, NSString *name, NSError **error) {
        if (processObjectIDs.count == 0) {
            if (error) *error = MakeError(49, [NSString stringWithFormat:@"%@の音声プロセスがありません", name]);
            return false;
        }
        CATapDescription *description = [[CATapDescription alloc]
            initStereoMixdownOfProcesses:processObjectIDs];
        description.name = [name stringByAppendingString:@" Process Tap"];
        description.UUID = [NSUUID UUID];
        description.privateTap = YES;
        description.muteBehavior = CATapUnmuted;
        description.exclusive = NO;
        description.mixdown = YES;
        description.mono = NO;

        OSStatus status = AudioHardwareCreateProcessTap(description, &tapID);
        if (status != noErr || tapID == kAudioObjectUnknown) {
            if (error) *error = MakeError(50, [NSString stringWithFormat:@"%@のProcess Tapを作成できません（%s）", name, FourCC(status).c_str()]);
            return false;
        }

        NSString *uid = [NSString stringWithFormat:@"jp.local.gptcallmixer.tap.%@", description.UUID.UUIDString.lowercaseString];
        NSDictionary *tapEntry = @{
            [NSString stringWithUTF8String:kAudioSubTapUIDKey]: description.UUID.UUIDString,
            [NSString stringWithUTF8String:kAudioSubTapDriftCompensationKey]: @YES
        };
        NSDictionary *aggregate = @{
            [NSString stringWithUTF8String:kAudioAggregateDeviceNameKey]: name,
            [NSString stringWithUTF8String:kAudioAggregateDeviceUIDKey]: uid,
            [NSString stringWithUTF8String:kAudioAggregateDeviceIsPrivateKey]: @YES,
            [NSString stringWithUTF8String:kAudioAggregateDeviceIsStackedKey]: @NO,
            [NSString stringWithUTF8String:kAudioAggregateDeviceTapListKey]: @[tapEntry]
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &aggregateID);
        if (status != noErr || aggregateID == kAudioObjectUnknown) {
            const OSStatus cleanupStatus = AudioHardwareDestroyProcessTap(tapID);
            if (cleanupStatus == noErr) {
                tapID = kAudioObjectUnknown;
            } else {
                if (error) *error = MakeError(54, [NSString stringWithFormat:@"%@のTap入力デバイス作成に失敗し、Process Tapの後始末にも失敗しました（作成: %s、後始末: %s）", name, FourCC(status).c_str(), FourCC(cleanupStatus).c_str()]);
                return false;
            }
            if (error) *error = MakeError(51, [NSString stringWithFormat:@"%@のTap入力デバイスを作成できません（%s）", name, FourCC(status).c_str()]);
            return false;
        }
        return true;
    }

    bool destroy(NSError **error = nullptr) {
        if (!source.stop(error)) return false;
        if (aggregateID != kAudioObjectUnknown) {
            const OSStatus status = AudioHardwareDestroyAggregateDevice(aggregateID);
            if (status != noErr) {
                if (error) *error = MakeError(52, [NSString stringWithFormat:@"Tap入力デバイスを破棄できません（%s）", FourCC(status).c_str()]);
                return false;
            }
            aggregateID = kAudioObjectUnknown;
        }
        if (tapID != kAudioObjectUnknown) {
            const OSStatus status = AudioHardwareDestroyProcessTap(tapID);
            if (status != noErr) {
                if (error) *error = MakeError(53, [NSString stringWithFormat:@"Process Tapを破棄できません（%s）", FourCC(status).c_str()]);
                return false;
            }
            tapID = kAudioObjectUnknown;
        }
        return true;
    }
};

struct MixerImplementation {
    AudioRingBuffer micToGPT;
    AudioRingBuffer micToCall;
    AudioRingBuffer callToGPT;
    AudioRingBuffer gptToCall;
    SourceCapture microphone;
    TapCapture callTap;
    TapCapture gptTap;
    TargetOutput toGPT;
    TargetOutput toCall;
    bool running = false;

    bool start(
        AudioObjectID microphoneID,
        NSArray<NSNumber *> *callProcessIDs,
        NSArray<NSNumber *> *gptProcessIDs,
        NSError **error
    ) {
        if (!stop(error)) return false;
        NSMutableSet<NSNumber *> *overlap = [NSMutableSet setWithArray:callProcessIDs];
        [overlap intersectSet:[NSSet setWithArray:gptProcessIDs]];
        if (overlap.count > 0) {
            if (error) *error = MakeError(60, @"通話側とGPT側が同じ音声プロセスです。Chrome同士は分離できないため、MeetをChrome、Web VoiceをSafariにしてください。");
            return false;
        }

        const AudioObjectID toGPTDevice = DeviceForUID([GPTCallMixerEngine toChatGPTDeviceUID]);
        const AudioObjectID toCallDevice = DeviceForUID([GPTCallMixerEngine toCallDeviceUID]);
        if (toGPTDevice == kAudioObjectUnknown || toCallDevice == kAudioObjectUnknown) {
            if (error) *error = MakeError(61, @"GPT Call Mixerの2つの仮想デバイスがありません。ドライバを検証・導入してから再試行してください。");
            return false;
        }

        if (!ValidateFloatDeviceFormat(microphoneID, kAudioObjectPropertyScopeInput, @"マイク", false, error)
            || !ValidateFloatDeviceFormat(toGPTDevice, kAudioObjectPropertyScopeOutput, @"GPT用仮想デバイス", true, error)
            || !ValidateFloatDeviceFormat(toCallDevice, kAudioObjectPropertyScopeOutput, @"通話用仮想デバイス", true, error)
            || !ValidateDeviceBufferSize(microphoneID, @"マイク", error)
            || !ValidateDeviceBufferSize(toGPTDevice, @"GPT用仮想デバイス", error)
            || !ValidateDeviceBufferSize(toCallDevice, @"通話用仮想デバイス", error)) {
            return false;
        }

        micToGPT.reset();
        micToCall.reset();
        callToGPT.reset();
        gptToCall.reset();

        if (!callTap.create(callProcessIDs, @"GPT Call Mixer Call Capture", error)) goto failed;
        if (!gptTap.create(gptProcessIDs, @"GPT Call Mixer GPT Capture", error)) goto failed;
        if (!ValidateFloatDeviceFormat(callTap.aggregateID, kAudioObjectPropertyScopeInput, @"通話アプリ音声", false, error)
            || !ValidateFloatDeviceFormat(gptTap.aggregateID, kAudioObjectPropertyScopeInput, @"GPT音声", false, error)
            || !ValidateDeviceBufferSize(callTap.aggregateID, @"通話アプリ音声", error)
            || !ValidateDeviceBufferSize(gptTap.aggregateID, @"GPT音声", error)) goto failed;

        if (!toGPT.start(toGPTDevice, &micToGPT, &callToGPT, error)) goto failed;
        if (!toCall.start(toCallDevice, &micToCall, &gptToCall, error)) goto failed;
        if (!microphone.start(microphoneID, {&micToGPT, &micToCall}, error)) goto failed;
        if (!callTap.source.start(callTap.aggregateID, {&callToGPT}, error)) goto failed;
        if (!gptTap.source.start(gptTap.aggregateID, {&gptToCall}, error)) goto failed;

        running = true;
        return true;

    failed:
        {
            NSError *cleanupError = nil;
            if (!stop(&cleanupError) && error) *error = cleanupError;
        }
        return false;
    }

    bool stop(
        NSError **error = nullptr,
        bool *quiesced = nullptr,
        bool *resourcesReleased = nullptr
    ) {
        bool succeeded = true;
        bool allIOQuiesced = true;
        NSError *firstError = nil;
        auto record = [&](bool result, NSError *candidate) {
            if (!result) {
                succeeded = false;
                if (firstError == nil) firstError = candidate;
            }
        };

        NSError *candidate = nil;
        bool gptSourceQuiesced = false;
        const bool gptSourceStopped = gptTap.source.stop(&candidate, &gptSourceQuiesced);
        record(gptSourceStopped, candidate);
        allIOQuiesced = allIOQuiesced && gptSourceQuiesced;
        candidate = nil;
        bool callSourceQuiesced = false;
        const bool callSourceStopped = callTap.source.stop(&candidate, &callSourceQuiesced);
        record(callSourceStopped, candidate);
        allIOQuiesced = allIOQuiesced && callSourceQuiesced;
        candidate = nil;
        bool microphoneQuiesced = false;
        const bool microphoneStopped = microphone.stop(&candidate, &microphoneQuiesced);
        record(microphoneStopped, candidate);
        allIOQuiesced = allIOQuiesced && microphoneQuiesced;
        candidate = nil;
        bool toCallQuiesced = false;
        const bool toCallStopped = toCall.stop(&candidate, &toCallQuiesced);
        record(toCallStopped, candidate);
        allIOQuiesced = allIOQuiesced && toCallQuiesced;
        candidate = nil;
        bool toGPTQuiesced = false;
        const bool toGPTStopped = toGPT.stop(&candidate, &toGPTQuiesced);
        record(toGPTStopped, candidate);
        allIOQuiesced = allIOQuiesced && toGPTQuiesced;
        if (gptSourceQuiesced) {
            candidate = nil;
            const bool gptTapDestroyed = gptTap.destroy(&candidate);
            record(gptTapDestroyed, candidate);
        }
        if (callSourceQuiesced) {
            candidate = nil;
            const bool callTapDestroyed = callTap.destroy(&candidate);
            record(callTapDestroyed, candidate);
        }
        running = !allIOQuiesced;
        if (quiesced) *quiesced = allIOQuiesced;
        const bool allResourcesReleased = allIOQuiesced
            && gptTap.aggregateID == kAudioObjectUnknown
            && gptTap.tapID == kAudioObjectUnknown
            && callTap.aggregateID == kAudioObjectUnknown
            && callTap.tapID == kAudioObjectUnknown;
        if (resourcesReleased) *resourcesReleased = allResourcesReleased;
        if (!succeeded && error) *error = firstError;
        return succeeded;
    }

    ~MixerImplementation() = default;
};

} // namespace

@interface GPTCallMixerEngine () {
    std::unique_ptr<MixerImplementation> _implementation;
}
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, copy, readwrite) NSString *statusText;
@property(nonatomic, copy, readwrite) NSArray<GPTAudioCandidate *> *microphones;
@property(nonatomic, copy, readwrite) NSArray<GPTAudioCandidate *> *audioProcesses;
@end

@implementation GPTCallMixerEngine

+ (NSString *)toChatGPTDeviceUID { return @"jp.local.gptcallmixer.to-chatgpt.device"; }
+ (NSString *)toCallDeviceUID { return @"jp.local.gptcallmixer.to-call.device"; }

- (instancetype)init {
    self = [super init];
    if (self) {
        _implementation = std::make_unique<MixerImplementation>();
        _statusText = @"未開始";
        _microphones = @[];
        _audioProcesses = @[];
        [self refresh:nil];
    }
    return self;
}

- (BOOL)refresh:(NSError **)error {
    NSMutableArray<GPTAudioCandidate *> *microphones = [NSMutableArray array];
    for (auto deviceID : GetObjectIDArray(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)) {
        if (ChannelCount(deviceID, kAudioObjectPropertyScopeInput) == 0) continue;
        NSString *uid = GetString(deviceID, kAudioDevicePropertyDeviceUID);
        if ([uid hasPrefix:@"jp.local.gptcallmixer."]) continue;
        GPTAudioCandidate *candidate = [GPTAudioCandidate new];
        candidate.objectID = deviceID;
        candidate.objectIDs = @[@(deviceID)];
        candidate.name = GetString(deviceID, kAudioObjectPropertyName);
        candidate.bundleID = uid;
        candidate.detail = [NSString stringWithFormat:@"Device %u — %@", deviceID, uid];
        candidate.active = YES;
        [microphones addObject:candidate];
    }

    NSMutableArray<GPTAudioCandidate *> *rawProcesses = [NSMutableArray array];
    for (auto processID : GetObjectIDArray(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)) {
        pid_t pid = -1;
        if (!GetScalar(processID, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid) || pid <= 0) continue;
        UInt32 runningOutput = 0;
        GetScalar(processID, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, runningOutput);

        GPTAudioCandidate *candidate = [GPTAudioCandidate new];
        candidate.objectID = processID;
        candidate.objectIDs = @[@(processID)];
        candidate.pid = pid;
        candidate.bundleID = GetString(processID, kAudioProcessPropertyBundleID);
        NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        candidate.name = application.localizedName ?: [NSString stringWithFormat:@"PID %d", pid];
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {};
        const int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
        NSString *path = pathLength > 0 ? [NSString stringWithUTF8String:pathBuffer] : @"";
        candidate.detail = [NSString stringWithFormat:@"%@ — PID %d — %@", candidate.bundleID.length ? candidate.bundleID : @"bundle IDなし", pid, path];
        candidate.active = runningOutput != 0;
        [rawProcesses addObject:candidate];
    }

    NSMutableDictionary<NSString *, NSMutableArray<GPTAudioCandidate *> *> *groups = [NSMutableDictionary dictionary];
    for (GPTAudioCandidate *candidate in rawProcesses) {
        NSString *family = ProcessFamilyKey(candidate);
        NSString *key = family.length ? family : [NSString stringWithFormat:@"process.%u", candidate.objectID];
        if (groups[key] == nil) groups[key] = [NSMutableArray array];
        [groups[key] addObject:candidate];
    }

    NSMutableArray<GPTAudioCandidate *> *processes = [NSMutableArray array];
    for (NSString *key in groups) {
        NSArray<GPTAudioCandidate *> *members = groups[key];
        GPTAudioCandidate *first = members.firstObject;
        GPTAudioCandidate *candidate = [GPTAudioCandidate new];
        candidate.objectID = first.objectID;
        candidate.pid = first.pid;
        candidate.name = ProcessFamilyName(key, first.name);
        candidate.bundleID = key;
        candidate.objectIDs = [members valueForKey:@"objectID"];
        NSUInteger activeCount = 0;
        for (GPTAudioCandidate *member in members) if (member.active) activeCount += 1;
        candidate.active = activeCount > 0;
        candidate.detail = [NSString stringWithFormat:@"%luプロセス（音声出力中 %lu）— Process Tapはタブではなくアプリ単位",
                            (unsigned long)members.count, (unsigned long)activeCount];
        [processes addObject:candidate];
    }
    [processes sortUsingComparator:^NSComparisonResult(GPTAudioCandidate *left, GPTAudioCandidate *right) {
        if (left.active != right.active) return left.active ? NSOrderedAscending : NSOrderedDescending;
        return [left.name localizedCaseInsensitiveCompare:right.name];
    }];

    self.microphones = microphones;
    self.audioProcesses = processes;
    if (!self.running) self.statusText = @"対象デバイスと音声プロセスを更新しました";
    if (error) *error = nil;
    return YES;
}

- (BOOL)startWithMicrophoneDevice:(AudioObjectID)microphoneDevice
              callProcessObjects:(NSArray<NSNumber *> *)callProcessObjects
                callProcessFamily:(NSString *)callProcessFamily
               gptProcessObjects:(NSArray<NSNumber *> *)gptProcessObjects
                 gptProcessFamily:(NSString *)gptProcessFamily
                            error:(NSError **)error {
    NSArray<NSNumber *> *currentCallProcessObjects =
        CurrentProcessObjectIDsForFamily(callProcessFamily, callProcessObjects);
    NSArray<NSNumber *> *currentGPTProcessObjects =
        CurrentProcessObjectIDsForFamily(gptProcessFamily, gptProcessObjects);
    if (currentCallProcessObjects.count == 0 || currentGPTProcessObjects.count == 0) {
        if (error) *error = MakeError(62, @"選択した通話側またはGPT側の音声プロセスが終了しました。対象アプリを開いた状態で再試行してください。");
        self.running = NO;
        self.statusText = @"開始できませんでした";
        return NO;
    }
    if (_implementation->start(
        microphoneDevice,
        currentCallProcessObjects,
        currentGPTProcessObjects,
        error
    )) {
        self.running = YES;
        self.statusText = @"動作中 — マイクと通話音声をミックスマイナス転送しています";
        return YES;
    }
    // If cleanup after a partial start could not quiesce an IOProc, keep the
    // public state running so the Stop action remains available.  Treating
    // this as a cleanly stopped start failure could strand live callbacks.
    self.running = _implementation->running;
    self.statusText = self.running
        ? @"開始に失敗しました — 音声IOの後始末が未完了です。停止を押してください"
        : @"開始できませんでした";
    return NO;
}

- (AudioObjectID)currentDefaultInputDevice {
    AudioObjectID deviceID = kAudioObjectUnknown;
    if (!GetScalar(
            kAudioObjectSystemObject,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            deviceID
        )) {
        return kAudioObjectUnknown;
    }
    return deviceID;
}

- (BOOL)isChatGPTDeviceCurrentDefaultInput {
    const AudioObjectID chatGPTDevice = DeviceForUID([GPTCallMixerEngine toChatGPTDeviceUID]);
    return chatGPTDevice != kAudioObjectUnknown
        && [self currentDefaultInputDevice] == chatGPTDevice;
}

- (NSString *)deviceNameForID:(AudioObjectID)deviceID {
    if (deviceID == kAudioObjectUnknown) return @"不明な入力";
    NSString *name = GetString(deviceID, kAudioObjectPropertyName);
    return name.length ? name : [NSString stringWithFormat:@"Device %u", deviceID];
}

- (BOOL)setDefaultInputDevice:(AudioObjectID)deviceID error:(NSError **)error {
    if (deviceID == kAudioObjectUnknown || ChannelCount(deviceID, kAudioObjectPropertyScopeInput) == 0) {
        if (error) *error = MakeError(70, @"macOS既定入力へ設定できる入力デバイスではありません。");
        return NO;
    }
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectSetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        nullptr,
        sizeof(deviceID),
        &deviceID
    );
    if (status != noErr) {
        if (error) *error = MakeError(
            71,
            [NSString stringWithFormat:@"macOS既定入力の変更に失敗しました（%s）。", FourCC(status).c_str()]
        );
        return NO;
    }
    AudioObjectID confirmedDeviceID = kAudioObjectUnknown;
    for (int attempt = 0; attempt < 40; ++attempt) {
        confirmedDeviceID = [self currentDefaultInputDevice];
        if (confirmedDeviceID == deviceID) break;
        usleep(25 * 1000);
    }
    if (confirmedDeviceID != deviceID) {
        if (error) *error = MakeError(72, @"macOS既定入力の変更を確認できませんでした。");
        return NO;
    }
    if (error) *error = nil;
    return YES;
}

- (BOOL)setChatGPTDeviceAsDefaultInput:(NSError **)error {
    AudioObjectID deviceID = DeviceForUID([GPTCallMixerEngine toChatGPTDeviceUID]);
    if (deviceID == kAudioObjectUnknown) {
        if (error) *error = MakeError(73, @"GPT Call Mixer → ChatGPT が見つかりません。HALドライバとCore Audioを確認してください。");
        return NO;
    }
    return [self setDefaultInputDevice:deviceID error:error];
}

- (void)stop {
    NSError *error = nil;
    bool quiesced = true;
    const BOOL stoppedCleanly = !_implementation || _implementation->stop(&error, &quiesced);
    self.running = !quiesced;
    self.statusText = stoppedCleanly
        ? @"停止しました"
        : [NSString stringWithFormat:@"停止処理でエラーが発生しました — %@", error.localizedDescription ?: @"不明なエラー"];
}

- (void)dealloc {
    NSError *error = nil;
    bool quiesced = true;
    bool resourcesReleased = true;
    if (_implementation) {
        _implementation->stop(&error, &quiesced, &resourcesReleased);
    }
    if (_implementation && (!quiesced || !resourcesReleased)) {
        // Keep callback context and ring storage alive if Core Audio refuses to
        // destroy an IOProc or a Tap resource. Leaking only on this exceptional
        // teardown path is safer than losing callback context or resource IDs.
        (void)_implementation.release();
    }
}

@end
