import simd
import KineCore

/// Color-management math: derive the linear RGB→RGB matrix that converts a
/// camera's native gamut into the Rec.709 working primaries. Computed from
/// published chromaticity primaries (stable, authoritative) rather than
/// pre-baked matrices. All listed gamuts use a D65 white point, so a plain
/// primaries concatenation is exact — no chromatic adaptation needed.
enum ColorScience {

    struct Primaries {
        let r: SIMD2<Float>, g: SIMD2<Float>, b: SIMD2<Float>, w: SIMD2<Float>
    }

    static let d65 = SIMD2<Float>(0.31271, 0.32902)

    static let rec709      = Primaries(r: SIMD2(0.640, 0.330), g: SIMD2(0.300, 0.600), b: SIMD2(0.150, 0.060), w: d65)
    static let rec2020     = Primaries(r: SIMD2(0.708, 0.292), g: SIMD2(0.170, 0.797), b: SIMD2(0.131, 0.046), w: d65)
    static let arriWG3     = Primaries(r: SIMD2(0.6840, 0.3130), g: SIMD2(0.2210, 0.8480), b: SIMD2(0.0861, -0.1020), w: d65)
    static let sGamut3Cine = Primaries(r: SIMD2(0.766, 0.275), g: SIMD2(0.225, 0.800), b: SIMD2(0.089, -0.087), w: d65)
    static let cinemaGamut = Primaries(r: SIMD2(0.740, 0.270), g: SIMD2(0.170, 1.140), b: SIMD2(0.080, -0.100), w: d65)
    static let vGamut      = Primaries(r: SIMD2(0.730, 0.280), g: SIMD2(0.165, 0.840), b: SIMD2(0.100, -0.030), w: d65)

    /// RGB→XYZ for a set of primaries (the standard derivation).
    static func rgbToXYZ(_ p: Primaries) -> simd_float3x3 {
        func xyz(_ c: SIMD2<Float>) -> SIMD3<Float> {
            SIMD3(c.x / c.y, 1, (1 - c.x - c.y) / c.y)
        }
        let Xr = xyz(p.r), Xg = xyz(p.g), Xb = xyz(p.b)
        let M = simd_float3x3(columns: (Xr, Xg, Xb))
        let S = simd_inverse(M) * xyz(p.w)
        return simd_float3x3(columns: (Xr * S.x, Xg * S.y, Xb * S.z))
    }

    static func primaries(for space: ColorTransferSpace) -> Primaries {
        switch space {
        case .rec709, .sRGB, .linear:    return rec709
        case .rec2020:                   return rec2020
        case .arriLogC3:                 return arriWG3
        case .sonySLog3:                 return sGamut3Cine
        case .canonCLog3, .canonCLog2:   return cinemaGamut
        case .panasonicVLog:             return vGamut
        }
    }

    /// Linear camera-gamut RGB → linear Rec.709 RGB. Identity for spaces
    /// already on Rec.709 primaries.
    static func cameraToRec709(_ space: ColorTransferSpace) -> simd_float3x3 {
        switch space {
        case .rec709, .sRGB, .linear:
            return matrix_identity_float3x3
        default:
            return simd_inverse(rgbToXYZ(rec709)) * rgbToXYZ(primaries(for: space))
        }
    }

    /// Cached per-space matrix rows (each as SIMD4, .xyz used) so the
    /// compositor can pack them into shader uniforms and apply
    /// `out = (dot(row0,c), dot(row1,c), dot(row2,c))`.
    static func gamutRows(_ space: ColorTransferSpace) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        if let cached = cache[space] { return cached }
        let m = cameraToRec709(space)
        // simd is column-major; row i = (col0[i], col1[i], col2[i]).
        let r0 = SIMD4<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x, 0)
        let r1 = SIMD4<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y, 0)
        let r2 = SIMD4<Float>(m.columns.0.z, m.columns.1.z, m.columns.2.z, 0)
        let rows = (r0, r1, r2)
        cache[space] = rows
        return rows
    }

    private static var cache: [ColorTransferSpace: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)] = [:]
}
