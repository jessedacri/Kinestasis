import Foundation

/// Native MXF audio extraction. Reads raw PCM packets straight
/// out of the MXF essence stream and produces per-channel Float
/// arrays, no AVFoundation / ffmpeg in the loop.
///
/// **Why this exists.** `AVAssetReader` can't open MXF unless the
/// user has installed Apple's Pro Video Formats package — the
/// same gap that motivated `MXFH264Player` for video. Audio has
/// the same problem: Canon XF-AVC / ARRI ProRes MXF / Sony XAVC
/// all wrap multiple mono (or stereo) PCM tracks per SMPTE 382M,
/// and AVAssetReader refuses them when the Pro Video component
/// isn't present. That leaves camera-audio extraction (PROD /
/// REFERENCE mode) silently broken for pro-camera MXFs.
///
/// **Scope.** Frame-wrapped linear PCM (by far the most common
/// case in camera MXFs). 16-bit, 24-bit, 32-bit little-endian
/// signed integer samples. Clip-wrapped PCM would work too as
/// long as packet lengths are sane — the code just concatenates
/// packet payloads.
///
/// **Architecture.** `MXFEssenceReader.scanAudioIndex` produces
/// per-track byte-range maps; `MXFSoundDescriptorReader.readAll`
/// gives us sample rate / bits / channel count; this extractor
/// seeks + reads each packet and de-interleaves into per-channel
/// Float arrays. Progress is reported packet-by-packet.
///
/// **Multi-track cameras.** Canon XF-AVC records 4 mono mic
/// inputs as 4 separate KLV tracks (element 01..04), each with
/// its own descriptor reporting channelCount=1. ARRI Alexa Mini
/// records 4 channels as 2 stereo tracks. `extract(url:...)`
/// returns one big `channels: [[Float]]` array concatenated in
/// track-number order, matching what
/// `VideoAudioExtractor.extractAndWriteWAV` does for AVFoundation-
/// readable containers.
public struct MXFAudioExtractor {

    public enum ExtractionError: LocalizedError {
        case noSoundTracks
        case noSoundDescriptor
        case unsupportedBitDepth(Int)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noSoundTracks:
                return "MXF contains no sound essence"
            case .noSoundDescriptor:
                return "MXF has no sound descriptor — can't determine sample format"
            case .unsupportedBitDepth(let bits):
                return "MXF uses \(bits)-bit audio which is not supported"
            case .readFailed(let msg):
                return "Failed to read MXF audio: \(msg)"
            }
        }
    }

    public struct Result {
        /// Concatenated per-channel Float arrays across every
        /// track in the file, in track-number order. For Canon
        /// XF-AVC with 4 mono tracks (each channelCount=1), this
        /// is 4 `[Float]` arrays.
        public let channels: [[Float]]
        public let sampleRate: Int
        /// Number of audio frames (per-channel sample count) —
        /// all channels have the same length.
        public let frameCount: Int

        public init(channels: [[Float]], sampleRate: Int, frameCount: Int) {
            self.channels = channels
            self.sampleRate = sampleRate
            self.frameCount = frameCount
        }
    }

    public typealias ProgressCallback = @Sendable (_ fraction: Double) -> Void

    /// Decode every sound track in an MXF into per-channel Float
    /// arrays at the file's native sample rate. Packet reads
    /// happen through a single long-lived FileHandle so we don't
    /// pay open/close overhead per packet.
    public static func extract(
        url: URL,
        onProgress: ProgressCallback? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> Result {
        let index = try MXFEssenceReader.scanAudioIndex(url: url)
        guard !index.soundTracks.isEmpty else {
            throw ExtractionError.noSoundTracks
        }
        let descriptors = try MXFSoundDescriptorReader.readAll(url: url)
        guard let primary = descriptors.first else {
            throw ExtractionError.noSoundDescriptor
        }
        let sampleRate = Int(primary.sampleRate.rounded())
        let bytesPerSample = primary.bytesPerSample
        let bits = Int(primary.quantizationBits)

        // Only handle linear PCM widths the camera world
        // actually produces. Anything else (8-bit, µ-law,
        // AES3-in-MXF, compressed) needs a different decoder
        // path that we haven't built yet.
        guard bits == 16 || bits == 24 || bits == 32 else {
            throw ExtractionError.unsupportedBitDepth(bits)
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ExtractionError.readFailed("cannot open \(url.lastPathComponent)")
        }
        defer { try? handle.close() }

        // Per-track descriptor matching. Canon XF-AVC writes one
        // descriptor per mono track; if the scanner returned N
        // descriptors and N tracks, pair them by track order.
        // Otherwise every track inherits the first descriptor
        // (stereo WAVE inside MXF with a single descriptor).
        let trackNumbers = index.soundTracks.keys.sorted()
        var perTrackChannels: [Int: [[Float]]] = [:]

        // Total byte budget for progress (sum of packet lengths
        // across every track).
        let totalBytes: UInt64 = trackNumbers.reduce(0) { acc, n in
            guard let t = index.soundTracks[n] else { return acc }
            return acc + t.packets.reduce(0) { $0 + $1.payloadLength }
        }
        var readBytes: UInt64 = 0

        for (idx, trackNum) in trackNumbers.enumerated() {
            guard let track = index.soundTracks[trackNum] else { continue }
            let desc: MXFSoundDescriptorReader.Result = {
                if descriptors.count == trackNumbers.count {
                    return descriptors[idx]
                }
                return primary
            }()
            let trackChannels = Int(desc.channelCount)
            let trackBytesPerSample = desc.bytesPerSample

            // Estimate total samples per channel from packet
            // byte count / (channels * bytesPerSample).
            let trackTotalBytes = track.packets.reduce(0) { $0 + $1.payloadLength }
            let estimatedFrames = Int(trackTotalBytes) / max(1, trackChannels * trackBytesPerSample)

            var channels = [[Float]](repeating: [], count: max(1, trackChannels))
            for c in 0..<channels.count {
                channels[c].reserveCapacity(estimatedFrames)
            }

            for packet in track.packets {
                if isCancelled?() == true {
                    throw CancellationError()
                }
                try handle.seek(toOffset: packet.payloadOffset)
                guard let data = try handle.read(upToCount: Int(packet.payloadLength)),
                      data.count == Int(packet.payloadLength) else {
                    throw ExtractionError.readFailed(
                        "short read at packet offset \(packet.payloadOffset)"
                    )
                }
                decodePCM(
                    data: data,
                    bytesPerSample: trackBytesPerSample,
                    channels: trackChannels,
                    into: &channels
                )
                readBytes &+= packet.payloadLength
                if totalBytes > 0 {
                    let frac = min(1.0, Double(readBytes) / Double(totalBytes))
                    onProgress?(frac)
                }
            }

            perTrackChannels[trackNum] = channels
        }

        // Concatenate in track-number order. Trim all channels
        // to the minimum length so uneven packet tails don't
        // leave one channel longer than another.
        var outputChannels: [[Float]] = []
        var minFrames = Int.max
        for n in trackNumbers {
            if let chs = perTrackChannels[n] {
                for ch in chs where ch.count < minFrames {
                    minFrames = ch.count
                }
            }
        }
        guard minFrames != Int.max, minFrames > 0 else {
            throw ExtractionError.readFailed("no audio samples decoded")
        }
        for n in trackNumbers {
            guard let chs = perTrackChannels[n] else { continue }
            for ch in chs {
                outputChannels.append(Array(ch.prefix(minFrames)))
            }
        }

        return Result(
            channels: outputChannels,
            sampleRate: sampleRate,
            frameCount: minFrames
        )
    }

    /// Decode an interleaved little-endian signed PCM buffer
    /// into Float samples ([-1, 1]), appending per-channel.
    /// Handles 16 / 24 / 32 bit widths — the sizes linear-PCM
    /// MXFs actually use in the wild.
    fileprivate static func decodePCM(
        data: Data,
        bytesPerSample: Int,
        channels: Int,
        into output: inout [[Float]]
    ) {
        let bytesPerFrame = bytesPerSample * channels
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            switch bytesPerSample {
            case 2:
                let scale: Float = 1.0 / 32768.0
                for frame in 0..<frameCount {
                    for c in 0..<channels {
                        let ofs = frame * bytesPerFrame + c * 2
                        let lo = UInt16(base[ofs])
                        let hi = UInt16(base[ofs + 1])
                        let raw = Int16(bitPattern: UInt16(hi << 8 | lo))
                        output[c].append(Float(raw) * scale)
                    }
                }
            case 3:
                // 24-bit LE signed. Sign-extend from bit 23.
                let scale: Float = 1.0 / 8388608.0
                for frame in 0..<frameCount {
                    for c in 0..<channels {
                        let ofs = frame * bytesPerFrame + c * 3
                        let b0 = UInt32(base[ofs])
                        let b1 = UInt32(base[ofs + 1])
                        let b2 = UInt32(base[ofs + 2])
                        var value = Int32(bitPattern: (b2 << 16) | (b1 << 8) | b0)
                        if (value & 0x0080_0000) != 0 {
                            value |= Int32(bitPattern: 0xFF00_0000)
                        }
                        output[c].append(Float(value) * scale)
                    }
                }
            case 4:
                let scale: Float = 1.0 / 2147483648.0
                for frame in 0..<frameCount {
                    for c in 0..<channels {
                        let ofs = frame * bytesPerFrame + c * 4
                        let b0 = UInt32(base[ofs])
                        let b1 = UInt32(base[ofs + 1])
                        let b2 = UInt32(base[ofs + 2])
                        let b3 = UInt32(base[ofs + 3])
                        let raw = Int32(bitPattern: (b3 << 24) | (b2 << 16) | (b1 << 8) | b0)
                        output[c].append(Float(raw) * scale)
                    }
                }
            default:
                break
            }
        }
    }
}

/// Random-access MXF audio reader. Builds the sound-packet index ONCE
/// (the expensive full-file KLV walk) and holds an open file handle, then
/// serves `decodeRange` requests that read + decode ONLY the packets
/// covering the requested sample span. This is what makes a bin of long
/// MXF clips usable — a trimmed timeline clip decodes its span (≈ms),
/// not the whole 200s+ track (≈10s).
public final class MXFAudioReader: @unchecked Sendable {
    public let sampleRate: Int
    public let totalFrames: Int
    public var channelCount: Int { plans.reduce(0) { $0 + $1.channels } }

    private struct Plan {
        let packets: [MXFEssenceReader.FrameRef]
        let cum: [Int]            // cum[i] = first sample-frame of packet i; cum[count] = total frames
        let channels: Int         // channels carried in each packet of this track
        let bytesPerSample: Int
    }
    private let plans: [Plan]
    private let handle: FileHandle
    private let lock = NSLock()

    private init(plans: [Plan], handle: FileHandle, sampleRate: Int, totalFrames: Int) {
        self.plans = plans; self.handle = handle
        self.sampleRate = sampleRate; self.totalFrames = totalFrames
    }

    deinit { try? handle.close() }

    public static func open(url: URL) throws -> MXFAudioReader {
        let index = try MXFEssenceReader.scanAudioIndex(url: url)
        guard !index.soundTracks.isEmpty else { throw MXFAudioExtractor.ExtractionError.noSoundTracks }
        let descriptors = try MXFSoundDescriptorReader.readAll(url: url)
        guard let primary = descriptors.first else { throw MXFAudioExtractor.ExtractionError.noSoundDescriptor }
        let bits = Int(primary.quantizationBits)
        guard bits == 16 || bits == 24 || bits == 32 else { throw MXFAudioExtractor.ExtractionError.unsupportedBitDepth(bits) }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw MXFAudioExtractor.ExtractionError.readFailed("cannot open \(url.lastPathComponent)")
        }

        let trackNumbers = index.soundTracks.keys.sorted()
        var plans: [Plan] = []
        var minTotal = Int.max
        for (idx, n) in trackNumbers.enumerated() {
            guard let t = index.soundTracks[n] else { continue }
            let desc = descriptors.count == trackNumbers.count ? descriptors[idx] : primary
            let ch = max(1, Int(desc.channelCount))
            let bps = desc.bytesPerSample
            let bpf = max(1, ch * bps)
            var cum = [Int](repeating: 0, count: t.packets.count + 1)
            for (i, p) in t.packets.enumerated() {
                cum[i + 1] = cum[i] + Int(p.payloadLength) / bpf
            }
            plans.append(Plan(packets: t.packets, cum: cum, channels: ch, bytesPerSample: bps))
            minTotal = min(minTotal, cum.last ?? 0)
        }
        let sampleRate = Int(primary.sampleRate.rounded())
        return MXFAudioReader(plans: plans, handle: handle,
                              sampleRate: sampleRate,
                              totalFrames: minTotal == Int.max ? 0 : minTotal)
    }

    /// Decode `frameCount` samples per channel starting at `startFrame`
    /// (source-frame index, full-file timeline). Out-of-range positions are
    /// silence. Output channel order matches `MXFAudioExtractor.extract`.
    public func decodeRange(startFrame: Int, frameCount: Int) -> [[Float]] {
        guard frameCount > 0 else { return plans.flatMap { Array(repeating: [Float](), count: $0.channels) } }
        lock.lock(); defer { lock.unlock() }
        var out: [[Float]] = []
        let hi = startFrame + frameCount
        for plan in plans {
            var chans = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: plan.channels)
            let total = plan.cum.last ?? 0
            if startFrame < total && hi > 0 {
                var pi = packetContaining(plan.cum, max(0, startFrame))
                while pi < plan.packets.count && plan.cum[pi] < hi {
                    let pStart = plan.cum[pi]
                    if let data = readPacket(plan.packets[pi]) {
                        var dec = [[Float]](repeating: [], count: plan.channels)
                        MXFAudioExtractor.decodePCM(data: data, bytesPerSample: plan.bytesPerSample,
                                                    channels: plan.channels, into: &dec)
                        for c in 0..<plan.channels {
                            let n = dec[c].count
                            for j in 0..<n {
                                let outIdx = pStart + j - startFrame
                                if outIdx >= 0 && outIdx < frameCount { chans[c][outIdx] = dec[c][j] }
                            }
                        }
                    }
                    pi += 1
                }
            }
            out.append(contentsOf: chans)
        }
        return out
    }

    private func readPacket(_ ref: MXFEssenceReader.FrameRef) -> Data? {
        do {
            try handle.seek(toOffset: ref.payloadOffset)
            let d = try handle.read(upToCount: Int(ref.payloadLength))
            return (d?.count == Int(ref.payloadLength)) ? d : nil
        } catch { return nil }
    }

    /// Largest packet index `p` with `cum[p] <= frame`.
    private func packetContaining(_ cum: [Int], _ frame: Int) -> Int {
        var lo = 0, hi = cum.count - 2
        if hi < 0 { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cum[mid] <= frame { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
