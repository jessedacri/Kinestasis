import Foundation
import Metal

/// Parses a `.cube` LUT file (Adobe spec) and uploads it to a
/// Metal 3D texture the `PPEMetalRenderer` can sample in its
/// fragment shader. Supports 3D LUTs; 1D LUTs are intentionally
/// rejected — most production LUTs for on-set monitoring are
/// 3D (`LUT_3D_SIZE` 17, 25, or 33).
///
/// **.cube format** (Adobe Cube LUT spec):
/// ```
/// # Optional comments
/// TITLE "My LUT"
/// LUT_3D_SIZE 33
/// DOMAIN_MIN 0.0 0.0 0.0
/// DOMAIN_MAX 1.0 1.0 1.0
/// 0.000 0.000 0.000
/// 0.031 0.000 0.000
/// ...
/// ```
/// Data order: red varies fastest, then green, then blue.
/// For size N, expect N³ rows of `r g b` floats.
///
/// **Why a 3D texture.** Once uploaded, the fragment shader
/// does a single `texture3D.sample()` call per pixel with
/// hardware trilinear interpolation — effectively zero cost on
/// Apple Silicon. Parsing + upload happens on the main thread
/// on LUT-change; playback itself never touches the parser.
public enum PPELUTLoader {
    public enum LoadError: LocalizedError {
        case fileUnreadable(String)
        case malformedSizeLine
        case unsupportedSize(Int)
        case truncatedData(expected: Int, got: Int)
        case textureCreationFailed
        case notA3DLUT

        public var errorDescription: String? {
            switch self {
            case .fileUnreadable(let s): return "Cannot read LUT file: \(s)"
            case .malformedSizeLine: return "LUT file missing LUT_3D_SIZE declaration"
            case .unsupportedSize(let n): return "LUT size \(n) not supported (expected 2-64)"
            case .truncatedData(let e, let g): return "LUT has \(g) entries, expected \(e)"
            case .textureCreationFailed: return "Metal 3D texture allocation failed"
            case .notA3DLUT: return "Only 3D LUTs are supported (1D LUT found)"
            }
        }
    }

    /// Parsed + GPU-resident LUT, ready to bind in a render
    /// encoder. The Metal texture uses `rgba32Float` — 4-channel
    /// alignment even though LUTs are RGB-only, because Metal
    /// 3D textures don't support 3-channel formats. The alpha
    /// channel gets filled with 1.0.
    public struct LoadedLUT {
        public let size: Int
        public let texture: MTLTexture
        /// The source URL so the UI can show "LUT: example.cube".
        public let sourceURL: URL

        public init(size: Int, texture: MTLTexture, sourceURL: URL) {
            self.size = size
            self.texture = texture
            self.sourceURL = sourceURL
        }
    }

    /// Load a `.cube` file and upload it to a Metal 3D texture
    /// on the given device. Throws on parse / I/O / allocation
    /// errors.
    public static func load(url: URL, device: MTLDevice) throws -> LoadedLUT {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LoadError.fileUnreadable(error.localizedDescription)
        }

        var size: Int = 0
        var minValues: (Float, Float, Float) = (0, 0, 0)
        var maxValues: (Float, Float, Float) = (1, 1, 1)
        var data: [Float] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip comments and trim whitespace. Empty or
            // comment-only lines after stripping → skip.
            var line = String(rawLine)
            if let hashIdx = line.firstIndex(of: "#") {
                line = String(line[..<hashIdx])
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // Directives that begin with an uppercase keyword:
            // LUT_3D_SIZE, LUT_1D_SIZE, DOMAIN_MIN, DOMAIN_MAX,
            // TITLE. Case-insensitive match for robustness.
            let upper = line.uppercased()
            if upper.hasPrefix("LUT_1D_SIZE") {
                throw LoadError.notA3DLUT
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, let n = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                    throw LoadError.malformedSizeLine
                }
                size = n
                continue
            }
            if upper.hasPrefix("DOMAIN_MIN") {
                let triple = parseTriple(after: line, keyword: "DOMAIN_MIN")
                if let t = triple { minValues = t }
                continue
            }
            if upper.hasPrefix("DOMAIN_MAX") {
                let triple = parseTriple(after: line, keyword: "DOMAIN_MAX")
                if let t = triple { maxValues = t }
                continue
            }
            if upper.hasPrefix("TITLE") {
                continue
            }
            // Otherwise this is a data row: three floats.
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count == 3,
                  let r = Float(tokens[0]),
                  let g = Float(tokens[1]),
                  let b = Float(tokens[2]) else {
                // Skip malformed lines rather than abort — some
                // LUT exports pad with stray whitespace or blank
                // lines in the middle of the data block.
                continue
            }
            data.append(r)
            data.append(g)
            data.append(b)
            data.append(1.0) // alpha filler for rgba32Float texture
        }

        guard size >= 2, size <= 64 else {
            throw LoadError.unsupportedSize(size)
        }
        let expectedSamples = size * size * size
        let actualSamples = data.count / 4
        guard actualSamples == expectedSamples else {
            throw LoadError.truncatedData(expected: expectedSamples, got: actualSamples)
        }

        // Normalize to [0, 1] if the LUT declares a non-unit
        // domain. `(sample - min) / (max - min)`. The shader
        // still samples the texture in [0, 1] — the domain
        // normalization baked into the texture is the cheapest
        // path since it avoids a per-pixel uniform lookup.
        let span: (Float, Float, Float) = (
            maxValues.0 - minValues.0,
            maxValues.1 - minValues.1,
            maxValues.2 - minValues.2
        )
        if minValues != (0, 0, 0) || maxValues != (1, 1, 1) {
            var i = 0
            while i < data.count {
                if span.0 > 0 { data[i] = (data[i] - minValues.0) / span.0 }
                if span.1 > 0 { data[i + 1] = (data[i + 1] - minValues.1) / span.1 }
                if span.2 > 0 { data[i + 2] = (data[i + 2] - minValues.2) / span.2 }
                i += 4
            }
        }

        // Allocate the Metal 3D texture + upload the pixel data.
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw LoadError.textureCreationFailed
        }
        texture.label = "LUT3D:\(url.lastPathComponent)"
        let bytesPerRow = size * MemoryLayout<Float>.size * 4
        let bytesPerImage = bytesPerRow * size
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: size, height: size, depth: size)
        )
        data.withUnsafeBufferPointer { buf in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                slice: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        return LoadedLUT(size: size, texture: texture, sourceURL: url)
    }

    private static func parseTriple(after line: String, keyword: String) -> (Float, Float, Float)? {
        let stripped = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
        let tokens = stripped.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count == 3,
              let a = Float(tokens[0]),
              let b = Float(tokens[1]),
              let c = Float(tokens[2]) else { return nil }
        return (a, b, c)
    }
}
