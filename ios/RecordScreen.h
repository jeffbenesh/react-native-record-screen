#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>

@interface RecordScreen : RCTEventEmitter <RCTBridgeModule>

@property (nonatomic, strong) RPScreenRecorder *screenRecorder;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, strong) AVAssetWriterInput *micInput;
@property (nonatomic, assign) int screenWidth;
@property (nonatomic, assign) int screenHeight;
@property (nonatomic, assign) BOOL enableMic;
@property (nonatomic, assign) int fps;
@property (nonatomic, assign) int bitrate;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, assign) BOOL encounteredFirstBuffer;

// CF types
@property (nonatomic, assign) CMSampleBufferRef afterAppBackgroundAudioSampleBuffer;
@property (nonatomic, assign) CMSampleBufferRef afterAppBackgroundMicSampleBuffer;
@property (nonatomic, assign) CMSampleBufferRef afterAppBackgroundVideoSampleBuffer;

@end
