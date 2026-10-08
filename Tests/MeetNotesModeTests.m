// Exercise controller actions with synthetic devices and a fake audio engine.
// No Process Tap, microphone capture, or default-device change is performed.
#define main GPTCallMixerApplicationMain
#import "../GPTCallMixerApp/main.m"
#undef main

#import <objc/runtime.h>

@interface TestMixerEngine : GPTCallMixerEngine
@property(nonatomic) BOOL simulatedRunning;
@property(nonatomic) AudioObjectID simulatedDefaultInput;
@property(nonatomic) NSUInteger startCount;
@property(nonatomic) NSUInteger switchCount;
@property(nonatomic) NSUInteger restoreCount;
@property(nonatomic, copy) NSArray<GPTAudioCandidate *> *testMicrophones;
@property(nonatomic, copy) NSArray<GPTAudioCandidate *> *testProcesses;
@property(nonatomic, copy) NSString *lastCallFamily;
@property(nonatomic, copy) NSString *lastGPTFamily;
@property(nonatomic, copy) NSArray<NSNumber *> *lastCallObjects;
@property(nonatomic, copy) NSArray<NSNumber *> *lastGPTObjects;
@end

@implementation TestMixerEngine
- (BOOL)isRunning { return self.simulatedRunning; }
- (NSString *)statusText { return @"Test engine"; }
- (NSArray<GPTAudioCandidate *> *)microphones { return self.testMicrophones; }
- (NSArray<GPTAudioCandidate *> *)audioProcesses { return self.testProcesses; }
- (BOOL)refresh:(NSError **)error {
    if (error) *error = nil;
    return YES;
}
- (AudioObjectID)currentDefaultInputDevice { return self.simulatedDefaultInput; }
- (BOOL)isChatGPTDeviceCurrentDefaultInput { return self.simulatedDefaultInput == 1000; }
- (BOOL)setChatGPTDeviceAsDefaultInput:(NSError **)error {
    if (error) *error = nil;
    self.switchCount += 1;
    self.simulatedDefaultInput = 1000;
    return YES;
}
- (BOOL)setDefaultInputDevice:(AudioObjectID)deviceID error:(NSError **)error {
    if (error) *error = nil;
    self.restoreCount += 1;
    self.simulatedDefaultInput = deviceID;
    return YES;
}
- (BOOL)startWithMicrophoneDevice:(AudioObjectID)microphoneDevice
              callProcessObjects:(NSArray<NSNumber *> *)callProcessObjects
                callProcessFamily:(NSString *)callProcessFamily
               gptProcessObjects:(NSArray<NSNumber *> *)gptProcessObjects
                 gptProcessFamily:(NSString *)gptProcessFamily
                            error:(NSError **)error {
    (void)microphoneDevice;
    self.lastCallObjects = callProcessObjects;
    self.lastCallFamily = callProcessFamily;
    self.lastGPTObjects = gptProcessObjects;
    self.lastGPTFamily = gptProcessFamily;
    if (error) *error = nil;
    self.startCount += 1;
    self.simulatedRunning = YES;
    return YES;
}
- (void)stop { self.simulatedRunning = NO; }
@end

static NSUserDefaults *testDefaults;

static id IsolatedStandardDefaults(id object, SEL selector) {
    (void)object;
    (void)selector;
    return testDefaults;
}

static void Check(BOOL condition, NSString *message) {
    if (!condition) [NSException raise:@"MeetNotesModeTestFailure" format:@"%@", message];
}

static GPTAudioCandidate *Candidate(AudioObjectID objectID, NSString *family, BOOL active) {
    GPTAudioCandidate *candidate = [GPTAudioCandidate new];
    candidate.objectID = objectID;
    candidate.objectIDs = @[@(objectID)];
    candidate.name = GPTProcessFamilyName(family, family);
    candidate.bundleID = family;
    candidate.detail = @"Synthetic test candidate";
    candidate.active = active;
    return candidate;
}

static GPTCallMixerAppDelegate *Controller(BOOL meetMode, TestMixerEngine **testEngine) {
    [testDefaults setBool:meetMode forKey:kMeetNotesModeDefaultsKey];
    TestMixerEngine *engine = [TestMixerEngine new];
    engine.simulatedDefaultInput = 42;
    engine.testMicrophones = @[Candidate(42, @"test.microphone", YES)];
    engine.testProcesses = @[
        Candidate(10, @"browser.chrome", YES),
        Candidate(20, @"call.slack", NO),
        Candidate(30, @"call.discord", YES),
        Candidate(40, @"gpt.desktop", NO)
    ];
    GPTCallMixerAppDelegate *controller = [GPTCallMixerAppDelegate new];
    controller.engine = engine;
    controller.previousDefaultInputDevice = kAudioObjectUnknown;
    [controller buildWindow];
    [controller refresh:nil];
    [controller updateButtons];
    *testEngine = engine;
    return controller;
}

static void SetMeetMode(GPTCallMixerAppDelegate *controller, BOOL enabled) {
    controller.meetNotesCheckbox.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [controller meetNotesModeChanged:nil];
}

static void TestModeRoundTrips(void) {
    TestMixerEngine *engine = nil;
    GPTCallMixerAppDelegate *controller = Controller(NO, &engine);
    Check(controller.defaultInputCheckbox.state == NSControlStateValueOn, @"Voice defaults to input switching");
    SetMeetMode(controller, YES);
    Check(controller.defaultInputCheckbox.state == NSControlStateValueOff, @"Notes disables input switching");
    Check(!controller.defaultInputCheckbox.enabled, @"Notes cannot enable input switching");
    SetMeetMode(controller, NO);
    Check(controller.defaultInputCheckbox.state == NSControlStateValueOn, @"Returning to Voice restores the ON preference");
    Check(controller.defaultInputCheckbox.enabled, @"Voice can change input switching");

    controller.defaultInputCheckbox.state = NSControlStateValueOff;
    SetMeetMode(controller, YES);
    SetMeetMode(controller, YES);
    SetMeetMode(controller, NO);
    Check(controller.defaultInputCheckbox.state == NSControlStateValueOff, @"Returning to Voice preserves an explicit OFF preference");

    controller.defaultInputCheckbox.state = NSControlStateValueOn;
    SetMeetMode(controller, YES);
    SetMeetMode(controller, YES);
    SetMeetMode(controller, NO);
    Check(controller.defaultInputCheckbox.state == NSControlStateValueOn, @"Repeated mode updates preserve the Voice preference");
    Check(engine.switchCount == 0 && engine.restoreCount == 0, @"Changing modes never changes real input devices");
}

static void TestSavedNotesMode(void) {
    TestMixerEngine *engine = nil;
    GPTCallMixerAppDelegate *controller = Controller(YES, &engine);
    Check([controller isMeetNotesMode], @"Saved notes mode is restored");
    Check(!controller.defaultInputCheckbox.enabled && controller.defaultInputCheckbox.state == NSControlStateValueOff,
          @"Saved notes mode disables input switching");
    Check([[controller selectedCandidate:controller.gptPopup].bundleID isEqualToString:@"call.discord"],
          @"An active Discord source is preferred over idle Slack");
    SetMeetMode(controller, NO);
    Check(controller.defaultInputCheckbox.state == NSControlStateValueOn, @"Saved notes mode can return to the Voice default");
}

static void TestNotesDoesNotChangeDefaultInput(void) {
    TestMixerEngine *engine = nil;
    GPTCallMixerAppDelegate *controller = Controller(YES, &engine);
    // Even if the disabled control is modified programmatically, the routing
    // action must keep the real default microphone for conversation apps.
    controller.defaultInputCheckbox.state = NSControlStateValueOn;
    [controller start:nil];
    Check(engine.startCount == 1 && engine.running, @"Valid notes routing starts");
    Check(engine.switchCount == 0 && engine.simulatedDefaultInput == 42, @"Notes keeps the physical default input");
    Check(!controller.meetNotesCheckbox.enabled && !controller.refreshButton.enabled,
          @"Routing locks mode and process detection");
    [controller stop:nil];
    Check(!engine.running && engine.restoreCount == 0, @"Notes stops without restoring an unchanged input");
    Check(controller.meetNotesCheckbox.enabled && controller.refreshButton.enabled, @"Stop unlocks routing configuration");
}

static void TestSharedProcessRejection(void) {
    TestMixerEngine *engine = nil;
    GPTCallMixerAppDelegate *controller = Controller(YES, &engine);
    [controller selectPopup:controller.gptPopup candidateWithBundleID:@"browser.chrome"];
    [controller start:nil];
    Check(engine.startCount == 0, @"Notes rejects using the same browser for both sides");

    GPTAudioCandidate *call = [controller selectedCandidate:controller.callPopup];
    [controller selectPopup:controller.gptPopup candidateWithBundleID:@"call.slack"];
    GPTAudioCandidate *source = [controller selectedCandidate:controller.gptPopup];
    source.objectIDs = call.objectIDs;
    [controller start:nil];
    Check(engine.startCount == 0, @"Notes rejects overlapping objects even with different family labels");

    source.objectIDs = @[@20];
    [controller start:nil];
    Check(engine.startCount == 1, @"Different source objects allow notes routing");
    [controller stop:nil];
}

static void TestVoiceInputRestoration(void) {
    TestMixerEngine *engine = nil;
    GPTCallMixerAppDelegate *controller = Controller(NO, &engine);
    [controller start:nil];
    Check(engine.switchCount == 1 && engine.simulatedDefaultInput == 1000, @"Voice switches to its virtual input");
    [controller stop:nil];
    Check(engine.restoreCount == 1 && engine.simulatedDefaultInput == 42, @"Voice restores the previous physical input");

    [controller start:nil];
    engine.simulatedDefaultInput = 99;
    [controller stop:nil];
    Check(engine.restoreCount == 1 && engine.simulatedDefaultInput == 99, @"Stop preserves an input changed by the user");
}

static void TestNewConversationApps(void) {
    for (NSString *family in @[@"call.line", @"call.zoom", @"call.apple-phone"]) {
        TestMixerEngine *engine = nil;
        GPTCallMixerAppDelegate *controller = Controller(YES, &engine);
        GPTAudioCandidate *source = Candidate(50, family, YES);
        source.objectIDs = @[@50, @51];
        engine.testProcesses = @[
            Candidate(10, @"browser.chrome", YES),
            Candidate(20, @"call.slack", NO),
            source,
            Candidate(40, @"gpt.desktop", NO)
        ];
        controller.hasRefreshedCandidates = NO;
        [controller refresh:nil];
        Check([[controller selectedCandidate:controller.gptPopup].bundleID isEqualToString:family],
              @"An active LINE, Zoom, or Phone source is preferred over idle Slack");
        [controller start:nil];
        Check([engine.lastCallFamily isEqualToString:@"browser.chrome"] && [engine.lastGPTFamily isEqualToString:family],
              @"Notes routes the selected app as the conversation source and Chrome as the Meet side");
        Check([engine.lastGPTObjects isEqualToArray:@[@50, @51]], @"Notes forwards the entire app process group");
        Check(engine.switchCount == 0 && engine.simulatedDefaultInput == 42, @"New notes sources retain the physical microphone");
        [controller stop:nil];

        SetMeetMode(controller, NO);
        [controller selectPopup:controller.callPopup candidateWithBundleID:family];
        [controller refresh:nil];
        Check([[controller selectedCandidate:controller.callPopup].bundleID isEqualToString:family],
              @"Re-detection preserves the explicitly selected call app");
        [controller start:nil];
        Check([engine.lastCallFamily isEqualToString:family] && [engine.lastGPTFamily isEqualToString:@"gpt.desktop"],
              @"Voice routes the selected app as the call side and ChatGPT as the other side");
        Check([engine.lastCallObjects isEqualToArray:@[@50, @51]], @"Voice forwards the entire app process group");
        [controller stop:nil];

        SetMeetMode(controller, YES);
        [controller selectPopup:controller.gptPopup candidateWithBundleID:family];
        // Simulate a new helper appearing after joining a call.
        source.objectID = 52;
        source.objectIDs = @[@52, @53];
        [controller refresh:nil];
        Check([[controller selectedCandidate:controller.gptPopup].bundleID isEqualToString:family],
              @"Re-detection preserves the selected notes source despite new process IDs");
        [controller start:nil];
        Check([engine.lastGPTObjects isEqualToArray:@[@52, @53]], @"Restart uses the new helper IDs");
        Check(engine.switchCount == 1, @"Only the previous Voice start changed the default input");
        [controller stop:nil];
        [controller updateWarning];
        if ([family isEqualToString:@"call.apple-phone"]) {
            Check([controller.warningLabel.stringValue containsString:@"FaceTime"], @"Phone selection discloses shared call audio");
        }
    }
}

static void TestIdlePhoneDoesNotOverrideSafari(void) {
    TestMixerEngine *engine = nil;
    GPTCallMixerAppDelegate *controller = Controller(YES, &engine);
    engine.testProcesses = @[
        Candidate(10, @"browser.chrome", YES),
        Candidate(20, @"call.apple-phone", NO),
        Candidate(30, @"browser.safari", NO)
    ];
    controller.hasRefreshedCandidates = NO;
    [controller refresh:nil];
    Check([[controller selectedCandidate:controller.gptPopup].bundleID isEqualToString:@"browser.safari"],
          @"Idle Apple call services do not take priority over Safari");
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"jp.local.gptcallmixer.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        IMP original = method_setImplementation(method, (IMP)IsolatedStandardDefaults);
        int result = 0;
        @try {
            [NSApplication sharedApplication];
            TestModeRoundTrips();
            TestSavedNotesMode();
            TestNotesDoesNotChangeDefaultInput();
            TestSharedProcessRejection();
            TestVoiceInputRestoration();
            TestNewConversationApps();
            TestIdlePhoneDoesNotOverrideSafari();
            printf("MeetNotesModeTests: PASS (synthetic audio engine, isolated preferences)\n");
        } @catch (NSException *exception) {
            fprintf(stderr, "MeetNotesModeTests: FAIL: %s\n", exception.reason.UTF8String);
            result = 1;
        } @finally {
            method_setImplementation(method, original);
            [testDefaults removePersistentDomainForName:suite];
            testDefaults = nil;
        }
        return result;
    }
}
