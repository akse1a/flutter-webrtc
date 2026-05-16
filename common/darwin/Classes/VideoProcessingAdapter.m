#import "VideoProcessingAdapter.h"
#import "OutgoingVideoFilterEngine.h"
#import <os/lock.h>

@implementation VideoProcessingAdapter {
  RTCVideoSource* _videoSource;
  CGSize _frameSize;
  NSArray<id<ExternalVideoProcessingDelegate>>* _processors;
  os_unfair_lock _lock;
  OutgoingVideoFilterEngine* _outgoingEngine;
}

- (instancetype)initWithRTCVideoSource:(RTCVideoSource*)source {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _videoSource = source;
    _processors = [NSArray<id<ExternalVideoProcessingDelegate>> new];
    _outgoingEngine = [[OutgoingVideoFilterEngine alloc] init];
  }
  return self;
}

- (OutgoingVideoFilterEngine *)outgoingFilterEngine {
  return _outgoingEngine;
}

- (RTCVideoSource* _Nonnull) source {
    return _videoSource;
}

- (void)addProcessing:(id<ExternalVideoProcessingDelegate>)processor {
  os_unfair_lock_lock(&_lock);
  _processors = [_processors arrayByAddingObject:processor];
  os_unfair_lock_unlock(&_lock);
}

- (void)removeProcessing:(id<ExternalVideoProcessingDelegate>)processor {
  os_unfair_lock_lock(&_lock);
  _processors = [_processors
      filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject,
                                                                        NSDictionary* bindings) {
        return evaluatedObject != processor;
      }]];
  os_unfair_lock_unlock(&_lock);
}

- (void)setSize:(CGSize)size {
  _frameSize = size;
}

- (void)capturer:(RTC_OBJC_TYPE(RTCVideoCapturer) *)capturer
    didCaptureVideoFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  RTCVideoFrame *processed = [_outgoingEngine processIncomingFrame:frame];
  os_unfair_lock_lock(&_lock);
  RTCVideoFrame *current = processed;
  for (id<ExternalVideoProcessingDelegate> processor in _processors) {
    current = [processor onFrame:current];
  }
  [_videoSource capturer:capturer didCaptureVideoFrame:current];
  os_unfair_lock_unlock(&_lock);
}

@end
