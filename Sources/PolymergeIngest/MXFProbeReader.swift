import Foundation

/// Fast MXF metadata extractor that shells out to `ffprobe`
/// rather than using AVFoundation's `AVURLAsset.load(.duration)`
/// on the huge ARRI / Sony / Canon MXFs the user's shoot days
/// produce.
///
/// **Why ffprobe instead of AVFoundation.**
/// AVFoundation with `preferPreciseDurationAndTiming: true`
/// memory-maps the essence body to count frames precisely. For
/// a 193 GB ARRI MXF that's tens of GB of mapped pages held
/// long after the parse completes, counted against the process's
/// working set and pushing macOS into swap. With
/// `preferPreciseDurationAndTiming: false`, AVFoundation's MXF
/// handler outright refuses to open the file ("Cannot Open") —
/// it appears the reader doesn't trust the header's duration
/// field (which ARRI populates with 0xFFFFFFFFFFFFFFFF
/// "undefined" everywhere).
///
/// `ffprobe` via FFmpeg handles MXF reliably and extracts exact
/// duration in under 200 ms even for a 193 GB file — it uses
/// the Random Index Pack at the footer to jump to the index
/// table without walking the essence body.
///
/// **Dependency:** requires `ffprobe` on the user's PATH or at
/// one of the standard Homebrew install locations. Without it,
/// the MXF parser falls back to the bitrate-based duration
/// estimator in `MXFTimecodeReader` (inaccurate but functional).
///
/// **Thread safety:** stateless. Safe to call from any thread.
public struct MXFProbeReader {

    public struct Metadata {
        public let durationSeconds: Double
        public let width: Int
        public let height: Int
        public let videoCodec: String
        public let frameRate: Double
        public let audioTrackCount: Int
        public let audioSampleRate: Int?
        public let audioChannelCount: Int

        public init(durationSeconds: Double, width: Int, height: Int, videoCodec: String, frameRate: Double, audioTrackCount: Int, audioSampleRate: Int?, audioChannelCount: Int) {
            self.durationSeconds = durationSeconds
            self.width = width
            self.height = height
            self.videoCodec = videoCodec
            self.frameRate = frameRate
            self.audioTrackCount = audioTrackCount
            self.audioSampleRate = audioSampleRate
            self.audioChannelCount = audioChannelCount
        }
    }

    /// Standard ffprobe install locations. We check the user's
    /// PATH first, then these specific paths (Homebrew default
    /// locations for Apple Silicon + Intel), so an installed
    /// ffprobe is found even when the app bundle's PATH is
    /// stripped by launchd.
    private static let ffprobePaths: [String] = [
        "/opt/homebrew/bin/ffprobe",    // Apple Silicon Homebrew
        "/usr/local/bin/ffprobe",       // Intel Homebrew
        "/usr/bin/ffprobe",             // system (rare)
    ]

    /// Locate ffprobe on disk. Returns nil if not installed.
    /// Cached per process to avoid repeated filesystem probes.
    private static let cachedFFprobePath: String? = {
        for path in ffprobePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback: `which` the PATH
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["ffprobe"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // fall through
        }
        return nil
    }()

    public static var isAvailable: Bool { cachedFFprobePath != nil }

    /// Run ffprobe on an MXF and return its metadata. Throws on
    /// process failure or missing ffprobe.
    public static func probe(url: URL) throws -> Metadata {
        guard let ffprobe = cachedFFprobePath else {
            throw ProbeError.ffprobeNotInstalled
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffprobe)
        task.arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw ProbeError.processFailed(status: Int(task.terminationStatus))
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.invalidOutput
        }

        // Duration: prefer format.duration (container-level),
        // fall back to first video stream's duration.
        var duration: Double = 0
        if let fmt = json["format"] as? [String: Any],
           let durStr = fmt["duration"] as? String,
           let d = Double(durStr) {
            duration = d
        }

        // Parse streams for video + audio info.
        var width = 0, height = 0, codec = "MXF"
        var frameRate: Double = 23.976
        var audioTrackCount = 0, audioChannelCount = 0
        var audioSampleRate: Int?
        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                guard let codecType = stream["codec_type"] as? String else { continue }
                if codecType == "video" {
                    if width == 0, let w = stream["width"] as? Int { width = w }
                    if height == 0, let h = stream["height"] as? Int { height = h }
                    if let n = stream["codec_name"] as? String, codec == "MXF" {
                        codec = n.capitalized
                    }
                    // Duration fallback from stream level.
                    if duration == 0,
                       let durStr = stream["duration"] as? String,
                       let d = Double(durStr) {
                        duration = d
                    }
                    // Frame rate — r_frame_rate is "num/den".
                    if let rfr = stream["r_frame_rate"] as? String {
                        let parts = rfr.split(separator: "/").map(String.init)
                        if parts.count == 2,
                           let num = Double(parts[0]),
                           let den = Double(parts[1]),
                           den > 0 {
                            frameRate = num / den
                        }
                    }
                } else if codecType == "audio" {
                    audioTrackCount += 1
                    if let ch = stream["channels"] as? Int {
                        audioChannelCount += ch
                    }
                    if audioSampleRate == nil,
                       let srStr = stream["sample_rate"] as? String,
                       let sr = Int(srStr) {
                        audioSampleRate = sr
                    }
                }
            }
        }

        return Metadata(
            durationSeconds: duration,
            width: width,
            height: height,
            videoCodec: codec,
            frameRate: frameRate,
            audioTrackCount: audioTrackCount,
            audioSampleRate: audioSampleRate,
            audioChannelCount: audioChannelCount
        )
    }

    public enum ProbeError: LocalizedError {
        case ffprobeNotInstalled
        case processFailed(status: Int)
        case invalidOutput

        public var errorDescription: String? {
            switch self {
            case .ffprobeNotInstalled:
                return "ffprobe not found on PATH or standard Homebrew locations. Install via 'brew install ffmpeg' to enable fast MXF duration probing."
            case .processFailed(let status):
                return "ffprobe exited with status \(status)"
            case .invalidOutput:
                return "ffprobe returned malformed JSON"
            }
        }
    }
}
