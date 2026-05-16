#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Runs before other ExternalVideoProcessingDelegate entries on VideoProcessingAdapter.
 * CPU blur is heavy at full resolution; default blur uses downscale → blur → upscale (nearest).
 * TODO: Metal/OpenGL path without changing Dart API.
 */
@interface OutgoingVideoFilterEngine : NSObject

- (RTCVideoFrame *)processIncomingFrame:(RTCVideoFrame *)frame;

- (BOOL)registerFilterWithId:(NSString *)filterId
                       config:(NSDictionary *_Nullable)config
                        error:(NSError *_Nullable *_Nullable)error;

- (void)unregisterFilterWithId:(NSString *)filterId;

- (BOOL)setFilterId:(NSString *)filterId enabled:(BOOL)enabled;

- (BOOL)updateConfig:(NSDictionary *_Nullable)config forFilterId:(NSString *)filterId;

- (void)clearAll;

@end

NS_ASSUME_NONNULL_END
