import CoreMedia
import Foundation

/// Pulls frames from a `VideoFrameSource` and feeds a
/// `PPEFrameQueue`. Runs on its own detached task at
/// `userInitiated` priority — high enough to keep up with 4K
/// ProRes at 23.976 fps on Apple Silicon, not so high that it
/// starves main-thread CoreAnimation commits (the mistake the
/// first MXF player made and that we reverted).
///
/// **Why a detached task + NSLock queue instead of an actor
/// pipeline.** Latency. Each decoded frame is hot-path data;
/// actor hops add microseconds of overhead per frame. The
/// decoder is simple enough that a single long-running task
/// with a lock-protected queue is cleaner than a chain of
/// awaits. Cancellation is still `Task.cancel()`.
///
/// **Throughput budget.** On M1 Pro, 4K ProRes HQ decode via
/// `AVAssetReader` runs at ~150-300 fps (hardware-accelerated).
/// Realtime playback at 23.976 fps uses < 20% of that budget,
/// so the queue stays full except during cold-start after a
/// seek. The 30-frame queue cap absorbs normal variation; if
/// the decoder really can't keep up (very high-bitrate 4444
/// XQ on older hardware), `frame(forPlaybackSeconds:)` will
/// return nil intermittently and the renderer will hold its
/// previous frame — smooth degradation, no crash.
public final class PPEBackgroundDecoder: @unchecked Sendable {

    /// Frame source being pulled from. Owned by this decoder;
    /// `tearDown()` releases it.
    private let source: VideoFrameSource

    /// Queue that the decoder writes into. Owned externally —
    /// typically by the `CustomVideoPlayer` controller in M4.
    private let queue: PPEFrameQueue

    /// Currently running decode task, if any.
    private var task: Task<Void, Never>?

    /// Serialize start/stop/seek so we don't race task creation.
    private let controlLock = NSLock()

    /// Closure the decoder polls to decide "am I far enough
    /// ahead of the playback target?". Returns the current
    /// video-local playback target in seconds, or nil when
    /// the target is unknown (pre-roll before first update).
    /// When set, the decoder sleeps while the newest buffered
    /// frame's PTS is ≥ `target + lookaheadSeconds`, rather
    /// than just when the queue is full. That gives the
    /// retention-ring queue room to keep decoding while
    /// evicting stale history, without over-producing frames
    /// faster than wall-clock can consume them.
    public var targetProvider: (@Sendable () -> Double?)?

    /// How many seconds of frames we keep buffered ahead of the
    /// playback target. 1.0 s at 24 fps = 24 frames of lookahead,
    /// which smooths over brief decoder stalls without
    /// over-committing memory.
    public var lookaheadSeconds: Double = 1.0

    public init(source: VideoFrameSource, queue: PPEFrameQueue) {
        self.source = source
        self.queue = queue
    }

    /// Begin (or resume) decoding. Safe to call multiple times;
    /// subsequent calls are no-ops while a task is running.
    public func start() {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard task == nil else { return }
        let src = source
        let q = queue
        let tp = targetProvider
        let la = lookaheadSeconds
        task = Task.detached(priority: .userInitiated) {
            await Self.runDecodeLoop(
                source: src,
                queue: q,
                targetProvider: tp,
                lookaheadSeconds: la
            )
        }
    }

    /// Cancel decoding. The in-flight `nextFrame()` call will
    /// return at its next checkpoint; the task exits cleanly.
    public func stop() async {
        controlLock.lock()
        let t = task
        task = nil
        controlLock.unlock()
        t?.cancel()
        await t?.value
    }

    /// Flush + seek + restart. Used when the playhead jumps
    /// (scrub) so the queue doesn't deliver frames for the old
    /// position. The new frames start flowing from `time`
    /// onward.
    public func seek(toSeconds time: Double) async throws {
        await stop()
        queue.flush()
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        try await source.seek(to: cmTime)
        start()
    }

    /// Release the source. Safe to call without calling stop()
    /// first — tears the task down too.
    public func tearDown() async {
        await stop()
        source.tearDown()
    }

    // MARK: - Internal

    /// The actual decode loop. Static so we don't capture self
    /// in the detached task — avoids an obvious retain cycle
    /// (task holds self holds task).
    private static func runDecodeLoop(
        source: VideoFrameSource,
        queue: PPEFrameQueue,
        targetProvider: (@Sendable () -> Double?)?,
        lookaheadSeconds: Double
    ) async {
        while !Task.isCancelled {
            // **Target-aware backpressure.** With the retention-
            // ring queue (M5.1), `frame(forPlaybackSeconds:)`
            // doesn't drop frames on lookup, so a full queue
            // no longer naturally drains as playback advances.
            // Instead we sleep when we've already decoded
            // enough frames ahead of the current playback
            // target. The queue's drop-oldest-on-enqueue
            // behavior handles history trim.
            if let provider = targetProvider,
               let target = provider(),
               let range = queue.bufferedRangeSeconds(),
               range.last >= target + lookaheadSeconds {
                try? await Task.sleep(nanoseconds: 8_000_000)
                continue
            }
            // Fallback when no target is available yet (pre-
            // roll before first sync tick): fill once, then
            // wait until the target wires up. This prevents
            // an infinite decode loop chewing through the
            // whole file before playback starts.
            if targetProvider == nil,
               queue.stats().depth >= queue.capacity {
                try? await Task.sleep(nanoseconds: 16_000_000)
                continue
            }
            do {
                guard let frame = try await source.nextFrame() else {
                    // EOF — source exhausted. Mark the queue
                    // so the consumer doesn't wait forever.
                    queue.markEOF()
                    return
                }
                // Push into the queue. If it won some race and
                // filled between our check and the append, try
                // again after a short sleep.
                var accepted = queue.tryEnqueue(frame)
                while !accepted && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000)
                    accepted = queue.tryEnqueue(frame)
                }
            } catch is CancellationError {
                return
            } catch {
                print("[PPE decoder] \(error.localizedDescription) — halting")
                queue.markEOF()
                return
            }
        }
    }
}
