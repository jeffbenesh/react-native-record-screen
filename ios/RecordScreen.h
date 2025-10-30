#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RecordScreen : RCTEventEmitter <RCTBridgeModule>
@property (nonatomic, assign) int screenWidth;
@property (nonatomic, assign) int screenHeight;
@property (nonatomic, assign) BOOL enableMic;
@property (nonatomic, assign) int bitrate;
@property (nonatomic, assign) int fps;

@end
