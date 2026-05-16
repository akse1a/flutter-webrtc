package com.cloudwebrtc.webrtc.video;

import androidx.annotation.Nullable;

import com.cloudwebrtc.webrtc.LocalTrack;

import org.webrtc.VideoFrame;
import org.webrtc.VideoProcessor;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

import java.util.ArrayList;
import java.util.List;

public class LocalVideoTrack extends LocalTrack implements VideoProcessor {
    private final OutgoingVideoFiltersController outgoingVideoFilters = new OutgoingVideoFiltersController();

    public interface ExternalVideoFrameProcessing {
        /**
         * Process a video frame.
         * @param frame
         * @return The processed video frame.
         */
        public abstract VideoFrame onFrame(VideoFrame frame);
    }

    public LocalVideoTrack(VideoTrack videoTrack) {
        super(videoTrack);
    }

    List<ExternalVideoFrameProcessing> processors = new ArrayList<>();

    public void addProcessor(ExternalVideoFrameProcessing processor) {
        synchronized (processors) {
            processors.add(processor);
        }
    }

    public void removeProcessor(ExternalVideoFrameProcessing processor) {
        synchronized (processors) {
            processors.remove(processor);
        }
    }

    public OutgoingVideoFiltersController getOutgoingVideoFilters() {
        return outgoingVideoFilters;
    }

    public void releaseOutgoingVideoFilters() {
        outgoingVideoFilters.clear();
    }

    private VideoSink sink = null;

    @Override
    public void setSink(@Nullable VideoSink videoSink) {
        sink = videoSink;
    }

    @Override
    public void onCapturerStarted(boolean b) {}

    @Override
    public void onCapturerStopped() {}

    @Override
    public void onFrameCaptured(VideoFrame videoFrame) {
        if (sink != null) {
            VideoFrame in = videoFrame;
            VideoFrame out = outgoingVideoFilters.apply(in);
            synchronized (processors) {
                for (ExternalVideoFrameProcessing processor : processors) {
                    VideoFrame next = processor.onFrame(out);
                    if (next != out) {
                        if (out != in) {
                            out.release();
                        }
                        out = next;
                    }
                }
            }
            if (out != in) {
                in.release();
            }
            sink.onFrame(out);
        }
    }
}