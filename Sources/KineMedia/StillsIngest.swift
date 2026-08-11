import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import KineCore

/// Scans a dropped folder for stills, reads EXIF capture times, and groups
/// them into `BurstShot`s. Pure metadata pass — no pixel decode — so a
/// thousand-frame burst folder ingests in well under a second.
public struct StillsIngest: Sendable {

    /// JPEG/HEIF plus the OEM RAW containers ImageIO decodes natively.
    /// Apple's per-OS supported-camera list is the compatibility boundary.
    public static let stillExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "tif", "tiff", "png",
        "dng", "raf", "arw", "nef", "nrw", "cr2", "cr3", "crw",
        "orf", "rw2", "pef", "srw", "erf", "raw", "rwl", "3fr", "fff", "iiq",
    ]

    /// Video files dropped alongside stills become shots too (Jesse,
    /// 2026-08-10): interpreted with the same look/feel via the existing
    /// AVFoundation clip path.
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public struct FolderScan: Sendable {
        /// Primary stills — the RAW of a RAW+JPEG pair.
        public var stills: [URL]
        /// RAW primary → its JPEG twin, for pairs.
        public var jpegPairs: [URL: URL]
        public var videos: [URL]
    }

    public init() {}

    /// Recursively list ingestable files under `folder` (or the file itself
    /// when a single file is dropped). Hidden files and packages skipped.
    public func scan(_ root: URL) -> FolderScan {
        var stills: [URL] = []
        var videos: [URL] = []
        let fm = FileManager.default

        func classify(_ url: URL) {
            let ext = url.pathExtension.lowercased()
            if Self.stillExtensions.contains(ext) { stills.append(url) }
            else if Self.videoExtensions.contains(ext) { videos.append(url) }
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else {
            return FolderScan(stills: [], jpegPairs: [:], videos: [])
        }
        if !isDir.boolValue {
            classify(root)
        } else if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    classify(url)
                }
            }
        }
        let (primaries, pairs) = Self.pairRawJpeg(stills)
        stills = primaries.sorted { $0.path < $1.path }
        videos.sort { $0.path < $1.path }
        return FolderScan(stills: stills, jpegPairs: pairs, videos: videos)
    }

    /// Cameras writing RAW+JPEG drop two files per shutter press
    /// (DSC01234.ARW + DSC01234.JPG). Collapse each same-directory
    /// basename pair to one primary still (the RAW), remembering the JPEG
    /// twin so shots can switch their frame source between the two.
    static func pairRawJpeg(_ stills: [URL]) -> (primaries: [URL], jpegPairs: [URL: URL]) {
        let jpegExts: Set<String> = ["jpg", "jpeg", "heic", "heif"]
        var byKey: [String: URL] = [:]
        var jpegByKey: [String: URL] = [:]
        var order: [String] = []
        for url in stills {
            let key = url.deletingPathExtension().path.lowercased()
            let isJpeg = jpegExts.contains(url.pathExtension.lowercased())
            if byKey[key] == nil {
                byKey[key] = url
                order.append(key)
                if isJpeg { jpegByKey[key] = url }
            } else if isJpeg {
                jpegByKey[key] = url                       // RAW already primary
            } else if jpegExts.contains(byKey[key]!.pathExtension.lowercased()) {
                jpegByKey[key] = byKey[key]                // promote RAW to primary
                byKey[key] = url
            }
        }
        var pairs: [URL: URL] = [:]
        for key in order {
            if let primary = byKey[key], let jpeg = jpegByKey[key], primary != jpeg {
                pairs[primary] = jpeg
            }
        }
        return (order.compactMap { byKey[$0] }, pairs)
    }

    /// Read one still's capture time + pixel size without decoding pixels.
    /// EXIF DateTimeOriginal + SubSecTimeOriginal; falls back to the file's
    /// modification date when EXIF is absent.
    public func probeStill(_ url: URL) -> StillFrame {
        var captureTime: TimeInterval?
        var pixelSize: PixelSize?

        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            // Orientation-aware pixel size: EXIF orientations 5–8 are 90°
            // rotations, so width/height swap for display purposes.
            if let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
                pixelSize = orientation >= 5
                    ? PixelSize(width: h, height: w)
                    : PixelSize(width: w, height: h)
            }
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
               let base = Self.exifFormatter.date(from: dateString) {
                var t = base.timeIntervalSince1970
                // Subsec fallback chain — cameras disagree on which tag
                // they fill (X-Pro2 writes none at all).
                let subsecTags = [kCGImagePropertyExifSubsecTimeOriginal,
                                  kCGImagePropertyExifSubsecTimeDigitized,
                                  kCGImagePropertyExifSubsecTime]
                for tag in subsecTags {
                    if let subsec = exif[tag] as? String,
                       let fraction = Double("0.\(subsec.trimmingCharacters(in: .whitespaces))") {
                        t += fraction
                        break
                    }
                }
                captureTime = t
            }
        }

        if captureTime == nil {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            captureTime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        return StillFrame(url: url, captureTime: captureTime ?? 0, pixelSize: pixelSize)
    }

    public struct IngestResult: Sendable {
        public var shots: [BurstShot]
        /// Stills whose capture-gap group fell below `minBurstCount` —
        /// one-offs, not bursts. Kept aside so they can be pruned to a
        /// separate folder instead of polluting the shot list.
        public var singles: [StillFrame]
        public var videos: [URL]
    }

    /// Full ingest: scan → probe every still (parallel, metadata-only) →
    /// group by capture gap → split real bursts from singles. Shots are
    /// named `<folder>_S001`, `_S002`, … in capture order. `progress`
    /// fires (done, total) from worker threads — hop to the main actor
    /// before touching UI state.
    public func ingest(folder: URL, gapThreshold: TimeInterval, minBurstCount: Int = 3,
                       progress: (@Sendable (Int, Int) -> Void)? = nil) -> IngestResult {
        let scanResult = scan(folder)
        let urls = scanResult.stills
        let total = urls.count
        var results = [StillFrame?](repeating: nil, count: total)
        let lock = NSLock()
        var done = 0
        results.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: total) { i in
                var frame = self.probeStill(urls[i])
                frame.pairedJpegURL = scanResult.jpegPairs[urls[i]]
                lock.lock()
                base[i] = frame
                done += 1
                let count = done
                lock.unlock()
                if count % 64 == 0 || count == total { progress?(count, total) }
            }
        }
        let frames = results.compactMap { $0 }
        let groups = BurstGrouper.group(frames, gapThreshold: gapThreshold)
        let floor = max(1, minBurstCount)
        let base = folder.deletingPathExtension().lastPathComponent
        var shots: [BurstShot] = []
        var singles: [StillFrame] = []
        for group in groups {
            if group.count >= floor {
                shots.append(BurstShot(name: String(format: "%@_S%03d", base, shots.count + 1), frames: group))
            } else {
                singles.append(contentsOf: group)
            }
        }
        return IngestResult(shots: shots, singles: singles, videos: scanResult.videos)
    }

    /// EXIF "yyyy:MM:dd HH:mm:ss" in the local timezone. EXIF carries no
    /// timezone; bursts are internally consistent, which is all grouping
    /// and cadence need.
    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Still decode

/// Orientation-corrected decodes of a still at arbitrary target sizes.
/// ImageIO picks embedded RAW/JPEG previews for small targets (fast skim
/// path) and falls back to a full decode for large ones.
public enum StillDecoder {
    /// Decode with EXIF orientation applied, longest edge ≤ `maxPixel`
    /// (pass a value ≥ the native long edge for a full-resolution decode).
    public static func decode(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Fast preview decode preferring an embedded thumbnail when one is
    /// large enough — RAW files carry full-scene JPEG previews, so skimming
    /// large RAWs never pays a RAW develop.
    public static func preview(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
