import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KineCore
import KineMedia
import KineRender
import KineEffects
import KineTimelineUI

public extension Notification.Name {
    static let kineExportFCPXML = Notification.Name("kine.export.fcpxml")
    static let kineNewSequence  = Notification.Name("kine.sequence.new")
    static let kineNewProject   = Notification.Name("kine.project.new")
    static let kineOpenProject  = Notification.Name("kine.project.open")
    static let kineSave         = Notification.Name("kine.project.save")
    static let kineSaveAs       = Notification.Name("kine.project.saveAs")
    static let kineAddVideoTrack = Notification.Name("kine.track.addVideo")
    static let kineAddAudioTrack = Notification.Name("kine.track.addAudio")
    static let kineRenderInToOut = Notification.Name("kine.render.inToOut")
    static let kineExportSequence = Notification.Name("kine.export.sequence")
    static let kineShowEffectControls = Notification.Name("kine.effects.show")
    static let kineShowAbout = Notification.Name("kine.about.show")
}

public struct KineRootView: View {
    @StateObject private var workspace = WorkspaceModel()
    @State private var keyMonitor: Any?
    /// Currently-held transport keys, for chords: I+O clears the trim,
    /// K+L steps a frame forward, J+K steps a frame back.
    @State private var heldChordKeys = HeldChordKeys()
    @State private var showingAbout = false

    public init() {}

    public var body: some View {
        content
            .navigationTitle("\(workspace.project.name)\(workspace.isDirty ? " (edited)" : "")")
            // Video editors expect a dark UI all the time, regardless
            // of the system appearance. Forcing dark keeps the bin +
            // toolbar from washing out against the dark timeline.
            .preferredColorScheme(.dark)
            // Brand accent (amber) drives every SwiftUI control's tint —
            // buttons, pickers, segmented controls, toggles. Polymerge family.
            .tint(KineTheme.accent)
            .background(KineTheme.bg)
    }

    private var splitLayout: some View {
        KineSplitView(
            isVertical: true,                                    // vertical divider → horizontal stack
            autosaveName: "kine.root.binVsMain",
            firstSpec: KinePaneSpec(minThickness: 180, maxThickness: 360, holdingPriority: 260),
            secondSpec: KinePaneSpec(minThickness: 600, holdingPriority: 240),
            initialFirstThickness: 240,
            first: {
                BinBrowserView(workspace: workspace)
                    .focusBorder(workspace.focusedViewer == .bin)
            },
            second: {
                KineSplitView(
                    isVertical: false,                            // horizontal divider → vertical stack
                    autosaveName: "kine.root.viewersVsTimeline",
                    firstSpec: KinePaneSpec(minThickness: 200, maxThickness: 480, holdingPriority: 260),
                    secondSpec: KinePaneSpec(minThickness: 240, holdingPriority: 240),
                    initialFirstThickness: 320,
                    first: {
                        KineSplitView(
                            isVertical: true,                     // source | program
                            autosaveName: "kine.viewers.sourceVsProgram",
                            firstSpec: KinePaneSpec(minThickness: 240, holdingPriority: 250),
                            secondSpec: KinePaneSpec(minThickness: 240, holdingPriority: 250),
                            initialFirstThickness: 520,
                            first: {
                                ViewerPane(title: "Source", clip: workspace.sourceClip, workspace: workspace)
                                    .focusBorder(workspace.focusedViewer == .source)
                            },
                            second: {
                                ProgramViewer(workspace: workspace)
                                    .focusBorder(workspace.focusedViewer == .program)
                            }
                        )
                    },
                    second: {
                        TimelineWithZoomBar(workspace: workspace)
                            .focusBorder(workspace.focusedViewer == .timeline)
                    }
                )
            }
        )
    }

    /// One view strip for the whole app: VIEW | Bin, Develop, Assemble.
    /// Bin and Develop are the Kinestasis flow; Assemble is the inherited
    /// timeline.
    private var modeBar: some View {
        HStack(spacing: 0) {
            Text("VIEW")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
            viewTab("Bin", active: workspace.appMode == .shots && workspace.shotsViewMode == .bin) {
                workspace.appMode = .shots
                workspace.shotsViewMode = .bin
            }
            viewTab("Develop", active: workspace.appMode == .shots && workspace.shotsViewMode == .develop) {
                workspace.appMode = .shots
                workspace.shotsViewMode = .develop
            }
            viewTab("Assemble", active: workspace.appMode == .assemble) {
                workspace.appMode = .assemble
            }
            Spacer()
        }
        .background(KineTheme.bgPanel)
    }

    private func viewTab(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Color.white : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(active ? KineTheme.accent : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    private var content: some View {
        Group {
            if workspace.programFullscreen {
                ProgramViewer(workspace: workspace)
            } else {
                VStack(spacing: 0) {
                    modeBar
                    Divider()
                    switch workspace.appMode {
                    case .shots:    ShotsWorkspaceView(workspace: workspace)
                    case .assemble: splitLayout
                    }
                }
            }
        }
        .frame(minWidth: 1200, minHeight: 800)
        .onReceive(NotificationCenter.default.publisher(for: .kineExportFCPXML)) { _ in
            exportFCPXML()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineNewSequence)) { _ in
            workspace.showingNewSequenceSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineNewProject)) { _ in
            workspace.newProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineOpenProject)) { _ in
            workspace.openProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineSave)) { _ in
            workspace.save()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineSaveAs)) { _ in
            workspace.saveAs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineAddVideoTrack)) { _ in
            workspace.addVideoTrack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineAddAudioTrack)) { _ in
            workspace.addAudioTrack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineRenderInToOut)) { _ in
            workspace.renderInToOut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineExportSequence)) { _ in
            workspace.showingExportSheet = true
        }
        .sheet(isPresented: $workspace.showingExportSheet) {
            ExportSheet(workspace: workspace)
        }
        .sheet(isPresented: $workspace.showingShotExportSheet) {
            ShotExportSheet(workspace: workspace)
        }
        .sheet(item: $workspace.activeNotice) { notice in
            KineNoticeSheet(notice: notice) { workspace.activeNotice = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineShowEffectControls)) { _ in
            // ⇧⌘5 — flip the Source pane to the Effect Controls tab
            // (Premiere-style, no popover).
            workspace.sourcePaneTab = .effectControls
            workspace.focusedViewer = .source
        }
        .sheet(isPresented: $workspace.showingNewSequenceSheet) {
            SequenceSettingsSheet(
                mode: .createNew,
                initialName: "Timeline \(workspace.project.sequences.count + 1)",
                initialSettings: SequencePreset.hd1080_23_976.settings ?? SequenceSettings(frameRate: .twentyThree976, resolution: PixelSize(width: 1920, height: 1080)),
                onConfirm: { name, settings in
                    workspace.createSequence(name: name, settings: settings)
                    workspace.showingNewSequenceSheet = false
                },
                onCancel: { workspace.showingNewSequenceSheet = false }
            )
        }
        .sheet(item: $workspace.pendingMismatch) { pending in
            SequenceMismatchSheet(
                pending: pending,
                onMatch:  { workspace.resolveMismatchMatchSequence() },
                onKeep:   { workspace.resolveMismatchKeepSequence() },
                onCancel: { workspace.resolveMismatchCancel() }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .kineShowAbout)) { _ in
            showingAbout = true
        }
        .sheet(isPresented: $showingAbout) {
            AboutView { showingAbout = false }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    /// Toggle the Program-fills-window mode and keep the native window
    /// fullscreen in sync so the picture truly fills the screen.
    private func setProgramFullscreen(_ on: Bool) {
        workspace.programFullscreen = on
        workspace.focusedViewer = .program
        let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.contentView != nil })
        let isFS = win?.styleMask.contains(.fullScreen) ?? false
        if on != isFS { win?.toggleFullScreen(nil) }
    }

    private func installKeyMonitor() {
        let held = heldChordKeys
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.type == .keyUp {
                if let chars = event.charactersIgnoringModifiers {
                    held.keys.remove(chars.lowercased())
                    if let token = Self.glyphToken(chars) { workspace.pressedKeys.remove(token) }
                }
                return event
            }

            // Skip if user is typing in a text field
            if NSApp.keyWindow?.firstResponder is NSText { return event }

            guard let chars = event.charactersIgnoringModifiers else { return event }
            let isShift = event.modifierFlags.contains(.shift)
            let isCommand = event.modifierFlags.contains(.command)
            let isOption = event.modifierFlags.contains(.option)

            if !event.isARepeat, HeldChordKeys.tracked.contains(chars.lowercased()) {
                held.keys.insert(chars.lowercased())
            }
            if !event.isARepeat, !isCommand, let token = Self.glyphToken(chars) {
                workspace.pressedKeys.insert(token)
            }

            // Shots workspace: transport acts on the focused (hovered /
            // selected) shot. Everything else falls through.
            if workspace.appMode == .shots && !isCommand {
                switch chars {
                case " ":
                    workspace.toggleShotPlayback()
                    return nil
                case "j":
                    // J+K chord: nudge one frame back.
                    if held.keys.contains("k") { workspace.shotStepFrames(-1) }
                    else { workspace.shotShuttle(direction: -1) }
                    return nil
                case "k":
                    if held.keys.contains("l") { workspace.shotStepFrames(1) }
                    else if held.keys.contains("j") { workspace.shotStepFrames(-1) }
                    else { workspace.shotStop() }
                    return nil
                case "l":
                    // K+L chord: nudge one frame forward.
                    if held.keys.contains("k") { workspace.shotStepFrames(1) }
                    else { workspace.shotShuttle(direction: 1) }
                    return nil
                case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)):
                    workspace.shotStepFrames(isShift ? -10 : -1)
                    return nil
                case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)):
                    workspace.shotStepFrames(isShift ? 10 : 1)
                    return nil
                case "i":
                    // I+O together (either order) clears the trim.
                    if isOption || held.keys.contains("o") { workspace.clearShotTrim() }
                    else { workspace.setShotTrimInAtPlayhead() }
                    return nil
                case "o":
                    if isOption || held.keys.contains("i") { workspace.clearShotTrim() }
                    else { workspace.setShotTrimOutAtPlayhead() }
                    return nil
                case "m":
                    workspace.toggleStillMarkAtPlayhead()
                    return nil
                case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)):
                    workspace.selectAdjacentShot(-1)
                    return nil
                case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)):
                    workspace.selectAdjacentShot(1)
                    return nil
                case "\u{1B}":
                    if isWindowFullscreen {
                        setWindowFullscreen(false)
                        return nil
                    }
                    if workspace.shotsViewMode == .develop {
                        workspace.shotsViewMode = .bin
                        return nil
                    }
                    break
                default:
                    break
                }
            }

            // Command-modified shortcuts take precedence over bare keys.
            if isCommand {
                switch chars {
                case "k":
                    workspace.splitAtPlayhead()
                    return nil
                case "l":
                    workspace.toggleLinkOnSelection()
                    return nil
                case "d":
                    if isShift {
                        workspace.removeTransitionAtPlayhead()
                    } else {
                        workspace.addCrossDissolveAtPlayhead()
                    }
                    return nil
                case "=", "+":
                    workspace.zoomIn()
                    return nil
                case "-":
                    workspace.zoomOut()
                    return nil
                case "z":
                    if isShift { workspace.redo() } else { workspace.undo() }
                    return nil
                case "f":
                    if workspace.appMode == .shots {
                        // Cmd+F is the processing gesture: land in Develop
                        // and toggle native fullscreen with it.
                        workspace.shotsViewMode = .develop
                        setWindowFullscreen(!isWindowFullscreen)
                    } else {
                        setProgramFullscreen(!workspace.programFullscreen)
                    }
                    return nil
                default:
                    return event
                }
            }

            switch chars {
            case "\u{1B}":   // Escape exits Program fullscreen
                if workspace.programFullscreen {
                    setProgramFullscreen(false)
                    return nil
                }
                return event
            case " ":
                workspace.toggleFocusedPlay()
                return nil
            case "n", "N":
                KineSettings.shared.snappingEnabled.toggle()
                return nil
            case "v", "V":
                workspace.splitAtPlayhead()
                return nil
            case "b", "B":
                workspace.activeTool = .blade
                return nil
            case "a", "A":
                workspace.activeTool = .pointer
                return nil
            case "j":
                workspace.focusedPlayReverse()
                return nil
            case "k":
                workspace.focusedStop()
                return nil
            case "l":
                workspace.focusedPlayForward()
                return nil
            case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)):
                workspace.focusedJumpFrames(isShift ? -10 : -1)
                return nil
            case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)):
                workspace.focusedJumpFrames(isShift ? 10 : 1)
                return nil
            case String(Character(UnicodeScalar(NSHomeFunctionKey)!)):
                workspace.jumpToStart()
                return nil
            case String(Character(UnicodeScalar(NSEndFunctionKey)!)):
                workspace.jumpToEnd()
                return nil
            case "i":
                let sourceFocused = workspace.sourceMarksActive
                if isOption {
                    if sourceFocused { workspace.sourceInMark = nil }
                    else { workspace.clearProgramIn() }
                } else if isShift {
                    if sourceFocused {
                        if let s = workspace.sourceInMark { workspace.sourceTimeSeconds = s }
                    } else {
                        workspace.goToProgramIn()
                    }
                } else {
                    if sourceFocused { workspace.setSourceIn() }
                    else { workspace.setProgramIn() }
                }
                return nil
            case "o":
                let sourceFocused = workspace.sourceMarksActive
                if isOption {
                    if sourceFocused { workspace.sourceOutMark = nil }
                    else { workspace.clearProgramOut() }
                } else if isShift {
                    if sourceFocused {
                        if let s = workspace.sourceOutMark { workspace.sourceTimeSeconds = s }
                    } else {
                        workspace.goToProgramOut()
                    }
                } else {
                    if sourceFocused { workspace.setSourceOut() }
                    else { workspace.setProgramOut() }
                }
                return nil
            case "f", "F":
                // Favorite the current source In/Out selection (FCP-style).
                // Only when a source clip is the active mark target.
                if workspace.sourceMarksActive {
                    workspace.favoriteSourceSelection()
                    return nil
                }
                return event
            case "x", "X":
                if isOption {
                    if workspace.sourceMarksActive { workspace.clearSourceMarks() }
                    else { workspace.clearProgramMarks() }
                    return nil
                }
                return event
            case ",":
                // `charactersIgnoringModifiers` strips shift here, so
                // shift+, lands in this case with isShift=true.
                if isShift {
                    workspace.nudgeSelectedClips(frames: -1)
                } else {
                    workspace.insertFromSource()
                }
                return nil
            case ".":
                if isShift {
                    workspace.nudgeSelectedClips(frames: 1)
                } else {
                    workspace.overwriteFromSource()
                }
                return nil
            case "<":
                // Fallback in case the keyboard layout reports the
                // shifted character directly. Either matches → nudge.
                workspace.nudgeSelectedClips(frames: -1)
                return nil
            case ">":
                workspace.nudgeSelectedClips(frames: 1)
                return nil
            case String(Character(UnicodeScalar(NSDeleteCharacter)!)),
                 String(Character(UnicodeScalar(NSBackspaceCharacter)!)),
                 String(Character(UnicodeScalar(NSDeleteFunctionKey)!)),
                 "\u{7F}":
                if !workspace.selectedClipIDs.isEmpty {
                    if isShift {
                        workspace.rippleDeleteSelected()
                    } else {
                        workspace.deleteSelected()
                    }
                    return nil
                }
                if let cut = workspace.selectedCut {
                    workspace.removeTransitionAtCut(cut)
                    workspace.selectedCut = nil
                    return nil
                }
                if let edge = workspace.selectedClipEdge {
                    workspace.removeFadeAtEdge(edge)
                    workspace.selectedClipEdge = nil
                    return nil
                }
                if workspace.selectedGap != nil {
                    workspace.deleteSelectedGap()
                    return nil
                }
                return event
            default:
                return event
            }
        }
        keyMonitor = monitor
    }

    final class HeldChordKeys {
        static let tracked: Set<String> = ["j", "k", "l", "i", "o"]
        var keys: Set<String> = []
    }

    /// The processing view's glyph bar lights these while held.
    private static func glyphToken(_ chars: String) -> String? {
        switch chars.lowercased() {
        case " ": return "space"
        case "j", "k", "l", "i", "o", "m": return chars.lowercased()
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): return "left"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): return "right"
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): return "up"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): return "down"
        default: return nil
        }
    }

    private var isWindowFullscreen: Bool {
        (NSApp.keyWindow ?? NSApp.windows.first(where: { $0.contentView != nil }))?
            .styleMask.contains(.fullScreen) ?? false
    }

    private func setWindowFullscreen(_ on: Bool) {
        let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.contentView != nil })
        if on != isWindowFullscreen { win?.toggleFullScreen(nil) }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func exportFCPXML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.nameFieldStringValue = workspace.project.name + ".fcpxml"
        panel.title = "Export FCPXML"
        panel.message = "Export the media pool as an FCPXML for Premiere / Resolve / Final Cut."

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try FCPXMLExporter().write(project: workspace.project, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "FCPXML export failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

/// Inset accent-stroke overlay used to mark the active pane.
/// Corner radius matches macOS's bottom window-corner curvature so the
/// stroke around panes that touch the window edges (bin, timeline)
/// follows the window's rounded corners cleanly.
private struct FocusBorder: ViewModifier {
    let isFocused: Bool
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? KineTheme.accent.opacity(0.7) : Color.clear,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func focusBorder(_ isFocused: Bool) -> some View {
        modifier(FocusBorder(isFocused: isFocused))
    }
}

/// Wraps the NSView timeline with a Polymerge-style zoom bar across
/// the bottom: minus / slider / plus + a px-per-second readout. The
/// slider is bound to `WorkspaceModel.pixelsPerSecond` so ⌘+/⌘- and
/// the slider stay in sync.
private struct TimelineWithZoomBar: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            TimelineHostView(workspace: workspace)
            Divider()
            HStack(spacing: 8) {
                Button(action: { workspace.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                ThinSlider(
                    value: $workspace.pixelsPerSecond,
                    range: 4...800
                )
                .frame(maxWidth: 360)
                Button(action: { workspace.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(Int(workspace.pixelsPerSecond)) px/s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(KineTheme.bgPanel)
        }
    }
}

private struct TimelineHostView: NSViewRepresentable {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var settings: KineSettings = .shared

    func makeNSView(context: Context) -> KineTimelineView {
        let view = KineTimelineView(frame: .zero)
        view.callbacks.insertClip = { [weak workspace] clipID, time, trackIdx in
            Task { @MainActor in
                workspace?.attemptInsertClip(clipID, atTime: time, videoTrackIndex: trackIdx)
            }
        }
        view.callbacks.insertClipFragment = { [weak workspace] clipID, start, dur, time, trackIdx in
            Task { @MainActor in
                workspace?.attemptInsertClipFragment(clipID, sourceStart: start, sourceDuration: dur, atTime: time, videoTrackIndex: trackIdx)
            }
        }
        view.callbacks.setPlayhead = { [weak workspace] time in
            Task { @MainActor in workspace?.setPlayhead(time) }
        }
        view.callbacks.selectClip = { [weak workspace] id, additive in
            Task { @MainActor in workspace?.select(id, additive: additive) }
        }
        view.callbacks.clearSelection = { [weak workspace] in
            Task { @MainActor in workspace?.clearSelection() }
        }
        view.callbacks.moveClip = { [weak workspace] id, time, target in
            let trackTarget: WorkspaceModel.TrackTarget? = {
                guard let t = target else { return nil }
                if t.kind == 0 { return .video(t.index) }
                if t.kind == 1 { return .audio(t.index) }
                return nil
            }()
            // Synchronous on main — the Task hop would defer the model
            // mutation one runloop tick, causing a single-frame render
            // with the clip on its old track right after we cleared the
            // floating-ghost state. AppKit guarantees this fires on the
            // main thread.
            MainActor.assumeIsolated {
                workspace?.moveClip(id, to: time, targetTrack: trackTarget)
            }
        }
        view.callbacks.moveSelectedClips = { [weak workspace] targets in
            MainActor.assumeIsolated {
                workspace?.moveSelectedClipsTo(targets)
            }
        }
        view.callbacks.trimLeft = { [weak workspace] id, time in
            Task { @MainActor in workspace?.trimLeft(id, to: time) }
        }
        view.callbacks.trimRight = { [weak workspace] id, time in
            Task { @MainActor in workspace?.trimRight(id, to: time) }
        }
        view.callbacks.clipSourceForID = { [weak workspace] id in
            workspace?.project.mediaPool.clips[id]
        }
        view.callbacks.requestToggleLink = { [weak workspace] in
            Task { @MainActor in workspace?.toggleLinkOnSelection() }
        }
        view.callbacks.requestUnlink = { [weak workspace] in
            Task { @MainActor in workspace?.unlinkSelection() }
        }
        view.callbacks.requestDeleteSelected = { [weak workspace] in
            Task { @MainActor in workspace?.deleteSelected() }
        }
        view.callbacks.requestRippleDeleteSelected = { [weak workspace] in
            Task { @MainActor in workspace?.rippleDeleteSelected() }
        }
        view.callbacks.selectGap = { [weak workspace] gap in
            Task { @MainActor in workspace?.selectGap(gap) }
        }
        view.callbacks.selectCut = { [weak workspace] cut in
            Task { @MainActor in workspace?.selectCut(cut) }
        }
        view.callbacks.requestAddTransition = { [weak workspace] cut in
            Task { @MainActor in
                guard let workspace else { return }
                workspace.applyTransitionAtCut(cut)
            }
        }
        view.callbacks.requestRemoveTransition = { [weak workspace] cut in
            Task { @MainActor in workspace?.removeTransitionAtCut(cut) }
        }
        view.callbacks.resizeTransitionEdge = { [weak workspace] cut, side, half in
            // Sync — mirrors moveClip pattern so the drag stays smooth.
            MainActor.assumeIsolated {
                if side == 0 {
                    workspace?.resizeTransition(at: cut, leftHalf: half)
                } else {
                    workspace?.resizeTransition(at: cut, rightHalf: half)
                }
            }
        }
        view.callbacks.selectClipEdge = { [weak workspace] edge in
            Task { @MainActor in workspace?.selectClipEdge(edge) }
        }
        view.callbacks.requestAddFade = { [weak workspace] edge in
            Task { @MainActor in workspace?.applyFadeAtEdge(edge) }
        }
        view.callbacks.requestRemoveFade = { [weak workspace] edge in
            Task { @MainActor in workspace?.removeFadeAtEdge(edge) }
        }
        view.callbacks.resizeSoloFade = { [weak workspace] edge, dur in
            MainActor.assumeIsolated {
                workspace?.applyFadeAtEdge(edge, durationSeconds: dur)
            }
        }
        view.callbacks.bladeClip = { [weak workspace] clipID, t in
            Task { @MainActor in workspace?.splitClipAndLinked(clipID, atSeconds: t) }
        }
        view.callbacks.setPixelsPerSecond = { [weak workspace] value in
            MainActor.assumeIsolated {
                workspace?.pixelsPerSecond = value
            }
        }
        view.callbacks.didReceiveFocus = { [weak workspace] in
            Task { @MainActor in workspace?.focusedViewer = .timeline }
        }
        view.callbacks.beginClipDragOrTrim = { [weak workspace] in
            Task { @MainActor in workspace?.beginUndoBatch() }
        }
        view.callbacks.endClipDragOrTrim = { [weak workspace] clipID in
            Task { @MainActor in
                if let id = clipID {
                    workspace?.finalizeOverlapsForClip(id)
                }
                workspace?.endUndoBatch()
            }
        }
        view.callbacks.requestToggleVideoEnabled = { [weak workspace] idx in
            Task { @MainActor in workspace?.toggleVideoTrackEnabled(at: idx) }
        }
        view.callbacks.requestToggleVideoLocked = { [weak workspace] idx in
            Task { @MainActor in workspace?.toggleVideoTrackLocked(at: idx) }
        }
        view.callbacks.requestToggleAudioMuted = { [weak workspace] idx in
            Task { @MainActor in workspace?.toggleAudioTrackMuted(at: idx) }
        }
        view.callbacks.requestToggleAudioSolo = { [weak workspace] idx in
            Task { @MainActor in workspace?.toggleAudioTrackSolo(at: idx) }
        }
        view.callbacks.requestToggleAudioLocked = { [weak workspace] idx in
            Task { @MainActor in workspace?.toggleAudioTrackLocked(at: idx) }
        }
        view.callbacks.requestSetVideoTarget = { [weak workspace] idx in
            Task { @MainActor in workspace?.setVideoTarget(at: idx) }
        }
        view.callbacks.requestSetAudioTarget = { [weak workspace] idx in
            Task { @MainActor in workspace?.setAudioTarget(at: idx) }
        }
        view.audioTrackLevelProvider = { [weak workspace] idx in
            workspace?.audio.peakLevel(forAudioTrackIndex: idx) ?? 0
        }
        // Drive the playhead line directly during playback so a moving
        // playhead doesn't republish the whole WorkspaceModel and re-push
        // the timeline every frame (the playback-staccato cause). Seeks /
        // scrubs still flow through `push` via objectWillChange.
        workspace.onPlayheadChange = { [weak view] time in
            MainActor.assumeIsolated { view?.movePlayhead(to: time) }
        }
        push(into: view)
        return view
    }

    func updateNSView(_ nsView: KineTimelineView, context: Context) {
        push(into: nsView)
    }

    private func push(into view: KineTimelineView) {
        view.sequence = workspace.activeSequence
        view.clipSources = workspace.project.mediaPool.clips
        view.playheadTime = workspace.playheadTime
        view.selectedClipIDs = workspace.selectedClipIDs
        view.selectedGap = workspace.selectedGap
        view.selectedCut = workspace.selectedCut
        view.selectedClipEdge = workspace.selectedClipEdge
        view.snappingEnabled = settings.snappingEnabled
        view.activeTool = workspace.activeTool
        view.pixelsPerSecond = workspace.pixelsPerSecond
        view.cacheSegmentsSeconds = workspace.cacheSegmentsForActiveSequence()
            .map { (start: $0.startSeconds, end: $0.endSeconds) }

        // Push the latest preview snapshots into the timeline view.
        // `previewVersion` ticks each time the cache commits, which
        // pulls SwiftUI through `updateNSView` and into this push.
        let snapshot = workspace.previewCache.snapshot()
        view.audioPeaks = snapshot.waveforms.mapValues { $0.peaks }
        var thumbs = snapshot.thumbs.mapValues { $0.images }
        // Shot clips (kine-shot://) never hit the AVFoundation preview
        // cache; use the shot's own filmstrip samples.
        for (clipID, clip) in workspace.project.mediaPool.clips where clip.url.scheme == "kine-shot" {
            if let host = clip.url.host, let uuid = UUID(uuidString: host),
               let images = workspace.shotThumbnails[ShotID(rawValue: uuid)] {
                thumbs[clipID] = images
            }
        }
        view.videoThumbnails = thumbs
        _ = workspace.previewVersion

        // Audio meters update via SwiftUI's playhead-driven re-renders
        // (playheadTime ticks at 60Hz while playing, which retriggers
        // updateNSView and forces a redraw with fresh meter values).
    }
}
