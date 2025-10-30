// RecordScreen.mm
#import "RecordScreen.h"
#import <React/RCTConvert.h>
#import <Photos/Photos.h>
#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>

@interface RecordScreen ()
@property (nonatomic, strong) RPScreenRecorder *screenRecorder;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInput *audioInput;
@property (nonatomic, assign) BOOL isRecording;
@property (nonatomic, strong) NSString *outputPath;
@end

@implementation RecordScreen

UIBackgroundTaskIdentifier _backgroundTaskID = UIBackgroundTaskInvalid;

- (NSArray<NSString *> *)supportedEvents {
    return @[];
}

- (void) muteAudioInBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    CMBlockBufferRef audioBlockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!audioBlockBuffer) return;

    size_t totalLength = 0;
    SInt16 *samples = NULL;

    OSStatus status = CMBlockBufferGetDataPointer(audioBlockBuffer, 0, NULL, &totalLength, (char **)(&samples));
    if (status != noErr || !samples) return;

    NSUInteger sampleCount = totalLength / sizeof(SInt16);
    for (NSUInteger i = 0; i < sampleCount; i++) {
        samples[i] = 0;
    }
}

- (int) adjustMultipleOf2:(int)value {
    return (value % 2 == 1) ? value + 1 : value;
}

- (AVAssetWriterInput *)createVideoInput {
    NSDictionary *videoSettings = @{
        AVVideoCodecKey: AVVideoCodecH264,
        AVVideoWidthKey: @([self adjustMultipleOf2:self.screenWidth]),
        AVVideoHeightKey: @([self adjustMultipleOf2:self.screenHeight])
    };

    AVAssetWriterInput *videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    videoInput.expectsMediaDataInRealTime = YES;
    return videoInput;
}

- (AVAssetWriterInput *)createAudioInput {
    NSDictionary *audioOutputSettings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @44100,
        AVNumberOfChannelsKey: @2,
        AVEncoderBitRateKey: @128000
    };

    AVAssetWriterInput *audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioOutputSettings];
    audioInput.expectsMediaDataInRealTime = YES;
    return audioInput;
}

- (void)requestPhotosPermissionWithCompletion:(void(^)(BOOL granted))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];

        if (status == PHAuthorizationStatusAuthorized) {
            completion(YES);
        } else if (status == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authStatus) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(authStatus == PHAuthorizationStatusAuthorized);
                });
            }];
        } else {
            completion(NO);
        }
    });
}

RCT_EXPORT_MODULE()

RCT_EXPORT_METHOD(setup: (NSDictionary *)config) {
    self.screenWidth = config[@"width"] ? [RCTConvert int:config[@"width"]] : 720;
    self.screenHeight = config[@"height"] ? [RCTConvert int:config[@"height"]] : 1280;
    self.enableMic = config[@"mic"] ? [RCTConvert BOOL:config[@"mic"]] : NO;
    self.bitrate = config[@"bitrate"] ? [RCTConvert int:config[@"bitrate"]] : 6000000;
    self.fps = config[@"fps"] ? [RCTConvert int:config[@"fps"]] : 30;
}

RCT_REMAP_METHOD(startRecording, resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    // Check if already recording
    if (self.isRecording) {
        resolve(@"already_recording");
        return;
    }

    // Setup background task
    _backgroundTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        if (_backgroundTaskID != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:_backgroundTaskID];
            _backgroundTaskID = UIBackgroundTaskInvalid;
        }
    }];

    // Initialize screen recorder
    self.screenRecorder = [RPScreenRecorder sharedRecorder];
    if (self.screenRecorder.isRecording) {
        resolve(@"already_recording");
        return;
    }

    // Create output file path
    NSString *outputURL = NSTemporaryDirectory();
    NSString *fileName = [NSString stringWithFormat:@"recording_%@.mp4", [[NSUUID UUID] UUIDString]];
    self.outputPath = [outputURL stringByAppendingPathComponent:fileName];

    // Create asset writer
    NSError *writerError = nil;
    self.writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:self.outputPath] fileType:AVFileTypeMPEG4 error:&writerError];
    if (!self.writer) {
        NSLog(@"Failed to create asset writer: %@", writerError);
        reject(@"writer_error", @"Failed to create video writer", writerError);
        return;
    }

    // Create and add video input
    self.videoInput = [self createVideoInput];
    if (![self.writer canAddInput:self.videoInput]) {
        reject(@"input_error", @"Cannot add video input", nil);
        return;
    }
    [self.writer addInput:self.videoInput];

    // Create and add audio input if mic is enabled
    if (self.enableMic) {
        self.audioInput = [self createAudioInput];
        if (self.audioInput && [self.writer canAddInput:self.audioInput]) {
            [self.writer addInput:self.audioInput];
            self.screenRecorder.microphoneEnabled = YES;
        } else {
            self.enableMic = NO;
            self.screenRecorder.microphoneEnabled = NO;
        }
    } else {
        self.screenRecorder.microphoneEnabled = NO;
    }

    // Start writing
    if (![self.writer startWriting]) {
        NSLog(@"Failed to start writing: %@", self.writer.error);
        reject(@"writer_start_failed", @"Failed to start writing", self.writer.error);
        return;
    }

    __block RCTPromiseResolveBlock resolveBlock = resolve;
    __block RCTPromiseRejectBlock rejectBlock = reject;
    __block BOOL hasStartedSession = NO;

    // Request video permission and start capture
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        if (!granted) {
            if (rejectBlock) {
                rejectBlock(@"permission_denied", @"Screen recording permission denied", nil);
                rejectBlock = nil;
            }
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.screenRecorder startCaptureWithHandler:^(CMSampleBufferRef sampleBuffer, RPSampleBufferType bufferType, NSError* error) {
                if (error) {
                    NSLog(@"Capture error: %@", error);
                    if (rejectBlock) {
                        rejectBlock(@"capture_error", error.localizedDescription, error);
                        rejectBlock = nil;
                    }
                    return;
                }

                if (!sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
                    return;
                }

                CFRetain(sampleBuffer);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        // Check writer status
                        if (self.writer.status == AVAssetWriterStatusFailed) {
                            NSLog(@"Writer failed: %@", self.writer.error);
                            if (resolveBlock) {
                                resolveBlock(@"error");
                                resolveBlock = nil;
                            }
                            CFRelease(sampleBuffer);
                            return;
                        }

                        // Start session on first video frame
                        if (!hasStartedSession && bufferType == RPSampleBufferTypeVideo) {
                            CMTime startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
                            [self.writer startSessionAtSourceTime:startTime];
                            hasStartedSession = YES;
                            self.isRecording = YES;

                            if (resolveBlock) {
                                resolveBlock(@"started");
                                resolveBlock = nil;
                            }
                        }

                        // Process samples only after session has started
                        if (hasStartedSession && self.writer.status == AVAssetWriterStatusWriting) {
                            switch (bufferType) {
                                case RPSampleBufferTypeVideo:
                                    if (self.videoInput.isReadyForMoreMediaData) {
                                        [self.videoInput appendSampleBuffer:sampleBuffer];
                                    }
                                    break;
                                case RPSampleBufferTypeAudioApp:
                                case RPSampleBufferTypeAudioMic:
                                    if (self.audioInput && self.audioInput.isReadyForMoreMediaData) {
                                        if (self.enableMic) {
                                            [self.audioInput appendSampleBuffer:sampleBuffer];
                                        } else {
                                            [self muteAudioInBuffer:sampleBuffer];
                                        }
                                    }
                                    break;
                                default:
                                    break;
                            }
                        }
                    }
                    CFRelease(sampleBuffer);
                });
            } completionHandler:^(NSError* error) {
                if (error) {
                    NSLog(@"Start capture completion error: %@", error);
                    if (rejectBlock) {
                        rejectBlock(@"capture_start_error", error.localizedDescription, error);
                        rejectBlock = nil;
                    }
                }
            }];
        });
    }];
}

RCT_REMAP_METHOD(stopRecording, resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject) {
    // End background task
    if (_backgroundTaskID != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_backgroundTaskID];
        _backgroundTaskID = UIBackgroundTaskInvalid;
    }

    // Check if recording
    if (!self.isRecording || !self.screenRecorder || !self.screenRecorder.isRecording) {
        reject(@"not_recording", @"Not currently recording", nil);
        return;
    }

    self.isRecording = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.screenRecorder stopCaptureWithHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"Stop capture error: %@", error);
                reject(@"stop_error", @"Failed to stop recording", error);
                return;
            }

            // Mark inputs as finished
            if (self.audioInput) {
                [self.audioInput markAsFinished];
            }
            if (self.videoInput) {
                [self.videoInput markAsFinished];
            }

            // Finish writing
            if (self.writer && self.writer.status == AVAssetWriterStatusWriting) {
                [self.writer finishWritingWithCompletionHandler:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self handleRecordingCompletion:resolve reject:reject];
                    });
                }];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self handleRecordingCompletion:resolve reject:reject];
                });
            }
        }];
    });
}

- (void)handleRecordingCompletion:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    // Check if file exists and has content
    if (!self.outputPath) {
        reject(@"file_error", @"No output path", nil);
        [self cleanup];
        return;
    }

    NSError *attributesError;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.outputPath error:&attributesError];

    if (attributesError || !fileAttributes) {
        NSLog(@"Error getting file attributes: %@", attributesError);
        reject(@"file_error", @"Cannot access recorded file", attributesError);
        [self cleanup];
        return;
    }

    NSNumber *fileSize = fileAttributes[NSFileSize];
    if (!fileSize || [fileSize integerValue] == 0) {
        NSLog(@"Recorded file is empty");
        reject(@"file_error", @"Recorded file is empty", nil);
        [self cleanup];
        return;
    }

    // Save to photos
    [self requestPhotosPermissionWithCompletion:^(BOOL granted) {
        if (!granted) {
            resolve(@"permission_denied");
            [self cleanup];
            return;
        }

        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:self.outputPath]];
        } completionHandler:^(BOOL success, NSError * _Nullable saveError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    resolve(@"saved");
                } else {
                    NSLog(@"Failed to save to Photos: %@", saveError);
                    resolve(@"save_failed");
                }
                [self cleanup];
            });
        }];
    }];
}

- (void)cleanup {
    // Cleanup resources
    self.screenRecorder = nil;
    self.writer = nil;
    self.videoInput = nil;
    self.audioInput = nil;

    // Remove temporary file
    if (self.outputPath) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSFileManager defaultManager] removeItemAtPath:self.outputPath error:nil];
            self.outputPath = nil;
        });
    }
}

RCT_REMAP_METHOD(clean,
                 cleanResolve:(RCTPromiseResolveBlock)resolve
                 cleanReject:(RCTPromiseRejectBlock)reject) {
    NSString *tempPath = NSTemporaryDirectory();
    NSArray *tempContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tempPath error:nil];
    for (NSString *file in tempContents) {
        if ([file hasSuffix:@".mp4"]) {
            NSString *filePath = [tempPath stringByAppendingPathComponent:file];
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        }
    }

    resolve(@"cleaned");
}

RCT_REMAP_METHOD(isRecording,
                 isRecordingResolve:(RCTPromiseResolveBlock)resolve
                 isRecordingReject:(RCTPromiseRejectBlock)reject) {
    BOOL isRecording = self.isRecording && self.screenRecorder && self.screenRecorder.isRecording;
    resolve([NSNumber numberWithBool:isRecording]);
}

@end
