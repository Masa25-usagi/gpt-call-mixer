#import <AppKit/AppKit.h>
#import "GPTCallMixerEngine.h"
#import "AudioProcessFamilies.h"

#include <stdio.h>
#include <string.h>

@interface GPTMixerDocumentView : NSStackView
@end

@implementation GPTMixerDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface GPTCallMixerAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) GPTCallMixerEngine *engine;
@property(nonatomic, strong) NSPopUpButton *microphonePopup;
@property(nonatomic, strong) NSPopUpButton *callPopup;
@property(nonatomic, strong) NSPopUpButton *gptPopup;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *warningLabel;
@property(nonatomic, strong) NSButton *defaultInputCheckbox;
@property(nonatomic, strong) NSButton *meetNotesCheckbox;
@property(nonatomic) NSControlStateValue voiceModeDefaultInputState;
@property(nonatomic) BOOL appliedMeetNotesMode;
@property(nonatomic, strong) NSTextField *microphoneRowDetail;
@property(nonatomic, strong) NSTextField *callRowTitle;
@property(nonatomic, strong) NSTextField *callRowDetail;
@property(nonatomic, strong) NSTextField *gptRowTitle;
@property(nonatomic, strong) NSTextField *gptRowDetail;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *startButton;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic) AudioObjectID previousDefaultInputDevice;
@property(nonatomic) BOOL changedDefaultInput;
@property(nonatomic) BOOL hasRefreshedCandidates;
@property(nonatomic) BOOL refreshedMeetNotesMode;
- (void)setupIfNeeded;
@end

static GPTCallMixerAppDelegate *gAppDelegate;
static NSString *const kMeetNotesModeDefaultsKey = @"MeetNotesMode";

@implementation GPTCallMixerAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self setupIfNeeded];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self setupIfNeeded];
    [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self setupIfNeeded];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    return NO;
}

- (void)setupIfNeeded {
    if (self.window != nil) return;
    self.engine = [GPTCallMixerEngine new];
    self.previousDefaultInputDevice = kAudioObjectUnknown;
    [self buildWindow];
    [self refresh:nil];
    [self updateButtons];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopRoutingAndRestoreDefaultInputUpdatingUI:NO];
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

- (NSView *)rowWithTitleLabel:(NSTextField *)titleLabel popup:(NSPopUpButton *)button detailLabel:(NSTextField *)detail {
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 5;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:620].active = YES;
    detail.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:titleLabel];
    [stack addArrangedSubview:button];
    [stack addArrangedSubview:detail];
    [titleLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [button.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [detail.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    return stack;
}

- (BOOL)isMeetNotesMode {
    return self.meetNotesCheckbox.state == NSControlStateValueOn;
}

- (void)applyModeLabels {
    if ([self isMeetNotesMode]) {
        self.microphoneRowDetail.stringValue = @"自分の声をMeetへ送ります。会話アプリのマイクは普段の物理マイクのまま使います。";
        self.callRowTitle.stringValue = @"2. Google Meetを開いているブラウザ";
        self.callRowDetail.stringValue = @"通常はGoogle Chrome。MeetのマイクはGPT Call Mixer → Callにします（Meetの音声自体は議事録には使いません）。";
        self.gptRowTitle.stringValue = @"3. Meetへ流す会話アプリ";
        self.gptRowDetail.stringValue = @"Slack・Discord・LINE・Zoom・Macの電話、またはSafariのWeb通話。通話に参加してから再検出します。Meetと同じブラウザでは分離できません。";
    } else {
        self.microphoneRowDetail.stringValue = @"この音声はChatGPTと通話相手の両方へ送ります。手元スピーカーにはモニターしません。";
        self.callRowTitle.stringValue = @"2. 通話側の音声プロセス";
        self.callRowDetail.stringValue = @"Google Meetのブラウザ、Slack・Discord・LINE・Zoom・Macの電話。選んだアプリの通話以外の音声も含みます。";
        self.gptRowTitle.stringValue = @"3. GPT Voice側の音声プロセス";
        self.gptRowDetail.stringValue = @"ChatGPT/Codexデスクトップ、またはSafariのChatGPT Web Voice。Web版はMeet=Chrome、Voice=Safariを推奨します。";
    }
}

- (void)meetNotesModeChanged:(id)sender {
    (void)sender;
    BOOL meetMode = [self isMeetNotesMode];
    [NSUserDefaults.standardUserDefaults setBool:meetMode forKey:kMeetNotesModeDefaultsKey];
    if (meetMode && !self.appliedMeetNotesMode) {
        // Conversation apps must keep using the real microphone, so never move the
        // macOS default input to a virtual device in this mode.
        self.voiceModeDefaultInputState = self.defaultInputCheckbox.state;
        self.defaultInputCheckbox.state = NSControlStateValueOff;
    } else if (!meetMode && self.appliedMeetNotesMode) {
        self.defaultInputCheckbox.state = self.voiceModeDefaultInputState;
    }
    self.appliedMeetNotesMode = meetMode;
    [self applyModeLabels];
    [self refresh:nil];
    [self updateButtons];
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 780, 720);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"GPT Call Mixer";
    self.window.minSize = NSMakeSize(700, 640);
    self.window.releasedWhenClosed = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces;
    [self.window center];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;

    NSStackView *root = [GPTMixerDocumentView stackViewWithViews:@[]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.alignment = NSLayoutAttributeLeading;
    root.spacing = 18;
    root.edgeInsets = NSEdgeInsetsMake(24, 24, 24, 24);
    root.translatesAutoresizingMaskIntoConstraints = NO;

    [root addArrangedSubview:[self label:@"GPT Call Mixer" size:28 weight:NSFontWeightSemibold]];
    NSTextField *subtitle = [self label:@"1台のMacで、物理マイク・通話アプリ・ChatGPT Voiceをミックスマイナス接続します。録音ファイルは作りません。" size:13 weight:NSFontWeightRegular];
    subtitle.textColor = NSColor.secondaryLabelColor;
    [root addArrangedSubview:subtitle];

    self.statusLabel = [self label:@"未開始" size:14 weight:NSFontWeightSemibold];
    self.statusLabel.wantsLayer = YES;
    self.statusLabel.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    self.statusLabel.layer.cornerRadius = 8;
    [root addArrangedSubview:self.statusLabel];

    self.meetNotesCheckbox = [NSButton checkboxWithTitle:@"Meet議事録モード（会話アプリの音声をGoogle Meetへ流す）"
                                                  target:self
                                                  action:@selector(meetNotesModeChanged:)];
    self.meetNotesCheckbox.state = [NSUserDefaults.standardUserDefaults boolForKey:kMeetNotesModeDefaultsKey]
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    [root addArrangedSubview:self.meetNotesCheckbox];
    NSTextField *meetNotesDescription = [self label:
        @"物理マイク＋会話相手の声をGPT Call Mixer → Callへ送ります。LINEの音声・ビデオ通話、Zoom、Macの電話にも対応します。ChromeのMeetでこのデバイスをマイクにし、対象プランの「Take notes（Geminiのメモ）」を開始すると、Meetが議事録をGoogleドキュメントに保存します。"
        size:12
        weight:NSFontWeightRegular];
    meetNotesDescription.textColor = NSColor.secondaryLabelColor;
    [root addArrangedSubview:meetNotesDescription];

    self.microphonePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.callPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.gptPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.microphoneRowDetail = [self label:@"" size:12 weight:NSFontWeightRegular];
    [root addArrangedSubview:[self rowWithTitleLabel:[self label:@"1. 物理マイク" size:14 weight:NSFontWeightSemibold]
                                              popup:self.microphonePopup
                                        detailLabel:self.microphoneRowDetail]];
    self.callRowTitle = [self label:@"" size:14 weight:NSFontWeightSemibold];
    self.callRowDetail = [self label:@"" size:12 weight:NSFontWeightRegular];
    self.gptRowTitle = [self label:@"" size:14 weight:NSFontWeightSemibold];
    self.gptRowDetail = [self label:@"" size:12 weight:NSFontWeightRegular];
    [root addArrangedSubview:[self rowWithTitleLabel:self.callRowTitle popup:self.callPopup detailLabel:self.callRowDetail]];
    [root addArrangedSubview:[self rowWithTitleLabel:self.gptRowTitle popup:self.gptPopup detailLabel:self.gptRowDetail]];
    [self.callPopup setTarget:self];
    [self.callPopup setAction:@selector(selectionChanged:)];
    [self.gptPopup setTarget:self];
    [self.gptPopup setAction:@selector(selectionChanged:)];

    self.warningLabel = [self label:@"" size:12 weight:NSFontWeightSemibold];
    self.warningLabel.textColor = NSColor.systemOrangeColor;
    [root addArrangedSubview:self.warningLabel];

    self.defaultInputCheckbox = [NSButton checkboxWithTitle:@"ChatGPT Voice用にmacOS既定入力を一時切替（停止時に元へ復元）"
                                                    target:nil
                                                    action:nil];
    self.voiceModeDefaultInputState = NSControlStateValueOn;
    self.appliedMeetNotesMode = [self isMeetNotesMode];
    self.defaultInputCheckbox.state = self.appliedMeetNotesMode
        ? NSControlStateValueOff
        : self.voiceModeDefaultInputState;
    [root addArrangedSubview:self.defaultInputCheckbox];
    NSTextField *defaultInputDescription = [self label:
        @"Safari Web Voiceや入力選択のないChatGPTデスクトップでは推奨です。動作中は他のアプリの「既定マイク」もGPT Call Mixer → ChatGPTになります。"
        size:12
        weight:NSFontWeightRegular];
    defaultInputDescription.textColor = NSColor.secondaryLabelColor;
    [root addArrangedSubview:defaultInputDescription];

    NSStackView *buttons = [NSStackView stackViewWithViews:@[]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 10;
    self.refreshButton = [NSButton buttonWithTitle:@"再検出" target:self action:@selector(refresh:)];
    self.startButton = [NSButton buttonWithTitle:@"開始" target:self action:@selector(start:)];
    self.startButton.keyEquivalent = @"\r";
    self.stopButton = [NSButton buttonWithTitle:@"停止" target:self action:@selector(stop:)];
    [buttons addArrangedSubview:self.refreshButton];
    [buttons addArrangedSubview:self.startButton];
    [buttons addArrangedSubview:self.stopButton];
    [root addArrangedSubview:buttons];

    NSBox *instructionsBox = [NSBox new];
    instructionsBox.title = @"通話アプリとVoiceで選ぶマイク";
    NSTextField *instructions = [self label:
        @"ChatGPTデスクトップ／Web Voiceの入力：GPT Call Mixer → ChatGPT\n"
         "Google Meet／通話アプリの入力：GPT Call Mixer → Call\n"
         "Meet議事録モード：会話アプリの入出力は普段のマイク・スピーカーのまま、ChromeのMeetだけマイクをGPT Call Mixer → Callにし、Meetのスピーカーはミュートします。\n\n"
         "Web VoiceをSafariで使い、入力デバイス選択が表示されない場合は、macOSの入力を一時的に「GPT Call Mixer → ChatGPT」へ設定します。"
         "Chrome同士はタブを分離できないため、MeetとWeb Voiceを同じChromeで同時利用しないでください。"
        size:12 weight:NSFontWeightRegular];
    instructions.translatesAutoresizingMaskIntoConstraints = NO;
    instructionsBox.contentView = instructions;
    [instructions.leadingAnchor constraintEqualToAnchor:instructionsBox.leadingAnchor constant:12].active = YES;
    [instructions.trailingAnchor constraintEqualToAnchor:instructionsBox.trailingAnchor constant:-12].active = YES;
    [instructions.topAnchor constraintEqualToAnchor:instructionsBox.topAnchor constant:26].active = YES;
    [instructions.bottomAnchor constraintEqualToAnchor:instructionsBox.bottomAnchor constant:-12].active = YES;
    [root addArrangedSubview:instructionsBox];

    NSClipView *clip = [NSClipView new];
    clip.drawsBackground = NO;
    clip.documentView = root;
    scroll.contentView = clip;
    self.window.contentView = scroll;
    [self applyModeLabels];

    [root.widthAnchor constraintEqualToAnchor:clip.widthAnchor].active = YES;
    for (NSView *view in root.arrangedSubviews) {
        if (view == buttons || [view isKindOfClass:NSButton.class]) {
            [view.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-48].active = YES;
        } else {
            [view.widthAnchor constraintEqualToAnchor:root.widthAnchor constant:-48].active = YES;
        }
    }
}

- (BOOL)isCallCandidate:(GPTAudioCandidate *)candidate {
    if (GPTIsSupportedCallFamily(candidate.bundleID)) return YES;
    NSString *value = [NSString stringWithFormat:@"%@ %@ %@", candidate.name, candidate.bundleID, candidate.detail].lowercaseString;
    return [value containsString:@"chrome"] || [value containsString:@"discord"]
        || [value containsString:@"teams"]
        || [value containsString:@"safari"] || [value containsString:@"firefox"]
        || [value containsString:@"slack"];
}

- (BOOL)isConversationSourceCandidate:(GPTAudioCandidate *)candidate {
    if (GPTIsSupportedCallFamily(candidate.bundleID)) return YES;
    NSString *value = [NSString stringWithFormat:@"%@ %@ %@", candidate.name, candidate.bundleID, candidate.detail].lowercaseString;
    return [value containsString:@"slack"] || [value containsString:@"discord"]
        || [value containsString:@"teams"]
        || [self isGPTCandidate:candidate];
}

- (BOOL)isGPTCandidate:(GPTAudioCandidate *)candidate {
    if ([candidate.bundleID isEqualToString:@"gpt.desktop"] || [candidate.bundleID hasPrefix:@"browser."]) return YES;
    NSString *value = [NSString stringWithFormat:@"%@ %@ %@", candidate.name, candidate.bundleID, candidate.detail].lowercaseString;
    return [value containsString:@"openai"] || [value containsString:@"chatgpt"]
        || [value containsString:@"codex"] || [value containsString:@"safari"]
        || [value containsString:@"webkit"] || [value containsString:@"chrome"]
        || [value containsString:@"firefox"] || [value containsString:@"edge"]
        || [value containsString:@"brave"] || [value containsString:@"arc"]
        || [value containsString:@"opera"] || [value containsString:@"vivaldi"];
}

- (void)populate:(NSPopUpButton *)popup candidates:(NSArray<GPTAudioCandidate *> *)candidates filter:(BOOL (^)(GPTAudioCandidate *))filter {
    [popup removeAllItems];
    for (GPTAudioCandidate *candidate in candidates) {
        if (filter && !filter(candidate)) continue;
        NSString *prefix = candidate.active ? @"●" : @"○";
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ %@ — %@", prefix, candidate.name, candidate.bundleID] action:nil keyEquivalent:@""];
        item.representedObject = candidate;
        item.toolTip = candidate.detail;
        [popup.menu addItem:item];
    }
    if (popup.numberOfItems == 0) [popup addItemWithTitle:@"候補なし — 対象アプリで一度音声を再生してください"];
}

- (void)selectPopup:(NSPopUpButton *)popup candidateWithObjectID:(AudioObjectID)objectID {
    for (NSMenuItem *item in popup.itemArray) {
        GPTAudioCandidate *candidate = item.representedObject;
        if ([candidate isKindOfClass:GPTAudioCandidate.class] && candidate.objectID == objectID) {
            [popup selectItem:item];
            return;
        }
    }
}

- (void)selectPopup:(NSPopUpButton *)popup candidateWithBundleID:(NSString *)bundleID {
    for (NSMenuItem *item in popup.itemArray) {
        GPTAudioCandidate *candidate = item.representedObject;
        if ([candidate isKindOfClass:GPTAudioCandidate.class]
            && [candidate.bundleID isEqualToString:bundleID]) {
            [popup selectItem:item];
            return;
        }
    }
}

- (void)selectionChanged:(id)sender {
    (void)sender;
    [self updateWarning];
}

- (NSString *)preferredConversationFamily {
    NSArray<NSString *> *families = @[@"call.slack", @"call.discord", @"call.line", @"call.zoom", @"call.apple-phone"];
    for (NSString *family in families) {
        for (GPTAudioCandidate *candidate in self.engine.audioProcesses) {
            if (candidate.active && [candidate.bundleID isEqualToString:family]) return family;
        }
    }
    // Idle Apple services exist even when Phone is closed. Prefer an open
    // conversation app or Safari before choosing those background services.
    for (NSString *family in [families subarrayWithRange:NSMakeRange(0, families.count - 1)]) {
        for (GPTAudioCandidate *candidate in self.engine.audioProcesses) {
            if ([candidate.bundleID isEqualToString:family]) return family;
        }
    }
    for (GPTAudioCandidate *candidate in self.engine.audioProcesses) {
        if ([candidate.bundleID isEqualToString:@"browser.safari"]) return @"browser.safari";
    }
    return @"call.apple-phone";
}

- (void)refresh:(id)sender {
    if (self.engine.running) {
        self.statusLabel.stringValue = @"動作中は再検出できません。停止してから再検出してください。";
        return;
    }
    BOOL meetMode = [self isMeetNotesMode];
    BOOL sameMode = self.hasRefreshedCandidates && self.refreshedMeetNotesMode == meetMode;
    AudioObjectID previousMicrophone = [self selectedCandidate:self.microphonePopup].objectID;
    NSString *previousCallFamily = sameMode ? [self selectedCandidate:self.callPopup].bundleID : nil;
    NSString *previousGPTFamily = sameMode ? [self selectedCandidate:self.gptPopup].bundleID : nil;
    NSError *error = nil;
    [self.engine refresh:&error];
    [self populate:self.microphonePopup candidates:self.engine.microphones filter:nil];
    [self populate:self.callPopup candidates:self.engine.audioProcesses filter:^BOOL(GPTAudioCandidate *candidate) {
        return [self isCallCandidate:candidate];
    }];
    [self populate:self.gptPopup candidates:self.engine.audioProcesses filter:^BOOL(GPTAudioCandidate *candidate) {
        return meetMode ? [self isConversationSourceCandidate:candidate] : [self isGPTCandidate:candidate];
    }];
    [self selectPopup:self.microphonePopup
        candidateWithObjectID:self.engine.currentDefaultInputDevice];
    if (previousMicrophone != kAudioObjectUnknown) {
        [self selectPopup:self.microphonePopup candidateWithObjectID:previousMicrophone];
    }
    [self selectPopup:self.callPopup candidateWithBundleID:@"browser.chrome"];
    if (meetMode) {
        [self selectPopup:self.gptPopup candidateWithBundleID:[self preferredConversationFamily]];
    } else {
        [self selectPopup:self.gptPopup candidateWithBundleID:@"gpt.desktop"];
    }
    if (previousCallFamily) [self selectPopup:self.callPopup candidateWithBundleID:previousCallFamily];
    if (previousGPTFamily) [self selectPopup:self.gptPopup candidateWithBundleID:previousGPTFamily];
    self.hasRefreshedCandidates = YES;
    self.refreshedMeetNotesMode = meetMode;
    self.statusLabel.stringValue = error.localizedDescription ?: self.engine.statusText;
    [self updateWarning];
}

- (GPTAudioCandidate *)selectedCandidate:(NSPopUpButton *)popup {
    id represented = popup.selectedItem.representedObject;
    return [represented isKindOfClass:GPTAudioCandidate.class] ? represented : nil;
}

- (void)updateWarning {
    GPTAudioCandidate *call = [self selectedCandidate:self.callPopup];
    GPTAudioCandidate *gpt = [self selectedCandidate:self.gptPopup];
    NSMutableSet<NSNumber *> *overlap = call ? [NSMutableSet setWithArray:call.objectIDs] : nil;
    if (gpt) [overlap intersectSet:[NSSet setWithArray:gpt.objectIDs]];
    if ([self isMeetNotesMode]) {
        if (call && gpt && (overlap.count > 0 || [call.bundleID isEqualToString:gpt.bundleID])) {
            self.warningLabel.stringValue = @"Meetと会話アプリを同じブラウザにはできません。会話アプリはデスクトップ版か、別のブラウザ（Safariなど）で開いてください。";
        } else {
            self.warningLabel.stringValue = @"MeetのマイクをGPT Call Mixer → Callにし、Meetのスピーカー（タブ）はミュートしてください。会話アプリはヘッドホン推奨です。";
        }
    } else if (call && gpt && overlap.count > 0) {
        self.warningLabel.stringValue = @"同じ音声プロセスは両側へ使えません。MeetをChrome、ChatGPT Web VoiceをSafariに分けてください。";
    } else if (call && gpt && [call.bundleID isEqualToString:gpt.bundleID] && [call.bundleID.lowercaseString containsString:@"chrome"]) {
        self.warningLabel.stringValue = @"Chrome同士はタブ単位に分離できません。Chrome + Safari構成を推奨します。";
    } else {
        self.warningLabel.stringValue = @"スピーカー使用時は物理マイクが音を拾うため、安定運用はヘッドホン推奨です。";
    }
    if ([call.bundleID isEqualToString:@"call.apple-phone"] || [gpt.bundleID isEqualToString:@"call.apple-phone"]) {
        self.warningLabel.stringValue = [self.warningLabel.stringValue stringByAppendingString:
            @" 電話はFaceTimeなどと通話音声を共有するため、同時利用すると両方の音が含まれる場合があります。"];
    }
}

- (void)start:(id)sender {
    GPTAudioCandidate *microphone = [self selectedCandidate:self.microphonePopup];
    GPTAudioCandidate *call = [self selectedCandidate:self.callPopup];
    GPTAudioCandidate *gpt = [self selectedCandidate:self.gptPopup];
    if (!microphone || !call || !gpt) {
        self.statusLabel.stringValue = [self isMeetNotesMode]
            ? @"マイク、Meetのブラウザ、会話アプリをすべて選択してください"
            : @"マイク、通話側、GPT側をすべて選択してください";
        return;
    }
    if ([self isMeetNotesMode]) {
        NSMutableSet<NSNumber *> *overlap = [NSMutableSet setWithArray:call.objectIDs];
        [overlap intersectSet:[NSSet setWithArray:gpt.objectIDs]];
        if (overlap.count > 0 || [call.bundleID isEqualToString:gpt.bundleID]) {
            self.statusLabel.stringValue = @"Meetと会話アプリを同じアプリにはできません。会話アプリはデスクトップ版か別のブラウザで開いてください。";
            return;
        }
    }
    NSError *error = nil;
    if (![self.engine startWithMicrophoneDevice:microphone.objectID
                            callProcessObjects:call.objectIDs
                              callProcessFamily:call.bundleID
                             gptProcessObjects:gpt.objectIDs
                               gptProcessFamily:gpt.bundleID
                                          error:&error]) {
        self.statusLabel.stringValue = error.localizedDescription ?: self.engine.statusText;
    } else {
        if (self.defaultInputCheckbox.state == NSControlStateValueOn && ![self isMeetNotesMode]) {
            self.previousDefaultInputDevice = [self.engine currentDefaultInputDevice];
            NSError *defaultInputError = nil;
            if (![self.engine setChatGPTDeviceAsDefaultInput:&defaultInputError]) {
                [self.engine stop];
                if (self.previousDefaultInputDevice != kAudioObjectUnknown) {
                    [self.engine setDefaultInputDevice:self.previousDefaultInputDevice error:nil];
                }
                self.previousDefaultInputDevice = kAudioObjectUnknown;
                self.changedDefaultInput = NO;
                self.statusLabel.stringValue = [NSString stringWithFormat:
                    @"開始を取り消しました — %@",
                    defaultInputError.localizedDescription ?: @"macOS既定入力を変更できませんでした"
                ];
                [self updateButtons];
                return;
            }
            AudioObjectID currentDefaultInput = [self.engine currentDefaultInputDevice];
            self.changedDefaultInput = self.previousDefaultInputDevice != kAudioObjectUnknown
                && self.previousDefaultInputDevice != currentDefaultInput;
            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"%@／macOS既定入力もGPT Call Mixer → ChatGPTへ一時切替中",
                self.engine.statusText
            ];
        } else if ([self isMeetNotesMode]) {
            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"Meet議事録モード動作中 — %@ の会話＋物理マイクを GPT Call Mixer → Call へ送っています",
                gpt.name
            ];
        } else {
            self.statusLabel.stringValue = self.engine.statusText;
        }
    }
    [self updateButtons];
}

- (void)stopRoutingAndRestoreDefaultInputUpdatingUI:(BOOL)updateUI {
    [self.engine stop];
    NSError *restoreError = nil;
    BOOL skippedRestoreBecauseUserChangedInput = NO;
    if (self.changedDefaultInput && self.previousDefaultInputDevice != kAudioObjectUnknown
        && [self.engine isChatGPTDeviceCurrentDefaultInput]) {
        [self.engine setDefaultInputDevice:self.previousDefaultInputDevice error:&restoreError];
    } else if (self.changedDefaultInput) {
        // Do not clobber a deliberate change made by the user or another app
        // while routing was active.  Only restore when our temporary device is
        // still the current default input.
        skippedRestoreBecauseUserChangedInput = YES;
    }
    self.changedDefaultInput = NO;
    self.previousDefaultInputDevice = kAudioObjectUnknown;
    if (updateUI) {
        self.statusLabel.stringValue = restoreError
            ? [NSString stringWithFormat:@"音声経路は停止しましたが、元の既定入力へ復元できませんでした — %@", restoreError.localizedDescription]
            : skippedRestoreBecauseUserChangedInput
                ? @"停止しました（既定入力は途中で変更されていたため、そのまま維持しました）"
            : self.engine.statusText;
        [self updateButtons];
    }
}

- (void)stop:(id)sender {
    [self stopRoutingAndRestoreDefaultInputUpdatingUI:YES];
}

- (void)updateButtons {
    self.startButton.enabled = !self.engine.running;
    self.stopButton.enabled = self.engine.running;
    self.microphonePopup.enabled = !self.engine.running;
    self.callPopup.enabled = !self.engine.running;
    self.gptPopup.enabled = !self.engine.running;
    self.defaultInputCheckbox.enabled = !self.engine.running && ![self isMeetNotesMode];
    self.meetNotesCheckbox.enabled = !self.engine.running;
    self.refreshButton.enabled = !self.engine.running;
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--diagnose") == 0) {
            GPTCallMixerEngine *engine = [GPTCallMixerEngine new];
            NSError *error = nil;
            [engine refresh:&error];
            if (error) {
                fprintf(stderr, "GPT Call Mixer diagnose: FAIL: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            printf("GPT Call Mixer diagnose (read-only)\nMicrophones: %lu\n",
                   (unsigned long)engine.microphones.count);
            for (GPTAudioCandidate *candidate in engine.microphones) {
                printf("  Device %u: %s\n", candidate.objectID, candidate.name.UTF8String);
            }
            printf("Audio process groups: %lu\n", (unsigned long)engine.audioProcesses.count);
            for (GPTAudioCandidate *candidate in engine.audioProcesses) {
                printf("  %s [%s] family=%s objects=", candidate.name.UTF8String, candidate.active ? "active" : "idle", candidate.bundleID.UTF8String);
                for (NSNumber *objectID in candidate.objectIDs) printf("%u ", objectID.unsignedIntValue);
                printf("\n");
            }
            AudioObjectID defaultInput = [engine currentDefaultInputDevice];
            printf("Default input: Device %u — %s\n",
                   defaultInput,
                   [engine deviceNameForID:defaultInput].UTF8String);
            printf("Virtual devices are validated only when Start is pressed.\n");
            printf("No tap, audio IO, recording, permission change, or device installation was performed.\n");
            return 0;
        }
        NSApplication *application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        gAppDelegate = [GPTCallMixerAppDelegate new];
        application.delegate = gAppDelegate;
        [application run];
    }
    return 0;
}
