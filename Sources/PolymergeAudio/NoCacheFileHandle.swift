import Foundation

/// Helper for opening files with `F_NOCACHE` set so that sequential
/// reads don't populate macOS's unified buffer cache.
///
/// **The problem.** `FileHandle(forReadingFrom:)` opens the file
/// with default cache behavior. Every chunk we read is mirrored
/// into the kernel's file-backed page cache. For a one-time scan
/// of a 14 GB Sound Devices poly (waveform generation, LTC
/// detection, stats) or a ProRes MXF that ffprobe walks, those
/// pages stay RESIDENT in RAM after we're done with the file —
/// they're "evictable" but count against the app's footprint in
/// Activity Monitor and contribute to memory pressure when the
/// user has 30+ GB of cached but unused audio.
///
/// For a shoot-day import with 9 multi-GB WAVs + 25 huge MXFs,
/// the cumulative page cache pollution was pushing macOS into
/// swap thrash even when PolyMerge's ACTUAL allocated memory
/// (phys_footprint) was under 10 GB.
///
/// **The fix.** `F_NOCACHE = 1` tells the unified buffer cache
/// to skip caching for this FD. Reads still work; they just
/// go directly from disk → user buffer without leaving a
/// cached copy behind. For audio / video metadata scans we're
/// never going to re-read from the same position, so caching
/// is pure overhead.
///
/// **When NOT to use this.**
///   - Playback render threads reading small chunks repeatedly
///     (they benefit from caching).
///   - Files we'll re-read later in the same session.
///
/// The helper is for one-time scans: waveform generation,
/// channel stats, LTC detection, MXF KLV walks. Each touches
/// a file once and moves on.
public struct NoCacheFileHandle {
    /// Open a file handle with `F_NOCACHE` enabled. Falls back
    /// to a regular `FileHandle(forReadingFrom:)` if the fcntl
    /// fails (rare; F_NOCACHE is supported on every macOS
    /// version PolyMerge runs on, but defensive).
    public static func open(url: URL) throws -> FileHandle {
        let handle = try FileHandle(forReadingFrom: url)
        // Disable the unified buffer cache for this FD. The
        // returned value is 0 on success, -1 on failure; we
        // don't surface failures because caching-ON is a valid
        // fallback.
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        return handle
    }
}
