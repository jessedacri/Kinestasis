import CoreMedia
import Foundation

/// Thread-safe ring buffer of decoded frames. Producer
/// (`PPEBackgroundDecoder`) enqueues as fast as the decoder
/// delivers, capped by `capacity`. Consumer (the display driver)
/// calls `frame(forPlaybackSeconds:)` on each display refresh
/// and receives the latest frame whose PTS is ≤ the requested
/// time — any frames older than that are dropped (standard NLE
/// behavior: skip rather than stretch).
///
/// **Why an NSLock-protected struct and not an `actor`**.
/// The display driver queries the queue from a `CADisplayLink`
/// callback which runs at screen refresh rate — on a 120 Hz
/// ProMotion display that's one call per 8.3 ms, budget
/// ~2 ms max per-frame work before we miss v-sync. Actor-hop
/// latency is measured in hundreds of microseconds on Apple
/// Silicon, and stacks up when multiple queries happen in
/// sequence during multi-cam preview. A lock-protected struct
/// keeps the critical section in microseconds and deterministic.
public final class PPEFrameQueue: @unchecked Sendable {
    /// Maximum number of frames we hold at once. Larger = more
    /// decode-ahead, more memory. 4K ProRes at ~13 MB/frame ×
    /// 30 frames ≈ 390 MB — bounded but healthy. Small enough
    /// that we don't starve the decoder or balloon RAM, large
    /// enough to absorb normal decoder throughput variation.
    public let capacity: Int

    private let lock = NSLock()
    private var frames: [PPEDecodedFrame] = []
    /// Producer bumps this counter every time it enqueues.
    /// Consumer uses it for cheap "did anything new arrive?"
    /// polling without locking to inspect the array.
    private var enqueueCount: UInt64 = 0
    /// Producer sets true when the source returned nil (EOF)
    /// so `frame(forPlaybackSeconds:)` can stop expecting
    /// more data to arrive for out-of-range requests.
    private var reachedEOF: Bool = false

    public init(capacity: Int = 30) {
        self.capacity = capacity
    }

    /// Enqueue a frame. Returns `true` if accepted, `false` if
    /// the queue is full — caller (the background decoder) then
    /// yields briefly and retries. We deliberately don't block
    /// here so the decoder task can be cancelled cleanly while
    /// backpressured.
    /// Enqueue a new frame. The queue acts as a retention ring:
    /// when full, the oldest frame is evicted to make room for
    /// the new one. Lookup (`frame(forPlaybackSeconds:)`) does
    /// NOT drop frames, so the queue holds the most recent
    /// `capacity` decoded frames. This matters for reverse
    /// playback + scrub-backward: the playhead moves through
    /// frames the queue has already seen, so having them still
    /// available lets us serve reverse ticks without re-
    /// seeking the decoder on every single tick.
    @discardableResult
    public func tryEnqueue(_ frame: PPEDecodedFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if frames.count >= capacity {
            frames.removeFirst()
        }
        frames.append(frame)
        enqueueCount &+= 1
        return true
    }

    /// Mark the stream as exhausted. Called by the decoder when
    /// the source returns nil from `nextFrame()`. The queue
    /// still serves the remaining buffered frames; EOF is a
    /// hint that no more are coming.
    public func markEOF() {
        lock.lock()
        reachedEOF = true
        lock.unlock()
    }

    /// Drop every queued frame and clear the EOF latch.
    /// Called on seek — the buffered frames are for the OLD
    /// position and are no longer relevant.
    public func flush() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        reachedEOF = false
        lock.unlock()
    }

    /// Pick the best frame to display for a given playback
    /// position. Non-destructive: does NOT drop older frames —
    /// that's handled by `tryEnqueue` evicting the oldest when
    /// capacity is hit. Reverse playback + scrub-backward both
    /// need older frames to stay available for lookup.
    ///
    /// Semantics:
    /// - Returns the latest frame whose PTS ≤ playbackSeconds.
    /// - If no such frame exists (queue empty, or oldest frame
    ///   is ahead of the request), returns nil. Caller renders
    ///   nothing this tick or keeps the previous frame visible.
    ///
    /// This matches NLE playback: if the decoder lags, the
    /// display "holds" the last-presented frame rather than
    /// drifting forward without content.
    public func frame(forPlaybackSeconds target: Double) -> PPEDecodedFrame? {
        lock.lock()
        defer { lock.unlock() }
        var best: PPEDecodedFrame?
        for f in frames {
            if CMTimeGetSeconds(f.pts) <= target {
                best = f
            } else {
                break
            }
        }
        return best
    }

    /// Range of PTS covered by the currently-buffered frames,
    /// in seconds. Nil when the queue is empty. Used by the
    /// scrub logic to decide "do I need to seek, or is the
    /// target already in-buffer?" — avoids a decoder seek per
    /// tick during reverse playback.
    public func bufferedRangeSeconds() -> (first: Double, last: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = frames.first, let last = frames.last else { return nil }
        return (CMTimeGetSeconds(first.pts), CMTimeGetSeconds(last.pts))
    }

    /// Snapshot of queue depth + EOF state. Cheap; used by the
    /// decoder to know whether to sleep and by the UI for
    /// diagnostics.
    public struct Stats: Sendable {
        public let depth: Int
        public let capacity: Int
        public let reachedEOF: Bool
        public let totalEnqueued: UInt64

        public init(depth: Int, capacity: Int, reachedEOF: Bool, totalEnqueued: UInt64) {
            self.depth = depth
            self.capacity = capacity
            self.reachedEOF = reachedEOF
            self.totalEnqueued = totalEnqueued
        }
    }

    public func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return Stats(
            depth: frames.count,
            capacity: capacity,
            reachedEOF: reachedEOF,
            totalEnqueued: enqueueCount
        )
    }
}
