import Foundation
import ImageIO
import KineCore

/// On-demand EXIF display fields for the adjust panel — read live from
/// the file (cheap, metadata-only), never stored in the project.
public enum ExifReader {

    public struct Field: Identifiable, Sendable, Equatable {
        public let id: String
        public let value: String
        public var label: String { id }
    }

    public static func read(url: URL) -> [Field] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return []
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        var out: [Field] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { out.append(Field(id: label, value: value)) }
        }

        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        add("Camera", [make, model].compactMap { $0 }.joined(separator: " "))
        add("Lens", exif[kCGImagePropertyExifLensModel] as? String)

        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            add("Shutter", t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))")
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double {
            add("Aperture", String(format: "ƒ/%.1f", f))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first {
            add("ISO", "\(iso)")
        }
        if let mm = exif[kCGImagePropertyExifFocalLength] as? Double {
            var s = String(format: "%.0f mm", mm)
            if let eq = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double, abs(eq - mm) > 1 {
                s += String(format: " (%.0f mm eq.)", eq)
            }
            add("Focal length", s)
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            add("Exp. comp", String(format: "%+.1f EV", bias))
        }
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            add("Dimensions", "\(w) × \(h)")
        }
        add("Captured", exif[kCGImagePropertyExifDateTimeOriginal] as? String)
        add("File", url.lastPathComponent)
        if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            add("Size", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return out
    }
}
