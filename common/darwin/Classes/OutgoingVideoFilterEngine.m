#import "OutgoingVideoFilterEngine.h"
#import "OutgoingVideoFilterIds.h"

#import <WebRTC/WebRTC.h>
#import <os/lock.h>

#ifdef DEBUG
#define FWV_LOG(...) NSLog(__VA_ARGS__)
#else
#define FWV_LOG(...) \
  do {               \
  } while (0)
#endif

@interface FWVOutgoingSlot : NSObject
@property(nonatomic, copy) NSString *filterId;
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) int radius;
@property(nonatomic, assign) float downscale;
@end

@implementation FWVOutgoingSlot
@end

@interface OutgoingVideoFilterEngine ()
- (void)fwv_applyConfig:(NSDictionary *)config toSlot:(FWVOutgoingSlot *)slot;
@end

static void fwv_scale_plane_nearest(const uint8_t *src,
                                    int src_stride,
                                    int src_w,
                                    int src_h,
                                    uint8_t *dst,
                                    int dst_stride,
                                    int dst_w,
                                    int dst_h) {
  for (int y = 0; y < dst_h; y++) {
    int sy = (int)((y + 0.5f) * src_h / dst_h);
    if (sy >= src_h) {
      sy = src_h - 1;
    }
    for (int x = 0; x < dst_w; x++) {
      int sx = (int)((x + 0.5f) * src_w / dst_w);
      if (sx >= src_w) {
        sx = src_w - 1;
      }
      dst[y * dst_stride + x] = src[sy * src_stride + sx];
    }
  }
}

static void fwv_blur_plane(uint8_t *data, int stride, int width, int height, int radius) {
  int n = width * height;
  uint8_t *tmp = (uint8_t *)malloc((size_t)n * 2);
  if (!tmp) {
    return;
  }
  uint8_t *acc = tmp + n;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int sum = 0;
      int count = 0;
      for (int k = -radius; k <= radius; k++) {
        int xx = x + k;
        if (xx < 0) {
          xx = 0;
        } else if (xx >= width) {
          xx = width - 1;
        }
        sum += data[y * stride + xx];
        count++;
      }
      tmp[y * width + x] = (uint8_t)(sum / count);
    }
  }
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int sum = 0;
      int count = 0;
      for (int k = -radius; k <= radius; k++) {
        int yy = y + k;
        if (yy < 0) {
          yy = 0;
        } else if (yy >= height) {
          yy = height - 1;
        }
        sum += tmp[yy * width + x];
        count++;
      }
      acc[y * width + x] = (uint8_t)(sum / count);
    }
  }
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      data[y * stride + x] = acc[y * width + x];
    }
  }
  free(tmp);
}

static void fwv_box_blur_i420(id<RTCI420Buffer> i420, int radius) {
  int w = (int)i420.width;
  int h = (int)i420.height;
  fwv_blur_plane((uint8_t *)i420.dataY, (int)i420.strideY, w, h, radius);
  int cw = (w + 1) / 2;
  int ch = (h + 1) / 2;
  int cr = MAX(1, radius / 2);
  fwv_blur_plane((uint8_t *)i420.dataU, (int)i420.strideU, cw, ch, cr);
  fwv_blur_plane((uint8_t *)i420.dataV, (int)i420.strideV, cw, ch, cr);
}

static id<RTCI420Buffer> fwv_i420_downscale_nearest(id<RTCI420Buffer> src, int dstW, int dstH) {
  id<RTCI420Buffer> dst = [[RTCI420Buffer alloc] initWithWidth:dstW height:dstH];
  fwv_scale_plane_nearest(
      src.dataY, (int)src.strideY, (int)src.width, (int)src.height, (uint8_t *)dst.dataY, (int)dst.strideY, dstW, dstH);
  int src_ch_w = ((int)src.width + 1) / 2;
  int src_ch_h = ((int)src.height + 1) / 2;
  int dst_ch_w = (dstW + 1) / 2;
  int dst_ch_h = (dstH + 1) / 2;
  fwv_scale_plane_nearest(src.dataU,
                           (int)src.strideU,
                           src_ch_w,
                           src_ch_h,
                           (uint8_t *)dst.dataU,
                           (int)dst.strideU,
                           dst_ch_w,
                           dst_ch_h);
  fwv_scale_plane_nearest(src.dataV,
                           (int)src.strideV,
                           src_ch_w,
                           src_ch_h,
                           (uint8_t *)dst.dataV,
                           (int)dst.strideV,
                           dst_ch_w,
                           dst_ch_h);
  return dst;
}

static id<RTCI420Buffer> fwv_i420_upscale_nearest(id<RTCI420Buffer> src, int dstW, int dstH) {
  id<RTCI420Buffer> dst = [[RTCI420Buffer alloc] initWithWidth:dstW height:dstH];
  fwv_scale_plane_nearest(
      src.dataY, (int)src.strideY, (int)src.width, (int)src.height, (uint8_t *)dst.dataY, (int)dst.strideY, dstW, dstH);
  int src_ch_w = ((int)src.width + 1) / 2;
  int src_ch_h = ((int)src.height + 1) / 2;
  int dst_ch_w = (dstW + 1) / 2;
  int dst_ch_h = (dstH + 1) / 2;
  fwv_scale_plane_nearest(src.dataU,
                           (int)src.strideU,
                           src_ch_w,
                           src_ch_h,
                           (uint8_t *)dst.dataU,
                           (int)dst.strideU,
                           dst_ch_w,
                           dst_ch_h);
  fwv_scale_plane_nearest(src.dataV,
                           (int)src.strideV,
                           src_ch_w,
                           src_ch_h,
                           (uint8_t *)dst.dataV,
                           (int)dst.strideV,
                           dst_ch_w,
                           dst_ch_h);
  return dst;
}

static RTCVideoFrame *fwv_apply_whole_frame_blur(RTCVideoFrame *frame, int radius, float downscale) {
  id<RTCI420Buffer> i420 = [frame.buffer toI420];
  int w = (int)i420.width;
  int h = (int)i420.height;
  int sw = MAX(2, (int)lroundf(w * downscale));
  int sh = MAX(2, (int)lroundf(h * downscale));
  id<RTCI420Buffer> small = fwv_i420_downscale_nearest(i420, sw, sh);
  fwv_box_blur_i420(small, radius);
  id<RTCI420Buffer> up = fwv_i420_upscale_nearest(small, w, h);
  return [[RTCVideoFrame alloc] initWithBuffer:up rotation:frame.rotation timeStampNs:frame.timeStampNs];
}

@implementation OutgoingVideoFilterEngine {
  os_unfair_lock _lock;
  NSMutableArray<FWVOutgoingSlot *> *_slots;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _slots = [NSMutableArray array];
  }
  return self;
}

- (RTCVideoFrame *)processIncomingFrame:(RTCVideoFrame *)frame {
  os_unfair_lock_lock(&_lock);
  NSArray<FWVOutgoingSlot *> *snap = [_slots copy];
  os_unfair_lock_unlock(&_lock);

  RTCVideoFrame *current = frame;
  for (FWVOutgoingSlot *slot in snap) {
    if (!slot.enabled) {
      continue;
    }
    if ([slot.filterId isEqualToString:kFWVOutgoingFilterWholeFrameBlur]) {
      current = fwv_apply_whole_frame_blur(current, slot.radius, slot.downscale);
    }
  }
  return current;
}

- (BOOL)registerFilterWithId:(NSString *)filterId
                       config:(NSDictionary *)config
                        error:(NSError *__autoreleasing *)error {
  if (filterId.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"FlutterWebRTC"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey : @"filterId is empty"}];
    }
    return NO;
  }
  FWVOutgoingSlot *slot = [[FWVOutgoingSlot alloc] init];
  slot.filterId = [filterId copy];
  slot.enabled = YES;
  slot.radius = 4;
  slot.downscale = 0.25f;
  [self fwv_applyConfig:config toSlot:slot];

  if (![filterId isEqualToString:kFWVOutgoingFilterWholeFrameBlur]) {
    if (error) {
      *error = [NSError errorWithDomain:@"FlutterWebRTC"
                                   code:2
                               userInfo:@{
                                 NSLocalizedDescriptionKey : [NSString stringWithFormat:@"unknown filterId %@", filterId]
                               }];
    }
    return NO;
  }

  os_unfair_lock_lock(&_lock);
  for (NSUInteger i = 0; i < _slots.count; i++) {
    if ([_slots[i].filterId isEqualToString:filterId]) {
      FWV_LOG(@"outgoing filter replace id=%@", filterId);
      [_slots removeObjectAtIndex:i];
      break;
    }
  }
  [_slots addObject:slot];
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (void)unregisterFilterWithId:(NSString *)filterId {
  os_unfair_lock_lock(&_lock);
  for (NSUInteger i = 0; i < _slots.count; i++) {
    if ([_slots[i].filterId isEqualToString:filterId]) {
      [_slots removeObjectAtIndex:i];
      break;
    }
  }
  os_unfair_lock_unlock(&_lock);
}

- (BOOL)setFilterId:(NSString *)filterId enabled:(BOOL)enabled {
  os_unfair_lock_lock(&_lock);
  BOOL ok = NO;
  for (FWVOutgoingSlot *slot in _slots) {
    if ([slot.filterId isEqualToString:filterId]) {
      slot.enabled = enabled;
      ok = YES;
      break;
    }
  }
  os_unfair_lock_unlock(&_lock);
  return ok;
}

- (BOOL)updateConfig:(NSDictionary *)config forFilterId:(NSString *)filterId {
  os_unfair_lock_lock(&_lock);
  BOOL ok = NO;
  for (FWVOutgoingSlot *slot in _slots) {
    if ([slot.filterId isEqualToString:filterId]) {
      [self fwv_applyConfig:config toSlot:slot];
      ok = YES;
      break;
    }
  }
  os_unfair_lock_unlock(&_lock);
  return ok;
}

- (void)clearAll {
  os_unfair_lock_lock(&_lock);
  [_slots removeAllObjects];
  os_unfair_lock_unlock(&_lock);
}

- (void)fwv_applyConfig:(NSDictionary *)config toSlot:(FWVOutgoingSlot *)slot {
  if (![config isKindOfClass:[NSDictionary class]] || config.count == 0) {
    return;
  }
  NSNumber *r = config[@"radius"];
  if ([r isKindOfClass:[NSNumber class]]) {
    slot.radius = (int)MAX(1, MIN(32, r.intValue));
  }
  NSNumber *sigma = config[@"sigma"];
  if ([sigma isKindOfClass:[NSNumber class]]) {
    slot.radius = (int)MAX(1, MIN(32, (int)lroundf(sigma.floatValue)));
  }
  NSNumber *d = config[@"downscale"];
  if ([d isKindOfClass:[NSNumber class]]) {
    float v = d.floatValue;
    slot.downscale = MAX(0.1f, MIN(1.f, v));
  }
}

@end
