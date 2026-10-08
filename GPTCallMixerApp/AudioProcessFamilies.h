#pragma once

#import "GPTCallMixerEngine.h"

// Match identifiers at namespace boundaries. Generic words such as "line",
// "phone", and "zoom" also occur in unrelated process names and paths.
static inline BOOL GPTBundleMatches(NSString *bundleID, NSString *identifier) {
    return [bundleID isEqualToString:identifier]
        || [bundleID hasPrefix:[identifier stringByAppendingString:@"."]];
}

static inline NSString *GPTProcessFamilyKey(GPTAudioCandidate *candidate) {
    NSString *bundleID = candidate.bundleID.lowercaseString ?: @"";
    NSString *name = candidate.name.lowercaseString ?: @"";
    NSString *path = candidate.executablePath.lowercaseString ?: @"";
    NSString *value = [NSString stringWithFormat:@"%@ %@ %@", bundleID, name, path];
    if ([value containsString:@"com.google.chrome"] || [value containsString:@"/google chrome.app/"]
        || [value containsString:@"google chrome helper"]) return @"browser.chrome";
    if ([value containsString:@"com.apple.safari"] || [value containsString:@"/safari.app/"]
        || [value containsString:@"safari webkit"]
        || [name isEqualToString:@"safari graphics and media"]) return @"browser.safari";
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

    if (GPTBundleMatches(bundleID, @"jp.naver.line.mac")
        || [path containsString:@"/line.app/contents/"]
        || [bundleID isEqualToString:@"line.audioservice"]
        || [bundleID isEqualToString:@"line.mediaservice"]
        || [bundleID isEqualToString:@"line.ffmpegservice"]
        || [bundleID isEqualToString:@"line.seekpreviewservice"]
        || GPTBundleMatches(bundleID, @"line.videopreviewservice")
        || ([bundleID isEqualToString:@"com.apple.webkit.gpu"]
            && [name isEqualToString:@"line graphics and media"])) return @"call.line";

    // Zoom's meeting/capture helpers have their own us.zoom.* bundle IDs.
    if ([bundleID hasPrefix:@"us.zoom."]
        || [path containsString:@"/zoom.us.app/contents/"]
        || [path containsString:@"/zoom workplace.app/contents/"]) return @"call.zoom";

    // Phone/FaceTime call audio can be owned by these shared system services,
    // rather than the frontmost app. Keep them in one explicitly shared group.
    if (GPTBundleMatches(bundleID, @"com.apple.mobilephone")
        || GPTBundleMatches(bundleID, @"com.apple.facetime")
        || [bundleID isEqualToString:@"com.apple.telephonyutilities"]
        || [bundleID isEqualToString:@"com.apple.avconferenced"]
        || [path isEqualToString:@"/system/applications/phone.app/contents/macos/phone"]
        || [path isEqualToString:@"/system/library/privateframeworks/telephonyutilities.framework/callservicesd"]
        || [path isEqualToString:@"/usr/libexec/avconferenced"]) return @"call.apple-phone";

    if ([value containsString:@"com.openai.codex"] || [value containsString:@"com.openai.chatgpt"]
        || [value containsString:@"com.openai.chat"] || [value containsString:@"/chatgpt.app/"]
        || [value containsString:@"/codex.app/"]) return @"gpt.desktop";
    return @"";
}

static inline BOOL GPTIsSupportedCallFamily(NSString *family) {
    return [@[@"call.slack", @"call.discord", @"call.line", @"call.zoom", @"call.apple-phone"] containsObject:family ?: @""];
}

static inline NSString *GPTProcessFamilyName(NSString *key, NSString *fallback) {
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
        @"call.line": @"LINE（アプリ全体・音声／ビデオ通話）",
        @"call.zoom": @"Zoom（アプリ全体・会議）",
        @"call.apple-phone": @"電話 / FaceTime（共有通話音声）",
        @"gpt.desktop": @"ChatGPT / Codex（アプリ全体）"
    };
    return names[key] ?: fallback;
}
