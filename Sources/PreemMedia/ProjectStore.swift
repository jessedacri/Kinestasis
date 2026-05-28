import Foundation
import PreemCore

/// Reads and writes `.preem` project files. v0.x stores the project as
/// a single JSON file. Render / proxy / waveform / thumbnail caches
/// live under `~/Library/Caches/com.preem/projects/<projectID>/` —
/// keyed by Project.id so the cache survives renames and follows the
/// project's identity rather than its on-disk path.
public enum ProjectStore {

    public static let fileExtension = "preem"

    public enum LoadError: Error, LocalizedError {
        case readFailed(String)
        case decodeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .readFailed(let s):   return "Could not read project file: \(s)"
            case .decodeFailed(let s): return "Project file is not a valid Preem project: \(s)"
            }
        }
    }

    public enum SaveError: Error, LocalizedError {
        case encodeFailed(String)
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .encodeFailed(let s): return "Could not encode project: \(s)"
            case .writeFailed(let s):  return "Could not write project file: \(s)"
            }
        }
    }

    /// JSON-encode and save the project atomically to the given URL.
    public static func save(project: Project, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(project)
        } catch {
            throw SaveError.encodeFailed(error.localizedDescription)
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }
    }

    /// Read and decode a project from the given URL.
    public static func load(from url: URL) throws -> Project {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.readFailed(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Project.self, from: data)
        } catch {
            throw LoadError.decodeFailed(error.localizedDescription)
        }
    }

    /// Standard autosave location for crash recovery — one file per
    /// running app instance keyed by the project's UUID. Lives in the
    /// user's caches directory so it's never user-visible but always
    /// recoverable.
    public static func autosaveURL(forProjectID id: UUID) -> URL {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Preem", isDirectory: true)
            .appendingPathComponent("autosave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id.uuidString).preem")
    }

    /// Root cache directory for a given project. Each subsystem
    /// (`prerender`, future `proxies`, etc.) reserves its own subdir
    /// beneath this root. Centralized so cache lookup doesn't depend on
    /// where the user keeps the `.preem` file.
    public static func projectCacheRoot(forProjectID id: UUID) -> URL {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Preem", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
