import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Decoded previews written to disk as JPEGs, keyed by source identity
/// (path + size + mtime) and decode tier. A 24MP develop happens ONCE per
/// frame per tier - ever; every later request, including after relaunch,
/// is a small JPEG read. This is how the pro apps keep preview generation
/// from owning the machine.
public enum PreviewDiskCache {

    private static let schemaVersion = 1

    public static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kinestasis", isDirectory: true)
            .appendingPathComponent("previews-v\(schemaVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Cache key: source identity + tier. mtime + size in the hash means
    /// an edited/replaced source file misses cleanly.
    static func key(for url: URL, maxPixel: Int) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = attrs[.size] as? Int else { return nil }
        let seed = "\(url.path)|\(size)|\(mtime)|\(maxPixel)"
        let digest = Insecure.SHA1.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func load(url: URL, maxPixel: Int) -> CGImage? {
        guard let key = key(for: url, maxPixel: maxPixel) else { return nil }
        let file = directory.appendingPathComponent("\(key).jpg")
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    public static func store(_ image: CGImage, url: URL, maxPixel: Int) {
        guard let key = key(for: url, maxPixel: maxPixel) else { return }
        let file = directory.appendingPathComponent("\(key).jpg")
        guard !FileManager.default.fileExists(atPath: file.path),
              let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Keep the cache under ~20 GB, oldest files first. Called once per
    /// launch from a background task.
    public static func sweep(maxBytes: Int64 = 20_000_000_000) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for f in files {
            let values = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((f, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= maxBytes { break }
        }
    }
}
