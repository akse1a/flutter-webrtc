package com.cloudwebrtc.webrtc.video;

import android.util.Log;

import androidx.annotation.Nullable;

import org.webrtc.JavaI420Buffer;
import org.webrtc.VideoFrame;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Ordered chain of outgoing (pre-encode) video filters for a {@link LocalVideoTrack}.
 *
 * <p>CPU blur at full resolution is expensive; the default {@link WholeFrameBlurFilter} uses
 * downscale → blur → upscale (nearest). TODO: optional GPU path (OpenGL) without changing the Dart
 * API.
 */
public class OutgoingVideoFiltersController {
  private static final String TAG = "OutgoingVideoFilters";

  private final Object lock = new Object();
  private final List<FilterSlot> slots = new ArrayList<>();

  public VideoFrame apply(VideoFrame input) {
    VideoFrame current = input;
    synchronized (lock) {
      for (FilterSlot slot : slots) {
        if (!slot.enabled.get()) {
          continue;
        }
        VideoFrame next = slot.filter.process(current);
        if (next != current) {
          current = next;
        }
      }
    }
    return current;
  }

  public void clear() {
    synchronized (lock) {
      for (FilterSlot slot : slots) {
        slot.filter.release();
      }
      slots.clear();
    }
  }

  /**
   * @return false if track is not a supported outgoing filter target
   */
  public boolean register(String filterId, @Nullable Map<String, Object> config) {
    synchronized (lock) {
      int existing = indexOf(filterId);
      if (existing >= 0) {
        if (Log.isLoggable(TAG, Log.DEBUG)) {
          Log.d(TAG, "register: replacing existing filter id=" + filterId);
        }
        slots.get(existing).filter.release();
        slots.remove(existing);
      }
      OutgoingVideoFrameFilter impl = createFilter(filterId);
      if (impl == null) {
        return false;
      }
      impl.updateConfig(config);
      FilterSlot slot = new FilterSlot(filterId, impl, new AtomicBoolean(true));
      slots.add(slot);
    }
    return true;
  }

  public boolean unregister(String filterId) {
    synchronized (lock) {
      int idx = indexOf(filterId);
      if (idx < 0) {
        return false;
      }
      slots.get(idx).filter.release();
      slots.remove(idx);
    }
    return true;
  }

  public boolean setEnabled(String filterId, boolean enabled) {
    synchronized (lock) {
      int idx = indexOf(filterId);
      if (idx < 0) {
        return false;
      }
      slots.get(idx).enabled.set(enabled);
    }
    return true;
  }

  public boolean updateConfig(String filterId, @Nullable Map<String, Object> config) {
    synchronized (lock) {
      int idx = indexOf(filterId);
      if (idx < 0) {
        return false;
      }
      slots.get(idx).filter.updateConfig(config);
    }
    return true;
  }

  private int indexOf(String filterId) {
    for (int i = 0; i < slots.size(); i++) {
      if (slots.get(i).filterId.equals(filterId)) {
        return i;
      }
    }
    return -1;
  }

  @Nullable
  private static OutgoingVideoFrameFilter createFilter(String filterId) {
    if (OutgoingVideoFilterIds.WHOLE_FRAME_BLUR.equals(filterId)) {
      return new WholeFrameBlurFilter();
    }
    return null;
  }

  private static final class FilterSlot {
    final String filterId;
    final OutgoingVideoFrameFilter filter;
    final AtomicBoolean enabled;

    FilterSlot(String filterId, OutgoingVideoFrameFilter filter, AtomicBoolean enabled) {
      this.filterId = filterId;
      this.filter = filter;
      this.enabled = enabled;
    }
  }

  /** Pluggable outgoing filter; implementations must release replaced frame buffers. */
  public interface OutgoingVideoFrameFilter {
    /** Returns {@code input} or a new frame; must not return null. */
    VideoFrame process(VideoFrame input);

    void updateConfig(@Nullable Map<String, Object> config);

    void release();
  }

  static final class WholeFrameBlurFilter implements OutgoingVideoFrameFilter {
    private volatile int blurRadius = 4;
    /** Downscale factor in (0,1], applied before blur. */
    private volatile float downscale = 0.25f;

    @Override
    public void updateConfig(@Nullable Map<String, Object> config) {
      if (config == null) {
        return;
      }
      Object r = config.get("radius");
      if (r instanceof Number) {
        blurRadius = Math.max(1, Math.min(32, ((Number) r).intValue()));
      }
      Object s = config.get("sigma");
      if (s instanceof Number) {
        blurRadius = Math.max(1, Math.min(32, Math.round(((Number) s).floatValue())));
      }
      Object d = config.get("downscale");
      if (d instanceof Number) {
        float v = ((Number) d).floatValue();
        downscale = Math.max(0.1f, Math.min(1f, v));
      }
    }

    @Override
    public void release() {
      // no native handles
    }

    @Override
    public VideoFrame process(VideoFrame input) {
      VideoFrame.Buffer inBuf = input.getBuffer();
      VideoFrame.I420Buffer i420 = inBuf.toI420();
      inBuf.release();

      int w = i420.getWidth();
      int h = i420.getHeight();
      float scale = downscale;
      int sw = Math.max(2, Math.round(w * scale));
      int sh = Math.max(2, Math.round(h * scale));

      VideoFrame.I420Buffer small = I420Transforms.downscaleNearest(i420, sw, sh);
      i420.release();

      I420Transforms.boxBlurI420(small, blurRadius);
      JavaI420Buffer upscaled = I420Transforms.upscaleNearest(small, w, h);
      small.release();

      return new VideoFrame(upscaled, input.getRotation(), input.getTimestampNs());
    }
  }

  /** Internal I420 helpers (separate from filter instance for clarity). */
  static final class I420Transforms {
    private I420Transforms() {}

    static VideoFrame.I420Buffer downscaleNearest(VideoFrame.I420Buffer src, int dstW, int dstH) {
      JavaI420Buffer dst = JavaI420Buffer.allocate(dstW, dstH);
      scalePlaneNearest(
          src.getDataY(), src.getStrideY(), src.getWidth(), src.getHeight(),
          dst.getDataY(), dst.getStrideY(), dstW, dstH);
      int srcChW = (src.getWidth() + 1) / 2;
      int srcChH = (src.getHeight() + 1) / 2;
      int dstChW = (dstW + 1) / 2;
      int dstChH = (dstH + 1) / 2;
      scalePlaneNearest(
          src.getDataU(), src.getStrideU(), srcChW, srcChH,
          dst.getDataU(), dst.getStrideU(), dstChW, dstChH);
      scalePlaneNearest(
          src.getDataV(), src.getStrideV(), srcChW, srcChH,
          dst.getDataV(), dst.getStrideV(), dstChW, dstChH);
      return dst;
    }

    static JavaI420Buffer upscaleNearest(VideoFrame.I420Buffer src, int dstW, int dstH) {
      JavaI420Buffer dst = JavaI420Buffer.allocate(dstW, dstH);
      scalePlaneNearest(
          src.getDataY(), src.getStrideY(), src.getWidth(), src.getHeight(),
          dst.getDataY(), dst.getStrideY(), dstW, dstH);
      int srcChW = (src.getWidth() + 1) / 2;
      int srcChH = (src.getHeight() + 1) / 2;
      int dstChW = (dstW + 1) / 2;
      int dstChH = (dstH + 1) / 2;
      scalePlaneNearest(
          src.getDataU(), src.getStrideU(), srcChW, srcChH,
          dst.getDataU(), dst.getStrideU(), dstChW, dstChH);
      scalePlaneNearest(
          src.getDataV(), src.getStrideV(), srcChW, srcChH,
          dst.getDataV(), dst.getStrideV(), dstChW, dstChH);
      return dst;
    }

    private static void scalePlaneNearest(
        ByteBuffer src, int srcStride, int srcW, int srcH,
        ByteBuffer dst, int dstStride, int dstW, int dstH) {
      for (int y = 0; y < dstH; y++) {
        int sy = (int) ((y + 0.5f) * srcH / dstH);
        if (sy >= srcH) {
          sy = srcH - 1;
        }
        for (int x = 0; x < dstW; x++) {
          int sx = (int) ((x + 0.5f) * srcW / dstW);
          if (sx >= srcW) {
            sx = srcW - 1;
          }
          byte v = src.get(sy * srcStride + sx);
          dst.put(y * dstStride + x, v);
        }
      }
    }

    static void boxBlurI420(VideoFrame.I420Buffer i420, int radius) {
      int w = i420.getWidth();
      int h = i420.getHeight();
      blurPlane(i420.getDataY(), i420.getStrideY(), w, h, radius);
      int cw = (w + 1) / 2;
      int ch = (h + 1) / 2;
      int cr = Math.max(1, radius / 2);
      blurPlane(i420.getDataU(), i420.getStrideU(), cw, ch, cr);
      blurPlane(i420.getDataV(), i420.getStrideV(), cw, ch, cr);
    }

    private static void blurPlane(ByteBuffer data, int stride, int width, int height, int radius) {
      int n = width * height;
      byte[] tmp = new byte[n];
      byte[] acc = new byte[n];
      // horizontal
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
            sum += data.get(y * stride + xx) & 0xff;
            count++;
          }
          tmp[y * width + x] = (byte) (sum / count);
        }
      }
      // vertical
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
            sum += tmp[yy * width + x] & 0xff;
            count++;
          }
          acc[y * width + x] = (byte) (sum / count);
        }
      }
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          data.put(y * stride + x, acc[y * width + x]);
        }
      }
    }
  }
}
