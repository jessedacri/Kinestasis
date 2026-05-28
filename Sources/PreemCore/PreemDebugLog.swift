import Foundation

/// File-based debug logger that bypasses stdout. SPM foreground GUI
/// apps sometimes have their stdout redirected away from the launching
/// terminal once the activation policy goes regular; writing directly
/// to a file in /tmp guarantees we capture diagnostics during a
/// debug run.
public enum PreemDebugLog {
    nonisolated(unsafe) private static let path = "/tmp/preem-debug.log"
    nonisolated(unsafe) private static let queue = DispatchQueue(label: "preem.debug.log")
    nonisolated(unsafe) private static var didTruncate = false

    public static func log(_ message: String) {
        queue.async {
            if !didTruncate {
                try? "".write(toFile: path, atomically: true, encoding: .utf8)
                didTruncate = true
            }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) \(message)\n"
            if let data = line.data(using: .utf8),
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        }
    }
}
