#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface GPTAudioCandidate : NSObject
@property(nonatomic) AudioObjectID objectID;
@property(nonatomic, copy) NSArray<NSNumber *> *objectIDs;
@property(nonatomic) pid_t pid;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic) BOOL active;
@end

@interface GPTCallMixerEngine : NSObject

@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, copy, readonly) NSString *statusText;
@property(nonatomic, copy, readonly) NSArray<GPTAudioCandidate *> *microphones;
@property(nonatomic, copy, readonly) NSArray<GPTAudioCandidate *> *audioProcesses;

- (BOOL)refresh:(NSError **)error;
- (BOOL)startWithMicrophoneDevice:(AudioObjectID)microphoneDevice
              callProcessObjects:(NSArray<NSNumber *> *)callProcessObjects
                callProcessFamily:(NSString *)callProcessFamily
               gptProcessObjects:(NSArray<NSNumber *> *)gptProcessObjects
                 gptProcessFamily:(NSString *)gptProcessFamily
                            error:(NSError **)error;
- (void)stop;

- (AudioObjectID)currentDefaultInputDevice;
- (BOOL)isChatGPTDeviceCurrentDefaultInput;
- (NSString *)deviceNameForID:(AudioObjectID)deviceID;
- (BOOL)setDefaultInputDevice:(AudioObjectID)deviceID error:(NSError **)error;
- (BOOL)setChatGPTDeviceAsDefaultInput:(NSError **)error;

+ (NSString *)toChatGPTDeviceUID;
+ (NSString *)toCallDeviceUID;

@end

NS_ASSUME_NONNULL_END
