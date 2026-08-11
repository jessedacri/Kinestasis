import Foundation
import KineCore

/// Filesystem layout + bookkeeping for the sequence pre-render cache.
/// Each (sequence, In→Out range) maps to a single ProRes `.mov` segment
/// under `~/Library/Caches/Kine/projects/<projectID>/prerender/`.
///
/// We key by project UUID rather than the `.kine` file path so the
/// cache survives renames + moves. Files are regenerable in seconds-to-
/// minutes so loss-on-copy across machines is acceptable for v1.
public enum PreRenderCache {

    /// Subdirectory name beneath `projectCacheRoot`.
    public static let subdir = "prerender"

    /// Resolve (and create if missing) the prerender directory for a
    /// given project UUID.
    public static func directory(forProjectID projectID: UUID) -> URL {
        let root = ProjectStore.projectCacheRoot(forProjectID: projectID)
        let dir = root.appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File URL for the cache segment covering `[startMs, endMs)` on
    /// the given sequence. The filename carries only the range — the
    /// freshness contract is "any segment on disk is valid for the
    /// current sequence state" because every clip-mutating path in
    /// WorkspaceModel calls `clearAll(...)` before letting the edit
    /// land. Re-rendering the same range overwrites the file in place.
    public static func segmentURL(
        forProjectID projectID: UUID,
        sequenceID: SequenceID,
        startMs: Int64,
        endMs: Int64
    ) -> URL {
        let dir = directory(forProjectID: projectID)
        let name = "\(sequenceID.rawValue.uuidString)_\(startMs)_\(endMs).mov"
        return dir.appendingPathComponent(name)
    }

    /// Delete every cached segment for the given sequence. Called when
    /// the sequence-level structure changes enough that nothing should
    /// be trusted (e.g. settings change, full clear).
    public static func clearAll(forProjectID projectID: UUID, sequenceID: SequenceID) {
        let dir = directory(forProjectID: projectID)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = "\(sequenceID.rawValue.uuidString)_"
        for name in contents where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Drop every segment whose timeline range overlaps `[startMs, endMs)`
    /// on the given sequence. Used when a clip inside a specific region
    /// changes and we want to keep segments outside the region alive.
    public static func invalidate(
        overlapping startMs: Int64,
        _ endMs: Int64,
        forProjectID projectID: UUID,
        sequenceID: SequenceID
    ) {
        let dir = directory(forProjectID: projectID)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let prefix = "\(sequenceID.rawValue.uuidString)_"
        for name in contents where name.hasPrefix(prefix) {
            // Strip the ".mov" suffix then split on "_". Filename is
            // `<sequenceID>_<startMs>_<endMs>.mov`.
            let stem = (name as NSString).deletingPathExtension
            let parts = stem.dropFirst(prefix.count).split(separator: "_")
            guard parts.count >= 2,
                  let segStart = Int64(parts[0]),
                  let segEnd   = Int64(parts[1])
            else { continue }
            if segStart < endMs && segEnd > startMs {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }


    /// Enumerate every on-disk segment for the given sequence. Used by
    /// the timeline ruler overlay and by playback-substitution lookups.
    public static func allSegments(
        forProjectID projectID: UUID,
        sequenceID: SequenceID
    ) -> [(url: URL, startMs: Int64, endMs: Int64)] {
        let dir = directory(forProjectID: projectID)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let prefix = "\(sequenceID.rawValue.uuidString)_"
        var out: [(URL, Int64, Int64)] = []
        for name in contents where name.hasPrefix(prefix) && name.hasSuffix(".mov") {
            let stem = (name as NSString).deletingPathExtension
            let parts = stem.dropFirst(prefix.count).split(separator: "_")
            guard parts.count >= 2,
                  let segStart = Int64(parts[0]),
                  let segEnd   = Int64(parts[1])
            else { continue }
            out.append((dir.appendingPathComponent(name), segStart, segEnd))
        }
        return out
    }
}
