import Foundation

/// Opt-in performance recorder for field reports: the user turns it on,
/// reproduces the slowness, and sends back one plain-text file.
///
/// Records timing, counts, and file basenames only - never image data,
/// never a full path. Off, every call costs one Bool read: the message is
/// an autoclosure, so nothing is even formatted.
public enum KineDiagnostics {

    /// Counters aggregated between snapshots. High-rate events (cache hits,
    /// decodes) would drown the log one line at a time.
    public enum Counter: String, CaseIterable {
        case ramHit = "ram-hit"
        case diskHit = "disk-hit"
        case decode = "decode"
        case enqueue = "enqueue"
        case frameMiss = "frame-miss"   // player asked for a frame that was not ready
    }

    private static let queue = DispatchQueue(label: "kine.diagnostics", qos: .utility)
    private static var handle: FileHandle?
    private static var counters: [String: Int] = [:]
    private static var startedAt = Date()
    private static var lastSnapshot = ""
    private static var lastSnapshotAt = 0.0

    /// Read from every instrumentation point, including hot ones. Written
    /// only by start/stop.
    public nonisolated(unsafe) private(set) static var isRecording = false
    public nonisolated(unsafe) private(set) static var currentLogURL: URL?

    /// Where recordings land. Visible in the Finder without hunting.
    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Kinestasis Diagnostics", isDirectory: true)
    }

    /// Begins a recording, returning the file being written. `context`
    /// lines describe the machine and the app's current settings.
    @discardableResult
    public static func start(context: [String: String] = [:]) -> URL? {
        guard !isRecording else { return currentLogURL }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = logDirectory.appendingPathComponent("kinestasis-diagnostics-\(stamp.string(from: Date())).txt")
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
            handle = try FileHandle(forWritingTo: url)
        } catch {
            return nil
        }
        startedAt = Date()
        counters = [:]
        lastSnapshot = ""
        lastSnapshotAt = 0
        currentLogURL = url
        isRecording = true

        let info = ProcessInfo.processInfo
        var header = [
            "Kinestasis diagnostics",
            "started        \(ISO8601DateFormatter().string(from: startedAt))",
            "app            \(appVersion)",
            "macOS          \(info.operatingSystemVersionString)",
            "cores          \(info.processorCount) (\(info.activeProcessorCount) active)",
            "memory         \(info.physicalMemory / 1_073_741_824) GB",
        ]
        for key in context.keys.sorted() {
            header.append(key.padding(toLength: max(15, key.count + 1), withPad: " ", startingAt: 0) + (context[key] ?? ""))
        }
        header.append("")
        header.append("Timing, counts, and file names only. No image data.")
        header.append("")
        write(header.joined(separator: "\n") + "\n")
        return url
    }

    @discardableResult
    public static func stop() -> URL? {
        guard isRecording else { return nil }
        flushCounters()
        write("\nstopped after \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s\n")
        let url = currentLogURL
        isRecording = false
        queue.sync {
            try? handle?.close()
            handle = nil
        }
        return url
    }

    /// One line, written immediately. For discrete events: stalls, tier
    /// changes, the start of a scrub, an unusually slow decode.
    public static func log(_ message: @autoclosure () -> String) {
        guard isRecording else { return }
        let text = message()
        let elapsed = Date().timeIntervalSince(startedAt)
        write(String(format: "%8.2f  %@\n", elapsed, text))
    }

    /// Bumps an aggregate counter. Cheap enough for per-frame paths.
    public static func count(_ counter: Counter, _ amount: Int = 1) {
        guard isRecording else { return }
        queue.async { counters[counter.rawValue, default: 0] += amount }
    }

    /// Emits the accumulated counters and resets them. Call on a timer
    /// while recording, so the log reads as a rate over time.
    public static func snapshot(_ state: @autoclosure () -> String) {
        guard isRecording else { return }
        let text = state()
        let elapsed = Date().timeIntervalSince(startedAt)
        queue.async {
            let tallies = Counter.allCases
                .compactMap { c -> String? in
                    guard let n = counters[c.rawValue], n > 0 else { return nil }
                    return "\(c.rawValue) \(n)"
                }
                .joined(separator: " · ")
            counters = [:]
            // An idle app would otherwise write the same line every two
            // seconds and bury the interesting ones.
            if tallies.isEmpty, text == lastSnapshot, elapsed - lastSnapshotAt < 30 { return }
            lastSnapshot = text
            lastSnapshotAt = elapsed
            let line = tallies.isEmpty ? text : "\(text) · \(tallies)"
            append(String(format: "%8.2f  %@\n", elapsed, line))
        }
    }

    private static func flushCounters() {
        queue.sync {
            let tallies = Counter.allCases.compactMap { c -> String? in
                guard let n = counters[c.rawValue], n > 0 else { return nil }
                return "\(c.rawValue) \(n)"
            }
            if !tallies.isEmpty {
                append("\ntotals since last snapshot: \(tallies.joined(separator: " · "))\n")
            }
            counters = [:]
        }
    }

    private static func write(_ text: String) {
        queue.async { append(text) }
    }

    /// Must be called on `queue`.
    private static func append(_ text: String) {
        guard let handle else { return }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
