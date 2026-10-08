#import "../GPTCallMixerApp/AudioProcessFamilies.h"
#include <stdio.h>

static NSUInteger checks;

static void CheckFamily(NSString *bundleID, NSString *name, NSString *path, NSString *expected) {
    GPTAudioCandidate *candidate = [GPTAudioCandidate new];
    candidate.bundleID = bundleID;
    candidate.name = name;
    candidate.executablePath = path;
    NSString *actual = GPTProcessFamilyKey(candidate);
    if (![actual isEqualToString:expected]) {
        [NSException raise:@"AudioProcessFamilyTestFailure"
                    format:@"%@ / %@: expected '%@', got '%@'", bundleID, name, expected, actual];
    }
    checks += 1;
}

int main(void) {
    @autoreleasepool {
        @try {
            CheckFamily(@"jp.naver.line.mac", @"LINE", @"", @"call.line");
            CheckFamily(@"jp.naver.line.mac.LineCall", @"LineCall", @"", @"call.line");
            CheckFamily(@"LINE.AudioService", @"LINE.AudioService", @"", @"call.line");
            CheckFamily(@"LINE.MediaService", @"LINE.MediaService", @"", @"call.line");
            CheckFamily(@"LINE.VideoPreviewService.0", @"LINE.VideoPreviewService.0", @"", @"call.line");
            CheckFamily(@"", @"PID 100", @"/Applications/LINE.app/Contents/Frameworks/LineCall.app/Contents/MacOS/LineCall", @"call.line");
            CheckFamily(@"com.apple.WebKit.GPU", @"LINE Graphics and Media", @"/System/Library/WebKit/GPU", @"call.line");

            // These identifiers are from Zoom's signed macOS installer.
            CheckFamily(@"us.zoom.xos", @"Zoom Workplace", @"", @"call.zoom");
            CheckFamily(@"us.zoom.CptHost", @"CptHost", @"", @"call.zoom");
            CheckFamily(@"us.zoom.ZoomMeeting", @"ZoomMeeting", @"", @"call.zoom");
            CheckFamily(@"us.zoom.caphost", @"caphost", @"", @"call.zoom");
            CheckFamily(@"", @"PID 101", @"/Applications/zoom.us.app/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost", @"call.zoom");

            CheckFamily(@"com.apple.mobilephone", @"電話", @"", @"call.apple-phone");
            CheckFamily(@"com.apple.FaceTime", @"FaceTime", @"", @"call.apple-phone");
            CheckFamily(@"com.apple.FaceTime.FTConversationService", @"", @"", @"call.apple-phone");
            CheckFamily(@"com.apple.TelephonyUtilities", @"", @"", @"call.apple-phone");
            CheckFamily(@"com.apple.avconferenced", @"", @"", @"call.apple-phone");
            CheckFamily(@"", @"PID 102", @"/usr/libexec/avconferenced", @"call.apple-phone");
            CheckFamily(@"", @"PID 103", @"/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd", @"call.apple-phone");

            // Do not assign generic names, similar namespaces, or another
            // app's shared WebKit process to one of the new call families.
            CheckFamily(@"org.example.line", @"Line editor", @"/Applications/Headline.app/Contents/MacOS/readline", @"");
            CheckFamily(@"jp.naver.line.macos", @"Line helper", @"", @"");
            CheckFamily(@"org.example.zoom", @"Zoom tools", @"/Applications/Zoomify.app/Contents/MacOS/CptHost", @"");
            CheckFamily(@"us.zoomer.xos", @"CptHost", @"", @"");
            CheckFamily(@"com.example.phone", @"Phone helper", @"/Applications/PhoneTools.app/Contents/MacOS/Phone", @"");
            CheckFamily(@"com.apple.TelephonyUtilities.example", @"callservicesd", @"/usr/local/bin/callservicesd", @"");
            CheckFamily(@"com.example.avconferenced", @"avconferenced", @"/usr/local/bin/avconferenced", @"");
            CheckFamily(@"com.apple.WebKit.GPU", @"Other Graphics and Media", @"/System/Library/WebKit/GPU", @"");
            CheckFamily(@"com.apple.WebKit.GPU", @"Safari Graphics and Media", @"/System/Library/WebKit/GPU", @"browser.safari");
            CheckFamily(@"com.google.Chrome.helper", @"Chrome helper", @"", @"browser.chrome");
            CheckFamily(@"com.tinyspeck.slackmacgap.helper", @"Slack helper", @"", @"call.slack");
            CheckFamily(@"com.hnc.Discord", @"Discord", @"", @"call.discord");
            CheckFamily(@"com.openai.codex", @"Codex", @"", @"gpt.desktop");

            if (GPTProcessFamilyKey([GPTAudioCandidate new]).length != 0) {
                [NSException raise:@"AudioProcessFamilyTestFailure" format:@"Missing metadata must not match"];
            }
            printf("AudioProcessFamilyTests: PASS (%lu identity cases, no audio capture)\n", (unsigned long)checks + 1);
        } @catch (NSException *exception) {
            fprintf(stderr, "AudioProcessFamilyTests: FAIL: %s\n", exception.reason.UTF8String);
            return 1;
        }
    }
    return 0;
}
