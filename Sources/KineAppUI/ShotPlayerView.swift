import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit
import KineCore
import KineMedia

/// The shot player: live-graded frame, transport bar, trim controls, mark
/// star, kept-range strip. One implementation shared by the inspector and
/// the fullscreen processing view. Follows `workspace.previewShot` (hover
/// skim wins, else the selection).
struct ShotPlayerView: View {
    @ObservedObject var workspace: WorkspaceModel
    /// Fullscreen processing view: let the picture take all the space.
    var large = false

    var body: some View {
        let shot = workspace.previewShot
        VStack(spacing: 0) {
            PlayerFrameHost(workspace: workspace, transport: workspace.shotTransport)
                .frame(minHeight: large ? 280 : 160, idealHeight: large ? nil : 240,
                       maxHeight: large ? .infinity : nil)
                .contentShape(Rectangle())
                .onTapGesture { workspace.toggleShotPlayback() }

            if let shot {
                transportBar(shot)
                trimStrip(shot)
            }
        }
    }

    private func transportBar(_ shot: BurstShot) -> some View {
        let total = max(1, ShotTimingEngine.totalFrames(workspace.scheduleForPreviewShot()))
        return HStack(spacing: 8) {
            playPauseButton
            TransportFrameCounter(transport: workspace.shotTransport, total: total)
            TransportScrub(workspace: workspace, transport: workspace.shotTransport, total: total)
            durationLabel(total: total)
            Divider().frame(height: 12)
            trimButtons(shot)
            TransportMarkControls(workspace: workspace, transport: workspace.shotTransport)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(KineTheme.bgPanel)
    }

    private var playPauseButton: some View {
        Button {
            workspace.toggleShotPlayback()
        } label: {
            Image(systemName: workspace.shotPlayRate != 0 ? "pause.fill" : "play.fill")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
    }

    private func durationLabel(total: Int64) -> some View {
        Text(String(format: "%.1fs", Double(total) / workspace.shotFrameRate.fps))
            .font(KineTheme.monoSmall)
            .foregroundStyle(KineTheme.textMuted)
    }

    @ViewBuilder private func trimButtons(_ shot: BurstShot) -> some View {
        Button("I") { workspace.setShotTrimInAtPlayhead() }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(KineTheme.accent)
            .help("Trim head to this still (key: I)")
        Button("O") { workspace.setShotTrimOutAtPlayhead() }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(KineTheme.accent)
            .help("Trim tail to this still (key: O)")
        if shot.isTrimmed {
            Text("\(shot.effectiveFrames.count)/\(shot.frames.count)")
                .font(KineTheme.monoSmall)
                .foregroundStyle(KineTheme.textMuted)
            Button {
                workspace.clearShotTrim()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .help("Clear trim (key: I+O together)")
        }
    }

    /// Where the kept range sits inside the full shot: dark ends are
    /// trimmed off and never play in the loop.
    @ViewBuilder private func trimStrip(_ shot: BurstShot) -> some View {
        if shot.isTrimmed, !shot.frames.isEmpty {
            GeometryReader { geo in
                let n = CGFloat(shot.frames.count)
                let x0 = CGFloat(shot.trimIn) / n * geo.size.width
                let x1 = CGFloat(shot.frames.count - shot.trimOut) / n * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.5))
                    Capsule().fill(KineTheme.accent.opacity(0.85))
                        .frame(width: max(2, x1 - x0))
                        .offset(x: x0)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .background(KineTheme.bgPanel)
            .help("Kept range inside the full shot. Dark ends are trimmed off and do not play.")
        }
    }

}


/// Layer-backed frame display: swapping the image only touches
/// CALayer.contents, never SwiftUI/AppKit layout. SwiftUI's Image treats
/// per-frame pixel-dimension jitter (2560x1706 vs x1707) as an intrinsic
/// size change and relayouts the whole window at playback rate - that was
/// the Develop-mode pinwheel.
struct FrameLayerView: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> LayerView { LayerView() }

    func updateNSView(_ view: LayerView, context: Context) {
        view.show(image)
    }

    final class LayerView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.minificationFilter = .trilinear
            layer?.magnificationFilter = .linear
        }

        required init?(coder: NSCoder) { nil }

        func show(_ image: CGImage?) {
            // Kill the implicit contents fade: at playback rate the
            // default 0.25s animation stacks into a continuous animation
            // stream that drives full-window layout every frame.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layer?.contentsScale = window?.backingScaleFactor ?? 2
        }
    }
}


/// The playback frame pipeline lives OUTSIDE SwiftUI: a render pump
/// subscribes to the transport and preview ticker directly and writes
/// finished frames straight into a CALayer. A playback tick therefore
/// touches zero SwiftUI state - per-tick @State swaps were dragging the
/// whole window through AppKit layout at frame rate no matter how small
/// the observing view was.
private struct PlayerFrameHost: View {
    @ObservedObject var workspace: WorkspaceModel
    let transport: WorkspaceModel.ShotTransport

    var body: some View {
        ZStack {
            Color.black
            PlayerFrameSurface(workspace: workspace)
            ShuttleBadge(transport: transport)
        }
    }
}

/// Observes ONLY the play rate (via onReceive + removeDuplicates, no
/// ObservedObject - that would tick per frame).
private struct ShuttleBadge: View {
    let transport: WorkspaceModel.ShotTransport
    @State private var rate: Double = 0

    var body: some View {
        Group {
            if rate != 0 {
                VStack {
                    HStack {
                        Spacer()
                        Text((rate < 0 ? "\u{25C0} " : "\u{25B6} ") + (abs(rate) == 1 ? "1x" : String(format: "%gx", abs(rate))))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                            .clipShape(Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .onReceive(transport.$playRate.removeDuplicates()) { rate = $0 }
    }
}

private struct PlayerFrameSurface: NSViewRepresentable {
    let workspace: WorkspaceModel

    func makeCoordinator() -> RenderPump { RenderPump(workspace: workspace) }

    func makeNSView(context: Context) -> FrameSurfaceView {
        let view = FrameSurfaceView()
        context.coordinator.attach(view)
        view.onTap = { [weak workspace] in workspace?.toggleShotPlayback() }
        view.dragPayload = { [weak workspace] in
            guard let workspace, let current = workspace.currentShotFrame() else { return nil }
            let url = current.shot.sourceURL(for: current.frame)
            let stem = url.deletingPathExtension().lastPathComponent
            return FrameDragPayload(sourceURL: url, grade: current.shot.grade,
                                    suggestedName: "\(current.shot.name)_\(stem).jpg")
        }
        return view
    }

    func updateNSView(_ view: FrameSurfaceView, context: Context) {}
}

/// Snapshot taken at drag start, so the promised file matches the frame
/// the user grabbed even if playback moves on.
struct FrameDragPayload {
    let sourceURL: URL
    let grade: ShotGrade
    let suggestedName: String
}

/// Layer-backed frame display: image swaps only touch CALayer.contents,
/// never layout, and never animate implicitly. Also a drag source: drag
/// the frame out and the receiver (Finder, Messages, Mail, an app icon)
/// gets a FULL-RESOLUTION graded JPEG via a file promise, rendered
/// through the same develop path as stills export.
final class FrameSurfaceView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var onTap: (() -> Void)?
    var dragPayload: (() -> FrameDragPayload?)?

    private var mouseDownPoint: NSPoint?
    private var promisedPayload: FrameDragPayload?
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: - Click to play, drag to export

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownPoint != nil { onTap?() }
        mouseDownPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let distance = hypot(event.locationInWindow.x - start.x,
                             event.locationInWindow.y - start.y)
        guard distance > 5, let payload = dragPayload?() else { return }
        mouseDownPoint = nil
        promisedPayload = payload

        let provider = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let thumb = dragThumbnail()
        let size = NSSize(width: 160, height: 160 * (thumb.map { CGFloat($0.height) / CGFloat(max(1, $0.width)) } ?? 0.66))
        let origin = convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: origin.x - size.width / 2, y: origin.y - size.height / 2,
                           width: size.width, height: size.height)
        let image = thumb.map { NSImage(cgImage: $0, size: size) } ?? NSImage(size: size)
        item.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func dragThumbnail() -> CGImage? {
        guard let contents = layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promisedPayload?.suggestedName ?? "Kinestasis Frame.jpg"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let payload = promisedPayload else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        // Full-resolution graded develop - identical to stills export.
        guard let image = ShotGradeRenderer().render(url: payload.sourceURL,
                                                     grade: payload.grade,
                                                     maxPixel: 100_000) else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        do {
            try StillExporter.writeJPEG(image, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// Drives the surface from Combine subscriptions; one grade render in
/// flight, latest-wins. One shared renderer (one CIContext) app-wide.
@MainActor final class RenderPump {
    private let workspace: WorkspaceModel
    private weak var surface: FrameSurfaceView?
    private var subs: Set<AnyCancellable> = []
    private var inFlight = false
    private var queued = false
    private var generation = 0
    private var lastShownURL: URL?
    private static let renderer = ShotGradeRenderer()

    nonisolated init(workspace: WorkspaceModel) {
        self.workspace = workspace
        Task { @MainActor in self.subscribe() }
    }

    private func subscribe() {
        // Async main delivery: @Published emits on willSet, so read the
        // model one runloop later, after the value actually lands.
        workspace.shotTransport.$playheadFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subs)
        workspace.previewTicker.$version
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subs)
        workspace.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subs)
    }

    func attach(_ view: FrameSurfaceView) {
        surface = view
        render()
    }

    private func render() {
        guard let shot = workspace.previewShot,
              let url = workspace.currentShotFrameURL() else {
            lastShownURL = nil
            surface?.show(nil)
            return
        }
        if workspace.shotPlayRate == 0 { workspace.scheduleRefinedFrame() }
        workspace.requestPreviewFrame(url)
        guard let base = workspace.cachedRefinedFrame(url) ?? workspace.cachedPreviewFrame(url) else {
            return   // ticker fires again when the decode lands
        }
        let grade = shot.grade
        let seed = workspace.shotPlayheadFrame
        if grade.isIdentity, lastShownURL != url || seed == 0 {
            // Ungraded: skip the CI hop entirely.
            lastShownURL = url
            surface?.show(base)
            return
        }
        if inFlight {
            queued = true
            return
        }
        inFlight = true
        generation += 1
        let gen = generation
        let ev = ExposureWobble.evOffset(
            outputFrame: seed, fps: workspace.shotFrameRate.fps,
            intensity: grade.wobbleIntensity, rate: grade.wobbleRate)
        Task.detached(priority: .userInitiated) {
            let image = Self.renderer.gradePreview(base, grade: grade, evOffset: ev, grainSeed: seed) ?? base
            await MainActor.run {
                self.inFlight = false
                if gen == self.generation {
                    self.lastShownURL = url
                    self.surface?.show(image)
                }
                if self.queued {
                    self.queued = false
                    self.render()
                }
            }
        }
    }
}

private struct TransportFrameCounter: View {
    @ObservedObject var transport: WorkspaceModel.ShotTransport
    let total: Int64

    var body: some View {
        Text(String(format: "%d / %d", transport.playheadFrame + 1, total))
            .font(KineTheme.monoSmall)
            .foregroundStyle(KineTheme.textMuted)
            .frame(width: 74, alignment: .leading)
    }
}

private struct TransportScrub: View {
    let workspace: WorkspaceModel
    @ObservedObject var transport: WorkspaceModel.ShotTransport
    let total: Int64

    var body: some View {
        PlayerScrubBar(
            fraction: Binding(
                get: { Double(transport.playheadFrame) / Double(max(1, total - 1)) },
                set: { f in
                    workspace.shotStop()
                    workspace.shotPlayheadFrame = Int64((f * Double(total - 1)).rounded())
                }
            )
        )
    }
}

private struct TransportMarkControls: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var transport: WorkspaceModel.ShotTransport

    var body: some View {
        if let current = workspace.currentShotFrame() {
            let marked = current.shot.markedStillIDs.contains(current.frame.id)
            Divider().frame(height: 12)
            Button {
                workspace.toggleStillMark(current.frame.id, in: current.shot.id)
            } label: {
                Image(systemName: marked ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(marked ? KineTheme.accent : KineTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Mark this still for export (key: M)")
            if current.shot.markedStillIDs.count > 0 {
                Text("\(current.shot.markedStillIDs.count)")
                    .font(KineTheme.monoSmall)
                    .foregroundStyle(KineTheme.textMuted)
            }
        }
    }
}
