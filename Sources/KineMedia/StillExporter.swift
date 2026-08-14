import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import KineCore

/// Writes a shot's marked stills for delivery: the graded develop as a
/// full-resolution JPEG, optionally the untouched source file and the RAW.
public enum StillExporter {

    public struct Options: Sendable {
        public var includeOriginals: Bool
        public var includeRaw: Bool
        public init(includeOriginals: Bool = false, includeRaw: Bool = false) {
            self.includeOriginals = includeOriginals
            self.includeRaw = includeRaw
        }
    }

    public enum StillError: LocalizedError {
        case developFailed(URL)
        case writeFailed(URL)
        public var errorDescription: String? {
            switch self {
            case .developFailed(let url): return "could not develop \(url.lastPathComponent)"
            case .writeFailed(let url): return "could not write \(url.lastPathComponent)"
            }
        }
    }

    private static let rawExtensions: Set<String> = [
        "raf", "arw", "cr2", "cr3", "crw", "nef", "nrw", "orf", "rw2",
        "pef", "srw", "erf", "rwl", "3fr", "fff", "iiq", "dng",
    ]

    /// Export one marked still into `directory`. Never overwrites: names
    /// that collide get a numbered suffix. Returns the files written.
    @discardableResult
    public static func export(frame: StillFrame, of shot: BurstShot,
                              to directory: URL, options: Options) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        let source = shot.sourceURL(for: frame)
        let stem = "\(shot.name)_\(source.deletingPathExtension().lastPathComponent)"

        let graded = ShotGradeRenderer().render(url: source, grade: shot.grade, maxPixel: 100_000)
        guard let graded else { throw StillError.developFailed(source) }
        let jpegURL = freeURL(directory.appendingPathComponent("\(stem).jpg"))
        try writeJPEG(graded, to: jpegURL)
        written.append(jpegURL)

        if options.includeOriginals {
            let dest = freeURL(directory.appendingPathComponent("\(stem)_original.\(source.pathExtension)"))
            try FileManager.default.copyItem(at: source, to: dest)
            written.append(dest)
        }
        if options.includeRaw, rawExtensions.contains(frame.url.pathExtension.lowercased()),
           frame.url != source || !options.includeOriginals {
            let dest = freeURL(directory.appendingPathComponent(
                "\(stem).\(frame.url.pathExtension)"))
            try FileManager.default.copyItem(at: frame.url, to: dest)
            written.append(dest)
        }
        return written
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.93) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw StillError.writeFailed(url)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw StillError.writeFailed(url) }
    }

    private static func freeURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
