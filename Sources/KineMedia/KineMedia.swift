import Foundation
import AVFoundation
@_exported import KineCore

/// KineMedia owns everything related to reading and writing media files:
/// metadata probing, VideoToolbox session management, proxy transcode,
/// thumbnail/waveform generation.
///
/// Public surface lands in M1 (`MediaProber` for ingest) and M2
/// (`VTSessionPool`, `ProxyManager`). Today this file exists so the module
/// has a TU; we'll fill it in as milestones land.
public enum KineMedia {
    public static let version = "0.1.0-m1-scaffold"
}
