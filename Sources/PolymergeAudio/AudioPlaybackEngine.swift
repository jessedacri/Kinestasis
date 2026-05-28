import AVFoundation
import Foundation

/// Per-file metering state. Updated by the audio render thread, read by the
/// UI display timer.
public final class TrackMeter: @unchecked Sendable {
    /// Linear peak [0..1] from most recent buffer
    public var rawPeak: Float = 0
    /// Linear RMS [0..1]
    public var rawRMS: Float = 0

    /// Display values (smoothed/decayed) — written by display timer on main thread
    public var displayPeak: Float = 0
    public var displayRMS: Float = 0
    public var peakHold: Float = 0
    public var peakHoldTimestamp: CFTimeInterval = 0

    /// Per-channel peaks (max channel count = 2 for now)
    public var channelPeaks: [Float] = [0, 0]
    public var channelDisplayPeaks: [Float] = [0, 0]

    public init() {}
}

/// Transport interface the audio playback engine drives during playback.
///
/// Owned by the executable target (see `TransportState`); the engine
/// reads/writes a few fields and calls `stop()`. Extracted as a protocol
/// here so the engine can live in `PolymergeAudio` without taking a
/// dependency on the executable's session-state types.
public protocol EnginePlaybackTransport: AnyObject {
    /// Current playhead position in output-rate samples.
    var playheadSample: Int64 { get set }
    /// Timeline length in samples. The engine wraps to 0 if the playhead
    /// is at or past the end.
    var totalSamples: UInt64 { get }
    /// Shuttle speed: 0 = stopped, 1 = 1× forward, -1 = 1× reverse, 2 = 2×,
    /// etc. The engine plays audio only when `abs(shuttleSpeed) == 1`.
    var shuttleSpeed: Double { get }
    /// True while the transport is in any playback mode (including shuttle).
    var isPlaying: Bool { get }
    /// Stop playback. Called by the engine when the timeline reaches the end.
    func stop()
}

/// Real-time multi-track mixing engine using `AVAudioSourceNode`.
///
/// **Architecture (Path B — DAW-style)**
///
/// PolyMerge's primary use case is verifying that a merge will be correctly
/// aligned. Playback must match the merge bit-for-bit, AND it must respond
/// instantly to mute / solo / bypass / HPF changes (no 1-2 second re-mix
/// pause). Apps like Logic, DaVinci, Premiere, and GarageBand achieve both
/// by mixing audio in a custom render callback that runs on the audio thread,
/// reading per-track buffers held in RAM and per-track flags that the UI
/// updates atomically.
///
/// This engine does the same:
/// - Each track is a `TrackBuffer` with raw + processed channel data
///   (`UnsafeMutablePointer<Float>`) loaded into RAM up front.
/// - The render callback iterates the current `TrackBuffer` array, reads
///   each track's mute / solo / panning / channel data, and sums into the
///   stereo output.
/// - Mute / solo / bypass updates write a single field (atomic on aligned
///   memory) — the next render block picks up the change instantly.
/// - HPF / phase / spectral changes rebuild the affected `TrackBuffer` in
///   the background, then atomically swap it into the engine's tracks list.
///   The old buffer is held briefly via the `staleTracks` list so any
///   in-flight render call can finish without reading freed memory.
///
/// The render block reads class fields via captured `self` (weak); it does
/// not allocate, take Swift locks, or call ObjC methods on the hot path.
///
/// **CRITICAL**: this class must NOT be `@Observable`. The Swift Observation
/// framework instruments every property read with a tracking call into the
/// observation system, which is both slow and unsafe to call from a real-time
/// audio thread. (Symptom of getting this wrong: 1000%+ CPU usage and audio
/// glitches.) UI-visible state is exposed via the `Observed` nested class
/// instead.
public final class AudioPlaybackEngine {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var displayLink: DisplayLinkTimer?

    /// SwiftUI-observable mirror of the engine's UI-visible state. Views that
    /// need to react to engine changes (level meter ticks, isRunning) observe
    /// this child object instead of the engine directly. Hot-path fields stay
    /// off the observation system entirely.
    @Observable
    public final class Observed {
        public var isEngineRunning: Bool = false
        public var meterTick: Int = 0
        /// Per-file meter state, mapped by file UUID. The display timer
        /// updates these on the main thread; the audio thread writes raw
        /// peaks into TrackBuffer fields directly.
        public var meters: [UUID: TrackMeter] = [:]

        public init() {}
    }
    public let observed = Observed()

    /// Pass-through for legacy view code that reads `engine.meterTick`,
    /// `engine.meters`, etc. directly.
    public var meterTick: Int { observed.meterTick }
    public var meters: [UUID: TrackMeter] { observed.meters }
    public var isEngineRunning: Bool { observed.isEngineRunning }

    public init() {}

    /// Per-track buffers wrapped in an immutable snapshot class. The render
    /// block reads `tracksSnapshot` once per call — Swift class reference
    /// assignment to a single field is atomic on aligned memory, so the
    /// audio thread always sees a coherent (possibly slightly stale) array.
    /// Mutations happen on the main thread by building a new snapshot.
    private var tracksSnapshot: TracksSnapshot = TracksSnapshot(tracks: [])
    private var nextSnapshotGeneration: Int = 1
    /// Old snapshots held briefly after a swap so any in-flight render call
    /// can finish reading the previous TrackBuffers. Cleared after a few
    /// render cycles.
    private var staleSnapshots: [TracksSnapshot] = []
    private let tracksLock = NSLock()

    /// Convenience accessor for the current tracks (main thread only).
    private var tracks: [TrackBuffer] {
        tracksSnapshot.tracks
    }

    /// Master sample rate of the timeline. Public read so callers
    /// can detect whether `replaceTracks` is safe (same SR as the
    /// running graph) vs needing a full `prepare` rebuild.
    public private(set) var sampleRate: Double = 48000
    /// Total length of the timeline in samples
    private var totalFrames: Int64 = 0

    /// Atomic-ish render state — read by the render block on every call.
    /// Aligned 64-bit / 8-bit / Bool reads are atomic on Apple hardware.
    private var playheadFrames: Int64 = 0
    private var playing: Bool = false

    /// Audio output pipeline latency in seconds. `AVAudioEngine`
    /// reports this via `outputNode.presentationLatency` once the
    /// engine has started — it's the total delay between when the
    /// render callback writes a sample and when that sample is
    /// actually converted to analog at the user's speakers/DAC.
    /// Typical values: 10-40 ms depending on buffer size + driver.
    ///
    /// **Why the PPE needs this.** `playheadFrames` tracks where
    /// we've WRITTEN audio to the engine, but the audible output
    /// at this instant is `playheadFrames - outputLatencyFrames`.
    /// Syncing video to `playheadFrames` directly puts video
    /// ahead of the audio the user is hearing — the constant
    /// lip-sync offset the user reports. `currentAudibleSeconds`
    /// subtracts this latency so video presentation matches what's
    /// actually coming out of the speakers.
    public private(set) var outputLatencySeconds: Double = 0
    private var bypassPhaseAlign: Bool = false
    /// Master output gain in linear units (1.0 = unity). Driven by the
    /// loudness normalization preview so the user can hear the active
    /// target while scrubbing. Reset to 1.0 when normalization is off
    /// or no measurement exists. Updated under `tracksLock` so the
    /// audio thread sees the new value on its next render call.
    private var outputGain: Float = 1.0

    private var meterTimer: Timer?
    private let metersLock = NSLock()

    // MARK: - Setup

    /// Prepare the engine to play a fresh set of TrackBuffers. Called by
    /// the session layer after building the per-track audio data.
    ///
    /// `bypassPhaseAlign` mirrors the active bin's phase-align bypass flag
    /// (formerly read from `MergeSession.phaseAlignBypassed`); the caller
    /// passes the current value so the engine doesn't need a reference to
    /// the session type. `initialPlayheadSample` is where playback should
    /// resume from (formerly `session.transport.playheadSample`).
    public func prepare(
        tracks: [TrackBuffer],
        totalFrames: Int64,
        sampleRate: Double,
        bypassPhaseAlign: Bool,
        initialPlayheadSample: Int64
    ) {
        teardown()

        let distinctProcessed = tracks.reduce(into: 0) { acc, t in
            if !t.rawChannels.isEmpty && !t.processedChannels.isEmpty,
               t.rawChannels[0] != t.processedChannels[0] {
                acc += 1
            }
        }
        print("[ALIGN-DIAG] engine.prepare tracks=\(tracks.count) distinctProcessed=\(distinctProcessed) usedCorrected(any)=\(tracks.contains { $0.usedCorrectedSource })")

        self.sampleRate = sampleRate
        self.totalFrames = totalFrames
        let gen = nextSnapshotGeneration
        nextSnapshotGeneration += 1
        self.tracksSnapshot = TracksSnapshot(tracks: tracks, generation: gen)
        self.bypassPhaseAlign = bypassPhaseAlign
        // Sync the engine playhead with the transport's current position
        self.playheadFrames = initialPlayheadSample

        // Reset meters
        metersLock.lock()
        observed.meters.removeAll()
        for track in tracks {
            observed.meters[track.id] = TrackMeter()
        }
        metersLock.unlock()

        // Build the AVAudioEngine + AVAudioSourceNode chain
        let engine = AVAudioEngine()
        self.engine = engine

        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            print("AudioPlaybackEngine: failed to build stereo format")
            return
        }

        let sourceNode = AVAudioSourceNode(format: outputFormat) { [weak self] isSilence, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else {
                isSilence.pointee = true
                return noErr
            }
            self.render(
                frameCount: Int(frameCount),
                audioBufferList: audioBufferList,
                isSilence: isSilence
            )
            return noErr
        }
        self.sourceNode = sourceNode

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: outputFormat)

        do {
            try engine.start()
            observed.isEngineRunning = true
            // Capture the output pipeline latency AFTER start — the
            // engine's `presentationLatency` isn't finalized until
            // the graph is running against the actual output device.
            // This feeds `currentAudibleSeconds()` so the PPE (and
            // future frame-accurate video sync) can present video
            // aligned with what's audibly playing, not where the
            // render callback last wrote.
            outputLatencySeconds = engine.outputNode.presentationLatency
            print(String(format: "[AudioPlayback] output latency = %.1f ms",
                         outputLatencySeconds * 1000))
            startMeterTimer()
        } catch {
            print("AudioPlaybackEngine: failed to start engine: \(error)")
            observed.isEngineRunning = false
        }
    }

    /// Wall-clock-accurate "what audio sample is audible right now"
    /// readout. Thread-safe: `playheadFrames` is a 64-bit aligned
    /// read which is atomic on Apple hardware, and
    /// `outputLatencySeconds` + `sampleRate` are written only
    /// during start/prepare. Called from the video playback
    /// thread to drive frame selection.
    ///
    /// Returns the position in **timeline samples** of the audio
    /// sample that's hitting the speakers *right now*, accounting
    /// for the engine's render-to-output pipeline delay. When
    /// `playing` is false, returns the engine's last written
    /// position (no latency subtraction — silence is silence).
    public func currentAudibleSeconds() -> Double {
        let sr = sampleRate
        guard sr > 0 else { return 0 }
        let frames = playheadFrames
        let engineSeconds = Double(frames) / sr
        guard playing else { return engineSeconds }
        return max(0, engineSeconds - outputLatencySeconds)
    }

    // MARK: - Render Callback

    /// Audio render callback. Called on the AVAudioEngine real-time thread.
    /// Sums all tracks into the stereo output buffers, respecting mute / solo
    /// / bypass flags, and advances the playhead.
    private func render(
        frameCount: Int,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        isSilence: UnsafeMutablePointer<ObjCBool>
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard abl.count >= 2 else {
            isSilence.pointee = true
            return
        }
        let leftPtr = abl[0].mData!.assumingMemoryBound(to: Float.self)
        let rightPtr = abl[1].mData!.assumingMemoryBound(to: Float.self)

        // Zero output first
        for i in 0..<frameCount {
            leftPtr[i] = 0
            rightPtr[i] = 0
        }

        // Capture ALL engine state under one lock acquire. NSLock provides
        // full memory-barrier semantics — without this lock, the audio
        // thread can read stale (cached) values for `playing`, `bypass`,
        // `tracksSnapshot`, AND for fields on the TrackBuffer instances
        // inside the snapshot (e.g. `muted`, `soloed`). All main-thread
        // mutators must also take this lock so writes are properly visible.
        tracksLock.lock()
        let snapshot = self.tracksSnapshot
        let isPlayingNow = self.playing
        let bypass = self.bypassPhaseAlign
        let total = self.totalFrames
        let startFrame = self.playheadFrames
        let masterGain = self.outputGain
        tracksLock.unlock()

        if !isPlayingNow {
            isSilence.pointee = true
            return
        }

        // Reached end?
        if startFrame >= total {
            isSilence.pointee = true
            self.tracksLock.lock()
            self.playing = false
            self.tracksLock.unlock()
            return
        }

        let trackSnapshot = snapshot.tracks

        // Determine soloed state once per render block. A track is
        // "any-soloed" if EITHER its file-level `soloed` flag is set
        // OR any of its per-channel solo bytes is set. We walk the
        // per-channel array byte-by-byte rather than building a
        // Swift Set / Array per render call (allocation in the
        // audio thread is forbidden — it can call into malloc and
        // produce buffer underruns).
        var anySoloed = false
        for t in trackSnapshot {
            if t.soloed { anySoloed = true; break }
            for ch in 0..<t.channelCount {
                if t.soloedChannels[ch] { anySoloed = true; break }
            }
            if anySoloed { break }
        }

        // Mix each track
        for track in trackSnapshot {
            // Whole-file mute trumps everything else for this track.
            // A whole-file mute with no per-channel overrides means
            // skip the entire track. (We don't currently support
            // "mute the file but solo one channel" — the per-channel
            // mute/solo gates are *additive* to the file-level
            // gates, not exceptions.)
            if track.muted { continue }

            // In solo mode, this track contributes ANYTHING only if
            // it has at least one soloed source: file-level
            // `soloed` OR at least one per-channel solo byte set.
            // If neither holds, every channel of this track is
            // silenced — skip the whole track to avoid the channel
            // loop entirely.
            if anySoloed {
                var trackHasAnySolo = track.soloed
                if !trackHasAnySolo {
                    for ch in 0..<track.channelCount {
                        if track.soloedChannels[ch] { trackHasAnySolo = true; break }
                    }
                }
                if !trackHasAnySolo { continue }
            }

            let trackOffset = track.fileOffsetSamples
            let trackLen = Int64(track.length)
            let chCount = track.channelCount
            let panL = track.panLeft

            // Phase delay only applies in normal mode and when not using a
            // pre-corrected source buffer
            let phaseDelay: Int64
            if bypass {
                phaseDelay = 0
            } else if track.usedCorrectedSource {
                phaseDelay = 0
            } else {
                phaseDelay = Int64(track.phaseDelayInt)
            }

            // Pick the source buffers based on bypass mode
            let channels = bypass ? track.rawChannels : track.processedChannels

            // Live per-track gain trim. Multiplied into every sample
            // before it lands in the output. Stored on TrackBuffer so
            // the main thread can change it without rebuilding the
            // buffer (instant slider/knob response).
            let gain = track.gainScalar

            // Per-track meter accumulators
            var trackPeak: Float = 0
            var trackCh0Peak: Float = 0
            var trackCh1Peak: Float = 0

            // Mix into output. Inner loop is hot — keep simple for inlining.
            // outBaseSrc maps output frame 0 to its source sample. Then for
            // output frame i, the source sample is (outBaseSrc + i). We clamp
            // i to the range where (outBaseSrc + i) is in [0, trackLen).
            let outBaseSrc = startFrame - trackOffset + phaseDelay
            let validStart = max(0, -outBaseSrc)
            let validEnd = min(Int64(frameCount), trackLen - outBaseSrc)
            if validEnd <= validStart { continue }

            let vStart = Int(validStart)
            let vEnd = Int(validEnd)
            let outBaseInt = Int(outBaseSrc)

            // Per-channel mute / solo gates. We resolve them ONCE
            // per track (not per sample) so the hot mix loop is
            // branch-free per-channel. A channel "plays" when:
            //   - It's not per-channel-muted, AND
            //   - We're not in solo mode, OR the file/channel is
            //     soloed.
            //
            // We compute chPlays0 / chPlays1 directly (mono + stereo
            // covers ~all files) and check chCount > 2 entries
            // inline in the channels-3+ loop below. This keeps the
            // audio thread allocation-free.
            @inline(__always) func chPlays(_ ch: Int) -> Bool {
                if track.mutedChannels[ch] { return false }
                if anySoloed && !(track.soloed || track.soloedChannels[ch]) { return false }
                return true
            }
            let chPlays0 = chPlays(0)
            let chPlays1 = chCount > 1 ? chPlays(1) : false

            // Per-channel peak pointer for ALL source channels
            let chPeaks = track.meterChannelPeaks

            if chCount == 1 {
                guard chPlays0 else { continue }
                let ch0 = channels[0]
                for i in vStart..<vEnd {
                    let s = ch0[outBaseInt + i] * gain
                    let v = s * panL  // panL == panR for mono (0.7071)
                    leftPtr[i] += v
                    rightPtr[i] += v
                    let abs_s = s < 0 ? -s : s
                    if abs_s > trackPeak { trackPeak = abs_s }
                    if abs_s > trackCh0Peak { trackCh0Peak = abs_s }
                    if abs_s > chPeaks[0] { chPeaks[0] = abs_s }
                }
            } else {
                let ch0 = channels[0]
                let ch1 = channels[1]
                if chPlays0 && chPlays1 {
                    for i in vStart..<vEnd {
                        let s0 = ch0[outBaseInt + i] * gain
                        let s1 = ch1[outBaseInt + i] * gain
                        leftPtr[i] += s0
                        rightPtr[i] += s1
                        let abs0 = s0 < 0 ? -s0 : s0
                        let abs1 = s1 < 0 ? -s1 : s1
                        if abs0 > trackPeak { trackPeak = abs0 }
                        if abs1 > trackPeak { trackPeak = abs1 }
                        if abs0 > trackCh0Peak { trackCh0Peak = abs0 }
                        if abs1 > trackCh1Peak { trackCh1Peak = abs1 }
                        if abs0 > chPeaks[0] { chPeaks[0] = abs0 }
                        if abs1 > chPeaks[1] { chPeaks[1] = abs1 }
                    }
                } else if chPlays0 {
                    for i in vStart..<vEnd {
                        let s0 = ch0[outBaseInt + i] * gain
                        leftPtr[i] += s0
                        let abs0 = s0 < 0 ? -s0 : s0
                        if abs0 > trackPeak { trackPeak = abs0 }
                        if abs0 > trackCh0Peak { trackCh0Peak = abs0 }
                        if abs0 > chPeaks[0] { chPeaks[0] = abs0 }
                    }
                } else if chPlays1 {
                    for i in vStart..<vEnd {
                        let s1 = ch1[outBaseInt + i] * gain
                        rightPtr[i] += s1
                        let abs1 = s1 < 0 ? -s1 : s1
                        if abs1 > trackPeak { trackPeak = abs1 }
                        if abs1 > trackCh1Peak { trackCh1Peak = abs1 }
                        if abs1 > chPeaks[1] { chPeaks[1] = abs1 }
                    }
                }
                // Channels 3+: sum into both L and R, attenuated. Now
                // also tracks per-source-channel peaks so every lane
                // in the timeline gets its own independent meter.
                if chCount > 2 {
                    for ch in 2..<chCount where chPlays(ch) {
                        let chPtr = channels[ch]
                        for i in vStart..<vEnd {
                            let s = chPtr[outBaseInt + i] * gain * 0.5
                            leftPtr[i] += s
                            rightPtr[i] += s
                            let abs_s = s < 0 ? -s : s
                            if abs_s > chPeaks[ch] { chPeaks[ch] = abs_s }
                            if abs_s > trackPeak { trackPeak = abs_s }
                        }
                    }
                }
            }

            // Update per-track meter — plain Float writes are atomic on
            // aligned memory. (Do NOT use a Swift Array here — concurrent
            // CoW races crash the process.)
            if trackPeak > track.meterPeak { track.meterPeak = trackPeak }
            if trackCh0Peak > track.meterCh0Peak { track.meterCh0Peak = trackCh0Peak }
            if trackCh1Peak > track.meterCh1Peak { track.meterCh1Peak = trackCh1Peak }
        }

        // Apply the loudness normalization preview gain to the final
        // mix. When normalization is off this is 1.0 and the multiply
        // is a no-op (still cheaper than a branch + skip).
        if masterGain != 1.0 {
            for i in 0..<frameCount {
                leftPtr[i] *= masterGain
                rightPtr[i] *= masterGain
            }
        }

        // Advance the playhead (under lock so the next render & main-thread
        // reads see the new value). NB: this lock acquire MUST have a
        // matching unlock — we hit a hard deadlock the first time around
        // when the unlock was missing.
        let newPlayhead = startFrame + Int64(frameCount)
        self.tracksLock.lock()
        if newPlayhead >= total {
            self.playheadFrames = total
            self.playing = false
        } else {
            self.playheadFrames = newPlayhead
        }
        self.tracksLock.unlock()
    }

    // MARK: - Transport

    /// Start playback at the current playhead. Sample-accurate at 1× speed.
    /// Reverse and >1× speeds are visual-only (the audio stays silent).
    public func play(transport: EnginePlaybackTransport) {
        guard isEngineRunning else { return }

        // Wrap to start if at end
        if transport.playheadSample >= Int64(transport.totalSamples) - 1 {
            transport.playheadSample = 0
        }

        let speed = transport.shuttleSpeed
        guard speed != 0 else { return }

        tracksLock.lock()
        self.playheadFrames = transport.playheadSample
        // Reverse and fast-forward are visual-only
        if speed < 0 || abs(speed) > 1 {
            self.playing = false
        } else {
            self.playing = true
        }
        tracksLock.unlock()
        startDisplayLink(transport: transport, originSeconds: CACurrentMediaTime())
    }

    public func stop() {
        tracksLock.lock()
        self.playing = false
        tracksLock.unlock()
        stopDisplayLink()
    }

    public func teardown() {
        stopMeterTimer()
        stop()
        if let sourceNode {
            sourceNode.removeTap(onBus: 0)
        }
        if let engine {
            engine.stop()
            if let sourceNode {
                engine.detach(sourceNode)
            }
        }
        metersLock.lock()
        observed.meters.removeAll()
        metersLock.unlock()
        engine = nil
        sourceNode = nil
        tracksSnapshot = TracksSnapshot(tracks: [])
        staleSnapshots = []
        observed.isEngineRunning = false
        playheadFrames = 0
        outputGain = 1.0
    }

    // MARK: - Live Updates

    /// Toggle the bypass flag. Instant — no rebuild.
    /// Takes the engine lock so the audio thread sees the write on its
    /// next render call (without it, cached field reads can ignore the
    /// change indefinitely on Apple Silicon's weakly-ordered memory model).
    public func setBypass(_ bypassed: Bool) {
        tracksLock.lock()
        self.bypassPhaseAlign = bypassed
        tracksLock.unlock()
    }

    /// Set the master output gain in linear units (1.0 = unity). Driven
    /// by the loudness normalization preview. Instant — the audio thread
    /// picks up the new value on its next render call.
    public func setOutputGain(_ linear: Float) {
        tracksLock.lock()
        self.outputGain = linear
        tracksLock.unlock()
    }

    /// Update mute on a specific track. Instant — no rebuild.
    public func setMute(fileID: UUID, muted: Bool) {
        tracksLock.lock()
        if let track = tracksSnapshot.tracks.first(where: { $0.id == fileID }) {
            track.muted = muted
        }
        tracksLock.unlock()
    }

    /// Update solo on a specific track. Instant — no rebuild.
    public func setSolo(fileID: UUID, soloed: Bool) {
        tracksLock.lock()
        if let track = tracksSnapshot.tracks.first(where: { $0.id == fileID }) {
            track.soloed = soloed
        }
        tracksLock.unlock()
    }

    /// Update mute on a SPECIFIC channel of a specific track.
    /// Multi-track poly recorder files (Sound Devices 6-channel
    /// polys, Zoom F8 iso recordings) carry several mics in one
    /// file; this lets the user mute the boom WITHOUT silencing
    /// the lavs that share the file. Instant — flips a single
    /// byte in the engine's per-channel mute array under
    /// `tracksLock` so the audio thread sees it on the next
    /// render call.
    public func setChannelMute(fileID: UUID, channel: Int, muted: Bool) {
        tracksLock.lock()
        if let track = tracksSnapshot.tracks.first(where: { $0.id == fileID }),
           channel >= 0 && channel < track.channelCount {
            track.mutedChannels[channel] = muted
        }
        tracksLock.unlock()
    }

    /// Update solo on a specific channel of a specific track.
    /// Same model as `setChannelMute` — flips a single byte under
    /// the engine lock; instant. When ANY channel anywhere in the
    /// session is soloed, the engine enters solo mode and only
    /// soloed sources contribute to the output.
    public func setChannelSolo(fileID: UUID, channel: Int, soloed: Bool) {
        tracksLock.lock()
        if let track = tracksSnapshot.tracks.first(where: { $0.id == fileID }),
           channel >= 0 && channel < track.channelCount {
            track.soloedChannels[channel] = soloed
        }
        tracksLock.unlock()
    }

    /// Update gain trim on a specific track as a linear scalar.
    /// Instant — no rebuild. The render block reads `gainScalar`
    /// under the same `tracksLock` so the change becomes audible
    /// on the next audio buffer (typically 5-10 ms).
    public func setGain(fileID: UUID, scalar: Float) {
        tracksLock.lock()
        if let track = tracksSnapshot.tracks.first(where: { $0.id == fileID }) {
            track.gainScalar = scalar
        }
        tracksLock.unlock()
    }

    /// Read the latest live meter peak for a specific file's channel.
    /// Returns linear amplitude in [0, 1]. Used by the loudness
    /// window's per-channel mix VU rows to animate the bar fill in
    /// time with playback. Channel 0 reads `meterCh0Peak`, channel 1
    /// reads `meterCh1Peak`, channels 2+ fall back to the file's
    /// combined `meterPeak` (no per-channel slot exists yet for
    /// >2-channel files; that's a follow-up).
    public func meterValue(forFileID fileID: UUID, channel: Int) -> Float {
        tracksLock.lock()
        defer { tracksLock.unlock() }
        guard let track = tracksSnapshot.tracks.first(where: { $0.id == fileID }) else {
            return 0
        }
        switch channel {
        case 0:  return track.meterCh0Peak
        case 1:  return track.meterCh1Peak
        default: return track.meterPeak
        }
    }

    /// Atomically replace one track's buffer (e.g., after HPF or phase rebuild).
    /// The old snapshot is held in `staleSnapshots` for a brief grace period
    /// so any in-flight render call can finish reading its pointers safely.
    public func replaceTrack(fileID: UUID, with newTrack: TrackBuffer) {
        tracksLock.lock()
        let oldSnapshot = tracksSnapshot
        var newArray = oldSnapshot.tracks
        if let idx = newArray.firstIndex(where: { $0.id == fileID }) {
            // Preserve the live mute/solo state of the track being replaced
            newTrack.muted = newArray[idx].muted
            newTrack.soloed = newArray[idx].soloed
            newArray[idx] = newTrack
            staleSnapshots.append(oldSnapshot)
            let gen = nextSnapshotGeneration
            nextSnapshotGeneration += 1
            tracksSnapshot = TracksSnapshot(tracks: newArray, generation: gen)
        }
        tracksLock.unlock()

        // Schedule cleanup of stale snapshots after a few render cycles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tracksLock.lock()
            self?.staleSnapshots.removeAll()
            self?.tracksLock.unlock()
        }
    }

    /// Atomically swap the engine's whole track set. Unlike
    /// `prepare(...)`, this does NOT tear down the AVAudioEngine
    /// or rebuild the AVAudioSourceNode — the audio graph stays
    /// up so the swap is glitch-free and ~instant. Use this for
    /// region transitions where the user expects scrubbing
    /// between regions to feel snappy.
    ///
    /// `prepare(...)` is reserved for first-time setup or when
    /// the underlying graph needs to change (sample rate change,
    /// engine teardown after errors). Region transitions only
    /// change WHICH files are loaded — the audio graph stays
    /// the same.
    public func replaceTracks(_ tracks: [TrackBuffer], totalFrames: Int64) {
        let distinctProcessed = tracks.reduce(into: 0) { acc, t in
            if !t.rawChannels.isEmpty && !t.processedChannels.isEmpty,
               t.rawChannels[0] != t.processedChannels[0] {
                acc += 1
            }
        }
        print("[ALIGN-DIAG] engine.replaceTracks tracks=\(tracks.count) distinctProcessed=\(distinctProcessed) usedCorrected(any)=\(tracks.contains { $0.usedCorrectedSource })")
        tracksLock.lock()
        let oldSnapshot = tracksSnapshot
        let gen = nextSnapshotGeneration
        nextSnapshotGeneration += 1
        tracksSnapshot = TracksSnapshot(tracks: tracks, generation: gen)
        self.totalFrames = totalFrames
        // Hold the previous snapshot briefly so any in-flight
        // render call can finish reading its pointers safely.
        staleSnapshots.append(oldSnapshot)
        tracksLock.unlock()

        // Refresh meter dictionary to track only the new files.
        metersLock.lock()
        observed.meters.removeAll()
        for track in tracks {
            observed.meters[track.id] = TrackMeter()
        }
        metersLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tracksLock.lock()
            self?.staleSnapshots.removeAll()
            self?.tracksLock.unlock()
        }
    }

    /// Seek to a specific output sample. Safe to call from main thread.
    public func seek(toSample sample: Int64) {
        tracksLock.lock()
        self.playheadFrames = max(0, min(sample, totalFrames))
        tracksLock.unlock()
    }

    // MARK: - Metering

    private func startMeterTimer() {
        stopMeterTimer()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateMeterDisplay()
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeterDisplay() {
        let peakDecay: Float = 0.85
        let peakHoldDuration: CFTimeInterval = 1.5
        let now = CACurrentMediaTime()

        metersLock.lock()
        // Snapshot current tracks (just for safe iteration)
        let trackSnapshot = self.tracks
        metersLock.unlock()

        for track in trackSnapshot {
            // Snapshot the audio thread's accumulators with plain scalar
            // reads (atomic on aligned memory), then reset them. There IS
            // a tiny race where the audio thread writes a sample between
            // our read and reset, losing one block of peak data — fine for
            // visual metering at 30 Hz.
            let rawPeak = track.meterPeak
            let ch0 = track.meterCh0Peak
            let ch1 = track.meterCh1Peak
            // Snapshot per-channel peaks BEFORE reset — resetMeters
            // zeros the pointer, so reading after reset always gets 0.
            let chCount = track.channelCount
            var perChPeaks = [Float](repeating: 0, count: chCount)
            for ch in 0..<chCount {
                perChPeaks[ch] = track.meterChannelPeaks[ch]
            }
            track.resetMeters()

            guard let meter = observed.meters[track.id] else { continue }

            meter.displayPeak = max(rawPeak, meter.displayPeak * peakDecay)
            // Per-source-channel display peaks. Resize on first use
            // or if the channel count changed (track rebuild). The
            // array lives on the main-thread-only `TrackMeter`, not
            // the audio thread, so `[Float]` is safe here.
            if meter.channelDisplayPeaks.count != chCount {
                meter.channelDisplayPeaks = [Float](repeating: 0, count: chCount)
            }
            for ch in 0..<chCount {
                let chPeak = perChPeaks[ch]
                meter.channelDisplayPeaks[ch] = max(chPeak, meter.channelDisplayPeaks[ch] * peakDecay)
            }
            if rawPeak > meter.peakHold {
                meter.peakHold = rawPeak
                meter.peakHoldTimestamp = now
            } else if now - meter.peakHoldTimestamp > peakHoldDuration {
                meter.peakHold = max(meter.peakHold * 0.92, meter.displayPeak)
            }
        }

        observed.meterTick &+= 1
    }

    // MARK: - Display Link (drives the playhead UI)

    /// Start the display link that advances the visual playhead. The display
    /// link reads the engine's `playheadFrames` (which the audio thread is
    /// updating) and pushes it to `transport.playheadSample`.
    ///
    /// **UI playhead throttled to ~30 Hz.** `CVDisplayLink` fires at
    /// monitor refresh rate — 60 Hz on standard displays, 120 Hz on
    /// ProMotion. Writing to `transport.playheadSample` at that rate
    /// triggers `@Observable` notifications across every SwiftUI
    /// view that observes the playhead (timeline ruler, lane rows,
    /// waveforms, video bar, file list highlights, region cards,
    /// TC readout, etc.). Each notification triggers a body re-
    /// evaluation + CoreAnimation commit on the main thread. At
    /// 120 Hz with a heavy timeline, the main thread stays saturated
    /// and can't keep up with CoreAnimation commits that the MXF
    /// `AVSampleBufferDisplayLayer` needs to present decoded frames
    /// — user sees "consistent staccato" even though VT decoded on
    /// time. Capping observable writes to 30 Hz (a 33 ms cursor
    /// jump is visually imperceptible) frees the main thread to
    /// commit video frames smoothly. Audio-engine sync paths that
    /// need sub-tick precision can still read `playheadFrames`
    /// directly.
    private func startDisplayLink(transport: EnginePlaybackTransport, originSeconds: TimeInterval) {
        stopDisplayLink()

        let speed = transport.shuttleSpeed
        let sampleRate = self.sampleRate
        let startSample = transport.playheadSample
        let totalSamples = transport.totalSamples
        let isAudioPlaying = self.playing  // false for shuttle modes
        let uiTickInterval: TimeInterval = 1.0 / 30.0
        var lastUIPublish: TimeInterval = 0

        displayLink = DisplayLinkTimer { [weak self] in
            guard let self, transport.isPlaying else {
                self?.stopDisplayLink()
                return
            }

            let now = CACurrentMediaTime()
            let shouldPublish = (now - lastUIPublish) >= uiTickInterval

            if isAudioPlaying {
                // Read the audio thread's playhead position. The render block
                // is the source of truth for 1× playback.
                let enginePh = self.playheadFrames
                if enginePh >= Int64(totalSamples) {
                    transport.playheadSample = Int64(totalSamples)
                    transport.stop()
                    self.stop()
                } else if shouldPublish {
                    transport.playheadSample = enginePh
                    lastUIPublish = now
                }
            } else {
                // Visual-only shuttle (silent). Advance the display playhead
                // based on wall clock × shuttle speed.
                let elapsed = now - originSeconds
                let samplesAdvanced = Int64(elapsed * sampleRate * speed)
                let newSample = startSample + samplesAdvanced

                if newSample < 0 {
                    transport.playheadSample = 0
                    transport.stop()
                    self.stop()
                } else if newSample >= Int64(totalSamples) {
                    transport.playheadSample = Int64(totalSamples)
                    transport.stop()
                    self.stop()
                } else if shouldPublish {
                    transport.playheadSample = newSample
                    lastUIPublish = now
                }
            }
        }
    }

    private func stopDisplayLink() {
        displayLink?.stop()
        displayLink = nil
    }
}

// MARK: - Tracks Snapshot

/// Immutable wrapper around the track array. The engine holds a reference to
/// one of these and replaces it atomically when the track set changes.
/// Reading a single class field is atomic on aligned memory, which lets the
/// audio thread read the snapshot without locks.
private final class TracksSnapshot {
    let tracks: [TrackBuffer]
    let generation: Int
    init(tracks: [TrackBuffer], generation: Int = 0) {
        self.tracks = tracks
        self.generation = generation
    }
}

// MARK: - Display Link Timer

/// CVDisplayLink-based timer for smooth playhead updates at screen refresh rate.
private class DisplayLinkTimer {
    private var displayLink: CVDisplayLink?
    private var callbackPointer: Unmanaged<CallbackWrapper>?

    init(callback: @escaping () -> Void) {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }

        let wrapper = CallbackWrapper(callback: callback)
        let pointer = Unmanaged.passRetained(wrapper)
        self.callbackPointer = pointer

        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let wrapper = Unmanaged<CallbackWrapper>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { wrapper.callback() }
            return kCVReturnSuccess
        }, pointer.toOpaque())

        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        callbackPointer?.release()
        callbackPointer = nil
    }

    deinit {
        stop()
    }

    private class CallbackWrapper {
        let callback: () -> Void
        init(callback: @escaping () -> Void) { self.callback = callback }
    }
}
