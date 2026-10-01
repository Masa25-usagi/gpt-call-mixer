#import <AppKit/AppKit.h>
#import "GPTCallMixerEngine.h"

#include <stdio.h>
#include <string.h>

@interface GPTCallMixerAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) GPTCallMixerEngine *engine;
@property(nonatomic, strong) NSPopUpButton *microphonePopup;
@property(nonatomic, strong) NSPopUpButton *callPopup;
@property(nonatomic, strong) NSPopUpButton *gptPopup;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *warningLabel;
@property(nonatomic, strong) NSButton *defaultInputCheckbox;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *startButton;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic) AudioObjectID previousDefaultInputDevice;
@property(nonatomic) BOOL changedDefaultInput;
- (void)setupIfNeeded;
@end

static GPTCallMixerAppDelegate *gAppDelegate;

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
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    return label;
}

- (NSView *)rowWithTitle:(NSString *)title popup:(NSPopUpButton *)button description:(NSString *)description {
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 5;
    NSTextField *titleLabel = [self label:title size:14 weight:NSFontWeightSemibold];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:620].active = YES;
    NSTextField *detail = [self label:description size:12 weight:NSFontWeightRegular];
    detail.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:titleLabel];
    [stack addArrangedSubview:button];
    [stack addArrangedSubview:detail];
    return stack;
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

    NSStackView *root = [NSStackView stackViewWithViews:@[]];
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

    self.microphonePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.callPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.gptPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [root addArrangedSubview:[self rowWithTitle:@"1. 物理マイク"
                                         popup:self.microphonePopup
                                    description:@"この音声はChatGPTと通話相手の両方へ送ります。手元スピーカーにはモニターしません。"]];
    [root addArrangedSubview:[self rowWithTitle:@"2. 通話側の音声プロセス"
                                         popup:self.callPopup
                                    description:@"Google Chrome（Meet）、将来はDiscordなど。Chromeを選ぶとMeet以外のChrome音声も対象になります。"]];
    [root addArrangedSubview:[self rowWithTitle:@"3. GPT Voice側の音声プロセス"
                                         popup:self.gptPopup
                                    description:@"ChatGPT/Codexデスクトップ、またはSafariのChatGPT Web Voice。Web版はMeet=Chrome、Voice=Safariを推奨します。"]];

    self.warningLabel = [self label:@"" size:12 weight:NSFontWeightSemibold];
    self.warningLabel.textColor = NSColor.systemOrangeColor;
    [root addArrangedSubview:self.warningLabel];

    self.defaultInputCheckbox = [NSButton checkboxWithTitle:@"ChatGPT Voice用にmacOS既定入力を一時切替（停止時に元へ復元）"
                                                    target:nil
                                                    action:nil];
    self.defaultInputCheckbox.state = NSControlStateValueOn;
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
         "Google Meet／通話アプリの入力：GPT Call Mixer → Call\n\n"
         "Web VoiceをSafariで使い、入力デバイス選択が表示されない場合は、macOSの入力を一時的に「GPT Call Mixer → ChatGPT」へ設定します。"
         "Chrome同士はタブを分離できないため、MeetとWeb Voiceを同じChromeで同時利用しないでください。"
        size:12 weight:NSFontWeightRegular];
    instructions.translatesAutoresizingMaskIntoConstraints = NO;
    instructionsBox.contentView = instructions;
    [instructions.leadingAnchor constraintEqualToAnchor:instructionsBox.leadingAnchor constant:12].active = YES;
    [instructions.trailingAnchor constraintEqualToAnchor:instructionsBox.trailingAnchor constant:-12].active = YES;
    [instructions.topAnchor constraintEqualToAnchor:instructionsBox.topAnchor constant:26].active = YES;
    [instructions.bottomAnchor constraintEqualToAnchor:instructionsBox.bottomAnchor constant:-12].active = YES;
    [instructionsBox.widthAnchor constraintGreaterThanOrEqualToConstant:680].active = YES;
    [root addArrangedSubview:instructionsBox];

    NSClipView *clip = [NSClipView new];
    clip.drawsBackground = NO;
    clip.documentView = root;
    scroll.contentView = clip;
    self.window.contentView = scroll;

    [root.widthAnchor constraintGreaterThanOrEqualToAnchor:scroll.widthAnchor constant:-2].active = YES;
}

- (BOOL)isCallCandidate:(GPTAudioCandidate *)candidate {
    NSString *value = [NSString stringWithFormat:@"%@ %@ %@", candidate.name, candidate.bundleID, candidate.detail].lowercaseString;
    return [value containsString:@"chrome"] || [value containsString:@"discord"]
        || [value containsString:@"zoom"] || [value containsString:@"teams"]
        || [value containsString:@"safari"] || [value containsString:@"firefox"];
}

- (BOOL)isGPTCandidate:(GPTAudioCandidate *)candidate {
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

- (void)refresh:(id)sender {
    if (self.engine.running) {
        self.statusLabel.stringValue = @"動作中は再検出できません。停止してから再検出してください。";
        return;
    }
    NSError *error = nil;
    [self.engine refresh:&error];
    [self populate:self.microphonePopup candidates:self.engine.microphones filter:nil];
    [self populate:self.callPopup candidates:self.engine.audioProcesses filter:^BOOL(GPTAudioCandidate *candidate) {
        return [self isCallCandidate:candidate];
    }];
    [self populate:self.gptPopup candidates:self.engine.audioProcesses filter:^BOOL(GPTAudioCandidate *candidate) {
        return [self isGPTCandidate:candidate];
    }];
    [self selectPopup:self.microphonePopup
        candidateWithObjectID:self.engine.currentDefaultInputDevice];
    [self selectPopup:self.callPopup candidateWithBundleID:@"browser.chrome"];
    [self selectPopup:self.gptPopup candidateWithBundleID:@"gpt.desktop"];
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
    if (call && gpt && overlap.count > 0) {
        self.warningLabel.stringValue = @"同じ音声プロセスは両側へ使えません。MeetをChrome、ChatGPT Web VoiceをSafariに分けてください。";
    } else if (call && gpt && [call.bundleID isEqualToString:gpt.bundleID] && [call.bundleID.lowercaseString containsString:@"chrome"]) {
        self.warningLabel.stringValue = @"Chrome同士はタブ単位に分離できません。Chrome + Safari構成を推奨します。";
    } else {
        self.warningLabel.stringValue = @"スピーカー使用時は物理マイクが音を拾うため、安定運用はヘッドホン推奨です。";
    }
}

- (void)start:(id)sender {
    GPTAudioCandidate *microphone = [self selectedCandidate:self.microphonePopup];
    GPTAudioCandidate *call = [self selectedCandidate:self.callPopup];
    GPTAudioCandidate *gpt = [self selectedCandidate:self.gptPopup];
    if (!microphone || !call || !gpt) {
        self.statusLabel.stringValue = @"マイク、通話側、GPT側をすべて選択してください";
        return;
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
        if (self.defaultInputCheckbox.state == NSControlStateValueOn) {
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
    self.defaultInputCheckbox.enabled = !self.engine.running;
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
                printf("  %s [%s] objects=", candidate.name.UTF8String, candidate.active ? "active" : "idle");
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
