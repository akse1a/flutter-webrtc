#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@class OutgoingVideoFilterEngine;

@protocol ExternalVideoProcessingDelegate
- (RTC_OBJC_TYPE(RTCVideoFrame) * _Nonnull)onFrame:(RTC_OBJC_TYPE(RTCVideoFrame) * _Nonnull)frame;
@end

@interface VideoProcessingAdapter : NSObject <RTCVideoCapturerDelegate>

- (_Nonnull instancetype)initWithRTCVideoSource:(RTCVideoSource* _Nonnull)source;

- (void)addProcessing:(_Nonnull id<ExternalVideoProcessingDelegate>)processor;

- (void)removeProcessing:(_Nonnull id<ExternalVideoProcessingDelegate>)processor;

- (RTCVideoSource* _Nonnull) source;

@property(nonatomic, strong, readonly) OutgoingVideoFilterEngine *outgoingFilterEngine;

@end
