import Foundation
import Metal
@_exported import KineCore

/// KineRender hosts the Metal compositor + render graph. M1 only needs
/// "give me a Metal device + texture cache" — that lives here. The full
/// render graph (RenderGraph, EffectNode, fused-pass compilation) lands
/// in M3 when transforms and opacity arrive.
public enum KineRender {
    /// One device per process. Apple Silicon has one GPU; UMA makes
    /// multi-device coordination meaningless.
    public static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
}
