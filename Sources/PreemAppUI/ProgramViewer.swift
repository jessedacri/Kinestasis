import SwiftUI
import AppKit
import AVFoundation
import PreemCore
import PreemMedia
import PolymergeMediaModel
import PolymergePlayback

/// Right-side viewer that shows whichever `PlacedClip` is under the
/// timeline playhead. Driven by `workspace.playheadTime` +
/// `workspace.activeSequence`. Renders via PolymergePlayback's PPE
/// pipeline so audio and video share one clock (the audio engine's
/// `currentAudibleSeconds`) and can't drift.
struct ProgramViewer: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Program")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(workspace.focusedViewer == .program ? Color.accentColor : Color.secondary)
                if workspace.focusedViewer == .program {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                Spacer()
                // Drop-warning chip lives in the header. The HStack is
                // fixed-height (see `.frame(height:)` below) so the
                // chip can come and go without shifting the picture.
                if workspace.realtimeIsDropping {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("Dropping frames · Render In to Out for smooth playback")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.12))
                    )
                }
                if let progress = workspace.renderProgress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        Text("Rendering \(Int(progress * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if let spec = sequenceSpec {
                    Text(spec)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("|")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                Text(formattedTimecode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if workspace.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 10)
            // Fixed header height — the drop chip insertion/removal
            // never shifts the program content below.
            .frame(height: 28)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ZStack {
                Color.black
                switch frameAtPlayhead {
                case .video:
                    // Unified realtime compositor — runs the same
                    // OfflineSequenceCompositor path the encoder uses,
                    // so realtime ≡ render by construction.
                    RealtimeProgramHostView(workspace: workspace)
                    // Direct-manipulation overlay: when a clip is
                    // selected and visible at the playhead, the user
                    // can drag the picture to move it or drag a corner
                    // to scale it.
                    ProgramTransformOverlay(workspace: workspace)
                case .audioOnly:
                    VStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Audio-only")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                case .empty:
                    Text(workspace.activeSequence == nil ? "No sequence" : "No clip under playhead")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 200, minHeight: 160)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusedViewer = .program
        }
    }

    private var formattedTimecode: String {
        let t = workspace.playheadTime.seconds
        let frameRate = workspace.activeSequence?.settings.frameRate ?? .thirty
        return Timecode.format(seconds: t, frameRate: frameRate)
    }

    /// Sequence spec string in the form "3840x2160 23.976" so the user
    /// always sees the active sequence's resolution + frame rate next
    /// to the playhead readout. Returns nil when no sequence is active.
    private var sequenceSpec: String? {
        guard let seq = workspace.activeSequence else { return nil }
        let res = seq.settings.resolution
        let fr = seq.settings.frameRate.rawValue
        return "\(res.width)x\(res.height) \(fr)"
    }

    private enum FrameAtPlayhead { case video, audioOnly, empty }

    private var frameAtPlayhead: FrameAtPlayhead {
        guard let sequence = workspace.activeSequence else { return .empty }
        for track in sequence.videoTracks {
            if track.clips.contains(where: { $0.timelineRange.contains(workspace.playheadTime) }) {
                return .video
            }
        }
        for track in sequence.audioTracks {
            if track.clips.contains(where: { $0.timelineRange.contains(workspace.playheadTime) }) {
                return .audioOnly
            }
        }
        return .empty
    }
}

/// NSView that hosts PPE's `CAMetalLayer` as its backing layer.
final class PPEHostView: NSView {
    private var metalLayer: CAMetalLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func attach(renderer: PPEMetalRenderer) {
        guard metalLayer !== renderer.layer else { return }
        metalLayer = renderer.layer
        renderer.layer.frame = bounds
        renderer.layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        // PPE now configures `presentsWithTransaction = true` +
        // `isOpaque = false` at init time so its CAMetalLayer
        // composites through CA's transaction system — the dual-PPE
        // cross-dissolve in ProgramViewer alpha-blends correctly.
        layer?.addSublayer(renderer.layer)
    }

    override func layout() {
        super.layout()
        if let metalLayer {
            metalLayer.frame = bounds
            metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        }
    }
}
