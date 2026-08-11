import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import KineCore
import KineMedia
import KineRender
import KineTimelineUI
import PolymergeAudio

@MainActor
public final class WorkspaceModel: ObservableObject {
    @Published public var project: Project
    @Published public var sourceClip: ClipSource?
    @Published public var programClip: ClipSource?
    @Published public var importing: Bool = false
    @Published public var activeSequenceID: SequenceID?

    /// Program playhead. Deliberately NOT `@Published`: it updates every
    /// frame during playback, and republishing the whole WorkspaceModel
    /// at the display rate re-renders the entire SwiftUI tree + re-pushes
    /// the timeline each frame, starving the render display link (the
    /// cause of playback staccato). Per-frame consumers are driven by
    /// `playheadClock` (timecode) and `onPlayheadChange` (timeline line).
    /// User-driven seeks/scrubs go through `setPlayhead`, which sends one
    /// `objectWillChange` so paused edits still refresh the whole tree.
    public var playheadTime: RationalTime = .zero {
        didSet {
            if playheadClock.seconds != playheadTime.seconds {
                playheadClock.seconds = playheadTime.seconds
            }
            onPlayheadChange?(playheadTime)
        }
    }

    /// Lightweight per-frame clock for the timecode readout. See `playheadTime`.
    public let playheadClock = PlayheadClock()
    /// Direct sink for the timeline's playhead line, set by the timeline host.
    public var onPlayheadChange: ((RationalTime) -> Void)?
    @Published public var selectedClipIDs: Set<PlacedClipID> = []
    /// Currently selected gap (empty space between clips on a track).
    /// Mutually exclusive with `selectedClipIDs`: selecting a gap
    /// clears the clip selection, and vice versa.
    @Published public var selectedGap: GapSelection?
    /// Currently selected cut between two abutting clips. Used by the
    /// right-click "Add / Remove Transition" menu and the wedge edge
    /// drag handles.
    @Published public var selectedCut: CutSelection?
    /// Currently selected single-clip edge (in or out point). Drives
    /// the right-click "Add Fade" menu for solo transitions.
    @Published public var selectedClipEdge: ClipEdgeSelection?
    /// Currently active timeline tool. A = pointer (default), B = blade.
    @Published public var activeTool: ActiveTool = .pointer
    /// Timeline zoom (pixels per second). Bound to the zoom slider and
    /// the ⌘+ / ⌘- shortcuts. Pushed into `KineTimelineView` each
    /// `updateNSView` cycle.
    @Published public var pixelsPerSecond: Double = 60

    /// Zoom in: multiply px/s by 1.5×, clamped to the view's max.
    public func zoomIn() {
        pixelsPerSecond = min(800, pixelsPerSecond * 1.5)
    }
    /// Zoom out: divide px/s by 1.5×, clamped to the view's min.
    public func zoomOut() {
        pixelsPerSecond = max(4, pixelsPerSecond / 1.5)
    }
    @Published public var showingNewSequenceSheet: Bool = false
    @Published public var pendingMismatch: PendingMismatch?
    @Published public var currentProjectURL: URL?
    @Published public var isDirty: Bool = false
    @Published public var saveError: String?
    @Published public var sourceTimeSeconds: Double = 0
    @Published public var sourceInMark: Double?
    @Published public var sourceOutMark: Double?
    /// True once the PPE source player has presented its first real frame
    /// after a play start. The source viewer holds the still placeholder
    /// over PPE until this flips, so play-after-skim doesn't flash black.
    @Published public var sourcePlaybackReady: Bool = false
    @Published public var focusedViewer: FocusedViewer = .program
    /// ⌘F — show ONLY the Program viewer filling the window (cinema mode).
    @Published public var programFullscreen: Bool = false
    /// 0…1 progress of an in-flight pre-render. nil = no render running.
    /// Driven by `renderInToOut`; consumed by the program viewer header
    /// (or wherever surfaces it).
    @Published public var renderProgress: Double?
    /// Most recent pre-render output path. Set when `renderInToOut`
    /// finishes successfully. Cleared on the next render kickoff.
    @Published public var lastRenderURL: URL?
    /// Error from the last pre-render attempt, if any. Cleared on
    /// the next kickoff.
    @Published public var renderError: String?
    /// Holds the in-flight encoder so the UI / next-kickoff can cancel it.
    private var activeEncoder: SequenceEncoder?
    @Published public var showingExportSheet: Bool = false
    /// Which tab the Source pane currently shows. Premiere-style:
    /// "Source" is the source viewer; "Effect Controls" edits the
    /// selected timeline clip's transform/crop and (eventually)
    /// keyframes. `⇧⌘5` flips to `.effectControls`.
    @Published public var sourcePaneTab: SourcePaneTab = .source
    /// Bin browser filter. `.all` shows every master clip as a filmstrip;
    /// `.favorites` shows only the marked favorite sub-ranges as their
    /// own draggable filmstrip entries.
    @Published public var binFilter: BinFilter = .all
    /// Set by RealtimeProgramHost when the compose-and-present
    /// roundtrip is taking too long on a sustained run. The program
    /// viewer header surfaces this as a subtle "Render In to Out for
    /// smooth playback" chip.
    @Published public var realtimeIsDropping: Bool = false

    public enum ExportRange { case inToOut, wholeSequence }

    /// Single source of truth for what's playing right now. Mutually
    /// exclusive between program and source viewers (Premiere-style).
    @Published public var playbackState: PlaybackState = .stopped

    // Computed convenience for SwiftUI views that previously used the
    // separate flags. Keep these so downstream code doesn't need rewriting.
    public var isPlaying: Bool       { playbackState.isPlaying }
    public var sourceIsPlaying: Bool { playbackState.isSourcePlaying }
    public var playbackRate: Double  { playbackState.rate }

    /// True when In/Out/Favorite keystrokes should act on the source clip:
    /// either the source viewer is focused, or the bin is focused with a
    /// clip skimmed/loaded into the source viewer (FCP marks the skimmer).
    public var sourceMarksActive: Bool {
        sourceClip != nil && (focusedViewer == .source || focusedViewer == .bin)
    }

    // MARK: - Undo / redo

    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private var undoSilenced: Bool = false
    private static let undoStackCap = 100

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Push the CURRENT project state to the undo stack and clear the
    /// redo stack. Call BEFORE making a mutation. No-op while a batch
    /// is in progress (drag, etc.) so a multi-tick gesture is one undo.
    public func pushUndoSnapshot() {
        guard !undoSilenced else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            undoStack.append(data)
            if undoStack.count > Self.undoStackCap {
                undoStack.removeFirst(undoStack.count - Self.undoStackCap)
            }
            redoStack.removeAll()
        } catch {
            KineDebugLog.log("[Undo] snapshot encode failed: \(error.localizedDescription)")
        }
    }

    /// Begin a batched mutation (e.g. a clip drag). Push a single
    /// snapshot now, then silence further pushes until `endUndoBatch`.
    public func beginUndoBatch() {
        guard !undoSilenced else { return }
        pushUndoSnapshot()
        undoSilenced = true
    }

    public func endUndoBatch() {
        undoSilenced = false
    }

    public func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let currentData = try encoder.encode(project)
            redoStack.append(currentData)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let restored = try decoder.decode(Project.self, from: snapshot)

            applyRestoredProject(restored)
        } catch {
            KineDebugLog.log("[Undo] restore failed: \(error.localizedDescription)")
        }
    }

    public func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let currentData = try encoder.encode(project)
            undoStack.append(currentData)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let restored = try decoder.decode(Project.self, from: snapshot)

            applyRestoredProject(restored)
        } catch {
            KineDebugLog.log("[Redo] restore failed: \(error.localizedDescription)")
        }
    }

    private func applyRestoredProject(_ restored: Project) {
        // Stop any playback before swapping the project under us.
        setPlayback(.stopped)
        project = restored
        // If active sequence got removed, pick the first one (or nil).
        if let id = activeSequenceID, !restored.sequences.contains(where: { $0.id == id }) {
            activeSequenceID = restored.sequences.first?.id
        }
        // Clean up selection: drop any clip IDs that no longer exist.
        let existing: Set<PlacedClipID> = {
            var s: Set<PlacedClipID> = []
            for seq in restored.sequences {
                for t in seq.videoTracks { for c in t.clips { s.insert(c.id) } }
                for t in seq.audioTracks { for c in t.clips { s.insert(c.id) } }
            }
            return s
        }()
        selectedClipIDs.formIntersection(existing)
        // Re-clip source viewer if its clip got dropped.
        if let s = sourceClip, restored.mediaPool.clips[s.id] == nil {
            sourceClip = nil
        }
        // Restoring a snapshot is a content change — nuke any cache
        // that referenced the in-memory sequence we just replaced.
        for seq in restored.sequences {
            PreRenderCache.clearAll(forProjectID: restored.id, sequenceID: seq.id)
        }
        refreshRenderSegmentCache()
        audio.invalidate(); sourceAudio.invalidate()
        markDirty()
    }

    /// Bumped on every playback transition. Async Tasks that need to
    /// finish work (audio.sync, etc.) check this before doing anything
    /// stateful — if the generation has moved on, the user's already
    /// asked for something else and they abort.
    private var playbackGen: UInt64 = 0

    /// Single CVDisplayLink driving whichever playback is active.
    private var playbackDisplayLink: CVDisplayLink?
    private var playStartHostTime: CFTimeInterval = 0
    private var playStartSeconds: Double = 0
    public let audio = TimelineAudioPipeline()
    /// Audio engine scoped to the source viewer. Mutex with `audio`
    /// via `PlaybackState`: only one of the two ever runs at a time.
    public let sourceAudio = SourceAudioPipeline()
    public let previewCache = ClipPreviewCache()
    /// Fast still-frame source for skim / scrub / paused source display.
    /// Reserves the PPE playback decoder for actual playback.
    public let skimProvider = SkimFrameProvider()

    /// Bumped whenever the preview cache commits new waveform / thumbnail
    /// data. The SwiftUI timeline host observes this so `updateNSView`
    /// re-runs and snapshots the latest previews into the NSView.
    @Published public private(set) var previewVersion: Int = 0

    private let prober = MediaProber()
    private let stillsIngest = StillsIngest()

    /// Per-still preview strips for shot bin rows (capped, evenly sampled).
    /// Not `@Published` — rows observe `previewVersion` like clip previews.
    public private(set) var shotThumbnails: [ShotID: [CGImage]] = [:]
    private var shotThumbsInFlight: Set<ShotID> = []
    private static let shotThumbMax = 16

    /// Non-nil while a shot batch export runs (0…1).
    @Published public var shotExportProgress: Double? = nil

    private var autosaveTimer: Timer?

    /// Weak handle for the AppDelegate to inspect lifecycle state
    /// (e.g. `isDirty` on ⌘Q) without a runtime singleton dance. Set
    /// when the only WorkspaceModel — owned by `KineRootView` —
    /// initializes; weak so the SwiftUI lifecycle remains the truth.
    public static weak var current: WorkspaceModel?

    public init() {
        // Start with NO sequence — user must create one via ⌘N. This
        // matches Premiere / Resolve where the project starts empty and
        // the user picks specs first.
        self.project = Project(name: "Untitled")
        self.activeSequenceID = nil
        scheduleAutosave()
        previewCache.onChange = { [weak self] in
            self?.previewVersion &+= 1
        }
        WorkspaceModel.current = self
    }

    /// Kick off (or no-op if already cached / in flight) waveform and
    /// thumbnail generation for the given source. Called when a clip
    /// is ingested or when an opened project's clips are first observed.
    public func schedulePreviews(for source: ClipSource) {
        if !source.audioTracks.isEmpty {
            previewCache.ensureWaveform(clipID: source.id, url: source.url)
        }
        if !source.videoTracks.isEmpty {
            previewCache.ensureThumbnails(clipID: source.id, url: source.url)
        }
    }

    // MARK: - Save / open / new

    public func newProject() {
        stop()
        project = Project(name: "Untitled")
        activeSequenceID = nil
        playheadTime = .zero
        selectedClipIDs = []
        currentProjectURL = nil
        isDirty = false
        audio.invalidate(); sourceAudio.invalidate()
        previewCache.clear()
        skimProvider.clear()
    }

    /// `completion` reports whether the project is saved when the call
    /// settles — including the async Save-As panel. Callers that gate on
    /// the result (e.g. quit-with-unsaved-changes) must use it rather
    /// than polling `isDirty`, which is still true while the panel is up.
    public func save(completion: ((Bool) -> Void)? = nil) {
        if let url = currentProjectURL {
            performSave(to: url)
            completion?(!isDirty)
        } else {
            saveAs(completion: completion)
        }
    }

    public func saveAs(completion: ((Bool) -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectStore.fileExtension) ?? .data]
        panel.nameFieldStringValue = project.name + ".\(ProjectStore.fileExtension)"
        panel.title = "Save Kinestasis Project"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            // Set the name BEFORE saving so the file contents persist
            // it. Previously the name was set after performSave, so
            // every Save-As produced an "Untitled" file on disk and
            // every subsequent Open showed the wrong window title.
            project.name = url.deletingPathExtension().lastPathComponent
            performSave(to: url)
            completion?(!isDirty)
        }
    }

    public func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectStore.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Kinestasis Project"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            performOpen(url: url)
        }
    }

    private func performSave(to url: URL) {
        do {
            try ProjectStore.save(project: project, to: url)
            currentProjectURL = url
            isDirty = false
        } catch {
            saveError = error.localizedDescription
            KineDebugLog.log("[Workspace] save failed: \(error.localizedDescription)")
        }
    }

    private func performOpen(url: URL) {
        do {
            stop()
            var loaded = try ProjectStore.load(from: url)
            // Defensive: if the persisted name is empty or the
            // pre-fix "Untitled" placeholder, infer it from the file
            // we just opened. The on-disk name and the displayed
            // window title should never disagree with the filename.
            let fileName = url.deletingPathExtension().lastPathComponent
            if loaded.name.isEmpty || loaded.name == "Untitled" {
                loaded.name = fileName
            }
            project = loaded
            activeSequenceID = loaded.sequences.first?.id
            playheadTime = .zero
            selectedClipIDs = []
            currentProjectURL = url
            isDirty = false
            audio.invalidate(); sourceAudio.invalidate()
            previewCache.clear()
            skimProvider.clear()
            for clip in loaded.mediaPool.clips.values {
                schedulePreviews(for: clip)
            }
        } catch {
            saveError = error.localizedDescription
            KineDebugLog.log("[Workspace] open failed: \(error.localizedDescription)")
        }
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isDirty else { return }
                let url = ProjectStore.autosaveURL(forProjectID: project.id)
                try? ProjectStore.save(project: project, to: url)
            }
        }
    }

    /// Mark the project dirty. Called from every mutation site.
    public func markDirty() {
        if !isDirty { isDirty = true }
    }

    /// Create a new sequence in the project and make it active. Called
    /// from the New Sequence dialog's confirm action.
    public func createSequence(name: String, settings: SequenceSettings) {
        pushUndoSnapshot()
        let sequence = Sequence(name: name, settings: settings)
        project.sequences.append(sequence)
        activeSequenceID = sequence.id
        project.modifiedAt = Date()
        markDirty()
    }

    public func activateSequence(_ id: SequenceID) {
        activeSequenceID = id
        playheadTime = .zero
        selectedClipIDs = []
        audio.invalidate(); sourceAudio.invalidate()
    }

    public func addVideoTrack() {
        updateSequence { sequence in
            let name = "V\(sequence.videoTracks.count + 1)"
            sequence.videoTracks.append(VideoTrack(name: name))
        }
    }

    public func addAudioTrack() {
        updateSequence { sequence in
            let name = "A\(sequence.audioTracks.count + 1)"
            sequence.audioTracks.append(AudioTrack(name: name))
        }
    }

    // MARK: - Track flag toggles (mute / solo / lock)

    public func toggleVideoTrackEnabled(at index: Int) {
        updateSequence { sequence in
            guard sequence.videoTracks.indices.contains(index) else { return }
            sequence.videoTracks[index].isEnabled.toggle()
        }
    }

    public func toggleVideoTrackLocked(at index: Int) {
        updateSequence { sequence in
            guard sequence.videoTracks.indices.contains(index) else { return }
            sequence.videoTracks[index].isLocked.toggle()
        }
    }

    public func toggleAudioTrackMuted(at index: Int) {
        updateSequence { sequence in
            guard sequence.audioTracks.indices.contains(index) else { return }
            sequence.audioTracks[index].isMuted.toggle()
        }
    }

    public func toggleAudioTrackSolo(at index: Int) {
        updateSequence { sequence in
            guard sequence.audioTracks.indices.contains(index) else { return }
            sequence.audioTracks[index].isSolo.toggle()
        }
    }

    public func toggleAudioTrackLocked(at index: Int) {
        updateSequence { sequence in
            guard sequence.audioTracks.indices.contains(index) else { return }
            sequence.audioTracks[index].isLocked.toggle()
        }
    }

    /// Update the active sequence's settings — used by the mismatch
    /// dialog when the user picks "Match sequence to clip".
    public func updateActiveSequenceSettings(_ newSettings: SequenceSettings) {
        updateSequence { sequence in
            sequence.settings = newSettings
        }
    }

    /// Returns the kind of mismatch (if any) between a clip and the
    /// active sequence — used by the drop handler to decide whether to
    /// prompt the user.
    public func mismatch(for clipID: ClipID) -> SequenceMismatch? {
        guard let sequence = activeSequence,
              let clip = project.mediaPool.clips[clipID] else { return nil }

        var differences: [SequenceMismatch.Field] = []

        if let v = clip.videoTracks.first {
            if v.resolution != sequence.settings.resolution { differences.append(.resolution(v.resolution, sequence.settings.resolution)) }
            if v.frameRate != sequence.settings.frameRate    { differences.append(.frameRate(v.frameRate, sequence.settings.frameRate)) }
        }
        if let a = clip.audioTracks.first {
            if a.sampleRate != sequence.settings.audioSampleRate {
                differences.append(.sampleRate(a.sampleRate, sequence.settings.audioSampleRate))
            }
            if a.channelCount != sequence.settings.audioChannelCount {
                differences.append(.channels(a.channelCount, sequence.settings.audioChannelCount))
            }
        }

        guard !differences.isEmpty else { return nil }

        let proposed = SequenceSettings(
            frameRate: clip.videoTracks.first?.frameRate ?? sequence.settings.frameRate,
            resolution: clip.videoTracks.first?.resolution ?? sequence.settings.resolution,
            colorSpace: sequence.settings.colorSpace,
            pixelAspectRatio: sequence.settings.pixelAspectRatio,
            audioSampleRate: clip.audioTracks.first?.sampleRate ?? sequence.settings.audioSampleRate,
            audioChannelCount: clip.audioTracks.first?.channelCount ?? sequence.settings.audioChannelCount
        )
        return SequenceMismatch(clipID: clipID, fields: differences, proposedSettings: proposed)
    }

    public var activeSequence: Sequence? {
        guard let id = activeSequenceID else { return nil }
        return project.sequences.first { $0.id == id }
    }

    /// Drop-handler entry point. If no sequence exists yet, auto-create
    /// one matching the dropped clip's specs and drop the clip at time 0.
    /// If a sequence exists, runs the mismatch check on the first drop
    /// (offers "match sequence to clip / keep / cancel"). Otherwise just
    /// inserts at the requested time.
    public func attemptInsertClip(_ clipID: ClipID, atTime time: RationalTime, videoTrackIndex: Int = 0) {
        // Auto-create sequence if none exists
        if activeSequenceID == nil {
            guard let clip = project.mediaPool.clips[clipID] else { return }
            createMatchingSequenceForClip(clip)
            insertClip(clipID, atTime: .zero, videoTrackIndex: 0)
            return
        }

        guard let sequence = activeSequence else { return }

        let isFirstClip = sequence.videoTracks.allSatisfy { $0.clips.isEmpty }
                       && sequence.audioTracks.allSatisfy { $0.clips.isEmpty }
        if isFirstClip, let mismatch = mismatch(for: clipID) {
            pendingMismatch = PendingMismatch(mismatch: mismatch, dropTime: time)
            return
        }
        insertClip(clipID, atTime: time, videoTrackIndex: videoTrackIndex)
    }

    /// Build a sequence whose settings match the clip's intrinsic
    /// specs (resolution, frame rate, sample rate, channels). Used by
    /// the auto-create-on-first-drop path.
    private func createMatchingSequenceForClip(_ clip: ClipSource) {
        let v = clip.videoTracks.first
        let a = clip.audioTracks.first
        let settings = SequenceSettings(
            frameRate: v?.frameRate ?? project.settings.defaultFrameRate,
            resolution: v?.resolution ?? project.settings.defaultResolution,
            colorSpace: project.settings.defaultColorSpace,
            pixelAspectRatio: .square,
            audioSampleRate: a?.sampleRate ?? 48_000,
            audioChannelCount: a?.channelCount ?? 2
        )
        let name = "Timeline \(project.sequences.count + 1)"
        let sequence = Sequence(name: name, settings: settings)
        project.sequences.append(sequence)
        activeSequenceID = sequence.id
        project.modifiedAt = Date()
        markDirty()
    }

    /// Insert a fragment of a source clip (used by drag-from-source-viewer)
    /// at the given timeline position. If marks are set on the source,
    /// the fragment is just that range; otherwise the full clip.
    public func attemptInsertClipFragment(
        _ clipID: ClipID,
        sourceStart: Double,
        sourceDuration: Double,
        atTime time: RationalTime,
        videoTrackIndex: Int = 0
    ) {
        if activeSequenceID == nil {
            guard let clip = project.mediaPool.clips[clipID] else { return }
            createMatchingSequenceForClip(clip)
            insertClipFragment(clipID, sourceStart: sourceStart, sourceDuration: sourceDuration, atTime: .zero, videoTrackIndex: 0)
            return
        }
        insertClipFragment(clipID, sourceStart: sourceStart, sourceDuration: sourceDuration, atTime: time, videoTrackIndex: videoTrackIndex)
    }

    public func insertClipFragment(
        _ clipID: ClipID,
        sourceStart: Double,
        sourceDuration: Double,
        atTime time: RationalTime,
        videoTrackIndex: Int = 0
    ) {
        guard let source = project.mediaPool.clips[clipID] else { return }
        guard let sequenceIndex = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        pushUndoSnapshot()
        let duration = max(0.04, sourceDuration)

        let hasVideo = !source.videoTracks.isEmpty
        let hasAudio = !source.audioTracks.isEmpty
        let linkID: UUID? = (hasVideo && hasAudio) ? UUID() : nil
        let audioTrackIndex = hasVideo ? videoTrackIndex : 0

        let sRange = TimeRange(
            start: RationalTime(value: Int64(sourceStart * 1000), scale: 1000),
            duration: RationalTime(value: Int64(duration * 1000), scale: 1000)
        )
        let tRange = TimeRange(
            start: time,
            duration: RationalTime(value: Int64(duration * 1000), scale: 1000)
        )

        var sequence = project.sequences[sequenceIndex]
        while videoTrackIndex >= sequence.videoTracks.count && hasVideo {
            sequence.videoTracks.append(VideoTrack(name: "V\(sequence.videoTracks.count + 1)"))
        }
        while audioTrackIndex >= sequence.audioTracks.count && hasAudio {
            sequence.audioTracks.append(AudioTrack(name: "A\(sequence.audioTracks.count + 1)"))
        }

        if hasVideo, sequence.videoTracks.indices.contains(videoTrackIndex) {
            splitOverlappingClips(in: &sequence.videoTracks[videoTrackIndex].clips, removingRange: tRange)
            sequence.videoTracks[videoTrackIndex].clips.append(PlacedClip(
                sourceClipID: clipID, sourceRange: sRange, timelineRange: tRange, linkID: linkID
            ))
            sequence.videoTracks[videoTrackIndex].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
        if hasAudio, sequence.audioTracks.indices.contains(audioTrackIndex) {
            splitOverlappingClips(in: &sequence.audioTracks[audioTrackIndex].clips, removingRange: tRange)
            sequence.audioTracks[audioTrackIndex].clips.append(PlacedClip(
                sourceClipID: clipID, sourceRange: sRange, timelineRange: tRange, linkID: linkID
            ))
            sequence.audioTracks[audioTrackIndex].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
        project.sequences[sequenceIndex] = sequence
        project.modifiedAt = Date()
        audio.invalidate(); sourceAudio.invalidate()
        markDirty()
    }

    public func resolveMismatchKeepSequence() {
        guard let pending = pendingMismatch else { return }
        insertClip(pending.mismatch.clipID, atTime: pending.dropTime)
        pendingMismatch = nil
    }

    public func resolveMismatchMatchSequence() {
        guard let pending = pendingMismatch else { return }
        updateActiveSequenceSettings(pending.mismatch.proposedSettings)
        insertClip(pending.mismatch.clipID, atTime: pending.dropTime)
        pendingMismatch = nil
    }

    public func resolveMismatchCancel() {
        pendingMismatch = nil
    }

    // MARK: - V/A linking

    /// Premiere-style ⌘L toggle. If the selection contains any clips that
    /// are currently linked, UNLINK them all (clear their linkID). If the
    /// selection is fully unlinked, LINK them under a new shared linkID.
    public func toggleLinkOnSelection() {
        let ids = selectedClipIDs
        guard !ids.isEmpty else { return }

        updateSequence { sequence in
            // Detect: any clip in selection that has a linkID?
            var anyLinked = false
            for vIdx in sequence.videoTracks.indices {
                for clip in sequence.videoTracks[vIdx].clips where ids.contains(clip.id) {
                    if clip.linkID != nil { anyLinked = true; break }
                }
                if anyLinked { break }
            }
            if !anyLinked {
                for aIdx in sequence.audioTracks.indices {
                    for clip in sequence.audioTracks[aIdx].clips where ids.contains(clip.id) {
                        if clip.linkID != nil { anyLinked = true; break }
                    }
                    if anyLinked { break }
                }
            }

            if anyLinked {
                // UNLINK every selected clip
                for vIdx in sequence.videoTracks.indices {
                    for cIdx in sequence.videoTracks[vIdx].clips.indices
                        where ids.contains(sequence.videoTracks[vIdx].clips[cIdx].id) {
                        sequence.videoTracks[vIdx].clips[cIdx].linkID = nil
                    }
                }
                for aIdx in sequence.audioTracks.indices {
                    for cIdx in sequence.audioTracks[aIdx].clips.indices
                        where ids.contains(sequence.audioTracks[aIdx].clips[cIdx].id) {
                        sequence.audioTracks[aIdx].clips[cIdx].linkID = nil
                    }
                }
            } else {
                // LINK them all under one new ID
                let newID = UUID()
                for vIdx in sequence.videoTracks.indices {
                    for cIdx in sequence.videoTracks[vIdx].clips.indices
                        where ids.contains(sequence.videoTracks[vIdx].clips[cIdx].id) {
                        sequence.videoTracks[vIdx].clips[cIdx].linkID = newID
                    }
                }
                for aIdx in sequence.audioTracks.indices {
                    for cIdx in sequence.audioTracks[aIdx].clips.indices
                        where ids.contains(sequence.audioTracks[aIdx].clips[cIdx].id) {
                        sequence.audioTracks[aIdx].clips[cIdx].linkID = newID
                    }
                }
            }
        }
    }

    /// Force-unlink the selected clips (clear their linkID), no matter
    /// what state they were in.
    public func unlinkSelection() {
        let ids = selectedClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for vIdx in sequence.videoTracks.indices {
                for cIdx in sequence.videoTracks[vIdx].clips.indices
                    where ids.contains(sequence.videoTracks[vIdx].clips[cIdx].id) {
                    sequence.videoTracks[vIdx].clips[cIdx].linkID = nil
                }
            }
            for aIdx in sequence.audioTracks.indices {
                for cIdx in sequence.audioTracks[aIdx].clips.indices
                    where ids.contains(sequence.audioTracks[aIdx].clips[cIdx].id) {
                    sequence.audioTracks[aIdx].clips[cIdx].linkID = nil
                }
            }
        }
    }

    /// Insert a clip from the bin onto the active sequence at the given
    /// time. If the source has both video and audio, the two PlacedClips
    /// share a `linkID` so move/trim/delete/split act on the pair.
    ///
    /// Drop-overwrite semantics: any existing clips that overlap the new
    /// clip's timeline range on the destination tracks are split at the
    /// new clip's edges and their overlapping middle is removed
    /// (Premiere/Resolve behavior). Surviving fragments retain their
    /// linkID; tying audio fragments back to the corresponding video
    /// fragment is handled by `splitOverlappingClips` re-linking the
    /// before- and after-pieces with a fresh shared ID.
    public func insertClip(_ clipID: ClipID, atTime time: RationalTime, videoTrackIndex: Int = 0) {
        guard let source = project.mediaPool.clips[clipID] else { return }
        guard let sequenceIndex = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        pushUndoSnapshot()

        let hasVideo = !source.videoTracks.isEmpty
        let hasAudio = !source.audioTracks.isEmpty
        let linkID: UUID? = (hasVideo && hasAudio) ? UUID() : nil

        let timelineRange = TimeRange(start: time, duration: source.duration)
        var sequence = project.sequences[sequenceIndex]

        // Audio target mirrors video target — V2 video pairs with A2
        // audio, etc. — so dropping above V1 doesn't trample A1's
        // existing audio.
        let audioTrackIndex = hasVideo ? videoTrackIndex : 0

        // Ensure the target video track index exists. If it's past the
        // end (i.e. user dragged above existing tracks), append empty
        // tracks up to that index.
        while videoTrackIndex >= sequence.videoTracks.count && hasVideo {
            sequence.videoTracks.append(VideoTrack(name: "V\(sequence.videoTracks.count + 1)"))
        }
        // Same for audio: ensure the mirrored audio track exists.
        while audioTrackIndex >= sequence.audioTracks.count && hasAudio {
            sequence.audioTracks.append(AudioTrack(name: "A\(sequence.audioTracks.count + 1)"))
        }

        if hasVideo, sequence.videoTracks.indices.contains(videoTrackIndex) {
            splitOverlappingClips(in: &sequence.videoTracks[videoTrackIndex].clips, removingRange: timelineRange)
            sequence.videoTracks[videoTrackIndex].clips.append(PlacedClip(
                sourceClipID: clipID,
                sourceRange: TimeRange(start: .zero, duration: source.duration),
                timelineRange: timelineRange,
                linkID: linkID
            ))
            sequence.videoTracks[videoTrackIndex].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
        if hasAudio, sequence.audioTracks.indices.contains(audioTrackIndex) {
            splitOverlappingClips(in: &sequence.audioTracks[audioTrackIndex].clips, removingRange: timelineRange)
            sequence.audioTracks[audioTrackIndex].clips.append(PlacedClip(
                sourceClipID: clipID,
                sourceRange: TimeRange(start: .zero, duration: source.duration),
                timelineRange: timelineRange,
                linkID: linkID
            ))
            sequence.audioTracks[audioTrackIndex].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
        project.sequences[sequenceIndex] = sequence
        project.modifiedAt = Date()
        audio.invalidate(); sourceAudio.invalidate()
        markDirty()
    }

    /// Slice any clip in `clips` that overlaps `range` so the
    /// overlapping span is removed. A clip that's fully covered by
    /// `range` is deleted. A clip that straddles `range.start` is
    /// trimmed back to end at `range.start`. A clip that straddles
    /// `range.end` is trimmed forward to start at `range.end`. A clip
    /// that contains `range` entirely is split into two — a left piece
    /// ending at `range.start` and a right piece starting at `range.end`.
    /// After a clip drag or trim, slice every other clip on the same
    /// track whose range overlaps the dragged clip's range. This is the
    /// "overwrite" half of "snap or overwrite" — same-track coexistence
    /// is never allowed. Called from the timeline's mouseUp.
    public func finalizeOverlapsForClip(_ id: PlacedClipID) {
        // Linked siblings move together — include them so a V/A pair
        // overwrites underlying clips on both tracks symmetrically.
        let allIDs = expandToLinked([id])
        updateSequenceWithoutUndo { sequence in
            for cid in allIDs {
                // Find which track this clip lives on.
                for vIdx in sequence.videoTracks.indices {
                    if let clip = sequence.videoTracks[vIdx].clips.first(where: { $0.id == cid }) {
                        Self.sliceOthersOnTrack(
                            keeping: cid,
                            range: clip.timelineRange,
                            in: &sequence.videoTracks[vIdx].clips
                        )
                    }
                }
                for aIdx in sequence.audioTracks.indices {
                    if let clip = sequence.audioTracks[aIdx].clips.first(where: { $0.id == cid }) {
                        Self.sliceOthersOnTrack(
                            keeping: cid,
                            range: clip.timelineRange,
                            in: &sequence.audioTracks[aIdx].clips
                        )
                    }
                }
            }
        }
    }

    /// Variant of `updateSequence` that does NOT push an undo snapshot.
    /// Used by finalizers that run inside an existing undo batch (the
    /// outer `beginUndoBatch` already snapshotted the pre-edit state).
    private func updateSequenceWithoutUndo(_ mutate: (inout Sequence) -> Void) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        var sequence = project.sequences[idx]
        mutate(&sequence)
        project.sequences[idx] = sequence
        project.modifiedAt = Date()
        audio.invalidate(); sourceAudio.invalidate()
        markDirty()
        invalidatePreRenderCache(for: sequence.id)
    }

    /// Wipe every cached pre-render segment for the given sequence.
    /// Called from every mutation path that could change what frames
    /// the compositor would produce. Cheap when the cache is empty;
    /// O(num_segments) FileManager ops otherwise.
    private func invalidatePreRenderCache(for sequenceID: SequenceID) {
        PreRenderCache.clearAll(forProjectID: project.id, sequenceID: sequenceID)
        if sequenceID == activeSequenceID { refreshRenderSegmentCache() }
    }

    /// Pull `keepID` out, run `splitOverlappingClips` on the rest, then
    /// put `keepID` back. Keeps the dragged clip's range intact.
    nonisolated private static func sliceOthersOnTrack(
        keeping keepID: PlacedClipID,
        range: TimeRange,
        in clips: inout [PlacedClip]
    ) {
        guard let keepIdx = clips.firstIndex(where: { $0.id == keepID }) else { return }
        let keep = clips[keepIdx]
        var others = clips
        others.remove(at: keepIdx)
        splitOverlappingClipsStatic(in: &others, removingRange: range)
        others.append(keep)
        others.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        clips = others
    }

    nonisolated private static func splitOverlappingClipsStatic(in clips: inout [PlacedClip], removingRange range: TimeRange) {
        var result: [PlacedClip] = []
        result.reserveCapacity(clips.count + 2)
        let rangeStart = range.start.seconds
        let rangeEnd = range.end.seconds
        for clip in clips {
            let cs = clip.timelineRange.start.seconds
            let ce = clip.timelineRange.end.seconds
            if ce <= rangeStart || cs >= rangeEnd { result.append(clip); continue }
            if cs >= rangeStart && ce <= rangeEnd { continue }
            if cs < rangeStart && ce > rangeStart && ce <= rangeEnd {
                let newDur = rangeStart - cs
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(start: clip.sourceRange.start, duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)),
                    timelineRange: TimeRange(start: clip.timelineRange.start, duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)),
                    isEnabled: clip.isEnabled, effects: clip.effects,
                    transitionIn: clip.transitionIn, transitionOut: nil,
                    linkID: clip.linkID
                ))
                continue
            }
            if cs >= rangeStart && cs < rangeEnd && ce > rangeEnd {
                let consumed = rangeEnd - cs
                let newSourceStart = clip.sourceRange.start.seconds + consumed
                let newDur = ce - rangeEnd
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(start: RationalTime(value: Int64(newSourceStart * 1000), scale: 1000), duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)),
                    timelineRange: TimeRange(start: RationalTime(value: Int64(rangeEnd * 1000), scale: 1000), duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)),
                    isEnabled: clip.isEnabled, effects: clip.effects,
                    transitionIn: nil, transitionOut: clip.transitionOut,
                    linkID: clip.linkID
                ))
                continue
            }
            if cs < rangeStart && ce > rangeEnd {
                let leftDur = rangeStart - cs
                let rightDur = ce - rangeEnd
                let consumedForRight = rangeEnd - cs
                let rightSourceStart = clip.sourceRange.start.seconds + consumedForRight
                let rightLinkID = UUID()
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(start: clip.sourceRange.start, duration: RationalTime(value: Int64(leftDur * 1000), scale: 1000)),
                    timelineRange: TimeRange(start: clip.timelineRange.start, duration: RationalTime(value: Int64(leftDur * 1000), scale: 1000)),
                    isEnabled: clip.isEnabled, effects: clip.effects,
                    transitionIn: clip.transitionIn, transitionOut: nil,
                    linkID: clip.linkID
                ))
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(start: RationalTime(value: Int64(rightSourceStart * 1000), scale: 1000), duration: RationalTime(value: Int64(rightDur * 1000), scale: 1000)),
                    timelineRange: TimeRange(start: RationalTime(value: Int64(rangeEnd * 1000), scale: 1000), duration: RationalTime(value: Int64(rightDur * 1000), scale: 1000)),
                    isEnabled: clip.isEnabled, effects: clip.effects,
                    transitionIn: nil, transitionOut: clip.transitionOut,
                    linkID: rightLinkID
                ))
                continue
            }
        }
        clips = result
    }

    private func splitOverlappingClips(in clips: inout [PlacedClip], removingRange range: TimeRange) {
        var result: [PlacedClip] = []
        result.reserveCapacity(clips.count + 2)
        let rangeStart = range.start.seconds
        let rangeEnd = range.end.seconds

        for clip in clips {
            let cs = clip.timelineRange.start.seconds
            let ce = clip.timelineRange.end.seconds

            // No overlap
            if ce <= rangeStart || cs >= rangeEnd {
                result.append(clip)
                continue
            }
            // Fully covered: drop
            if cs >= rangeStart && ce <= rangeEnd {
                continue
            }
            // Straddles range.start: trim back to end at rangeStart
            if cs < rangeStart && ce > rangeStart && ce <= rangeEnd {
                let newDur = rangeStart - cs
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(
                        start: clip.sourceRange.start,
                        duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)
                    ),
                    timelineRange: TimeRange(
                        start: clip.timelineRange.start,
                        duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)
                    ),
                    isEnabled: clip.isEnabled,
                    effects: clip.effects,
                    transitionIn: clip.transitionIn,
                    transitionOut: nil,
                    linkID: clip.linkID
                ))
                continue
            }
            // Straddles range.end: trim forward to start at rangeEnd
            if cs >= rangeStart && cs < rangeEnd && ce > rangeEnd {
                let consumed = rangeEnd - cs
                let newSourceStart = clip.sourceRange.start.seconds + consumed
                let newDur = ce - rangeEnd
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(
                        start: RationalTime(value: Int64(newSourceStart * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)
                    ),
                    timelineRange: TimeRange(
                        start: RationalTime(value: Int64(rangeEnd * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)
                    ),
                    isEnabled: clip.isEnabled,
                    effects: clip.effects,
                    transitionIn: nil,
                    transitionOut: clip.transitionOut,
                    linkID: clip.linkID
                ))
                continue
            }
            // Contains the range entirely: split into left + right
            if cs < rangeStart && ce > rangeEnd {
                let leftDur = rangeStart - cs
                let rightDur = ce - rangeEnd
                let consumedForRight = rangeEnd - cs
                let rightSourceStart = clip.sourceRange.start.seconds + consumedForRight

                // Left piece keeps original linkID
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(
                        start: clip.sourceRange.start,
                        duration: RationalTime(value: Int64(leftDur * 1000), scale: 1000)
                    ),
                    timelineRange: TimeRange(
                        start: clip.timelineRange.start,
                        duration: RationalTime(value: Int64(leftDur * 1000), scale: 1000)
                    ),
                    isEnabled: clip.isEnabled,
                    effects: clip.effects,
                    transitionIn: clip.transitionIn,
                    transitionOut: nil,
                    linkID: clip.linkID
                ))
                // Right piece gets a fresh linkID so it stays grouped
                // with the corresponding right-half on the other lane
                // (set by the caller on a per-insert basis).
                let rightLink = clip.linkID.map { _ in UUID() }
                result.append(PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(
                        start: RationalTime(value: Int64(rightSourceStart * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(rightDur * 1000), scale: 1000)
                    ),
                    timelineRange: TimeRange(
                        start: RationalTime(value: Int64(rangeEnd * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(rightDur * 1000), scale: 1000)
                    ),
                    isEnabled: clip.isEnabled,
                    effects: clip.effects,
                    transitionIn: nil,
                    transitionOut: clip.transitionOut,
                    linkID: rightLink
                ))
                continue
            }
        }
        clips = result
    }

    // MARK: - Link expansion helpers

    /// Given a set of clip IDs, returns that set plus every other clip
    /// that shares a `linkID` with any clip in the set.
    private func expandToLinked(_ ids: Set<PlacedClipID>) -> Set<PlacedClipID> {
        guard let seq = activeSequence else { return ids }
        let allClips = seq.videoTracks.flatMap(\.clips) + seq.audioTracks.flatMap(\.clips)
        let selectedLinkIDs = Set(allClips.filter { ids.contains($0.id) }.compactMap(\.linkID))
        guard !selectedLinkIDs.isEmpty else { return ids }
        var expanded = ids
        for clip in allClips {
            if let lid = clip.linkID, selectedLinkIDs.contains(lid) {
                expanded.insert(clip.id)
            }
        }
        return expanded
    }

    public func setPlayhead(_ time: RationalTime) {
        // User-driven seek/scrub (not the 60Hz playback tick): refresh the
        // whole tree once so the inspector / overlay / selection-dependent
        // views update. The didSet still drives the clock + timeline line.
        objectWillChange.send()
        playheadTime = time
    }

    /// Playhead time to compose at this instant, computed straight from
    /// the wall clock. The render display link calls this so it samples a
    /// smooth, monotonic value at its OWN cadence — rather than reading
    /// `playheadTime`, which is advanced by a separate playback display
    /// link at a different phase (through a `Task { @MainActor }` hop).
    /// Sampling one 120Hz clock from another out-of-phase one produced
    /// uneven 4/5/6-tick frame holds = the playback staccato. Falls back
    /// to the stored playhead when not in program playback.
    public func composePlayheadSeconds() -> Double {
        guard case .program(let rate) = playbackState else { return playheadTime.seconds }
        let elapsed = CACurrentMediaTime() - playStartHostTime
        let latency = (abs(rate - 1.0) < 0.01) ? audio.outputLatencySeconds : 0
        return max(0, playStartSeconds + elapsed * rate - latency)
    }

    // MARK: - Playback state machine
    //
    // All transitions go through `setPlayback`. It:
    //   1. Tears down whatever was running.
    //   2. Bumps the generation counter so any pending async Tasks bail.
    //   3. Starts the new mode.
    //
    // Direct callers (togglePlay, focusedPlayForward, etc.) just build
    // a target PlaybackState and call setPlayback.

    private func setPlayback(_ newState: PlaybackState) {
        playbackGen &+= 1
        tearDownCurrentPlayback()
        playbackState = newState
        switch newState {
        case .stopped:
            return
        case .program(let rate):
            startProgramPlayback(rate: rate)
        case .source(let rate):
            startSourcePlayback(rate: rate)
        }
    }

    private func tearDownCurrentPlayback() {
        if audio.transport.isPlaying { audio.stop() }
        if sourceAudio.transport.isPlaying { sourceAudio.stop() }
        if let link = playbackDisplayLink {
            CVDisplayLinkStop(link)
            playbackDisplayLink = nil
        }
    }

    private func startProgramPlayback(rate: Double) {
        guard let sequence = activeSequence else {
            playbackState = .stopped
            return
        }
        let mediaPool = project.mediaPool
        playStartHostTime = CACurrentMediaTime()
        playStartSeconds = playheadTime.seconds
        let myGen = playbackGen

        if abs(rate - 1.0) < 0.01 {
            // Forward 1× — drive through the audio engine.
            Task { @MainActor in
                await audio.sync(to: sequence, mediaPool: mediaPool, startPlayheadSeconds: playStartSeconds)
                // User may have hit K (or J or anything else) during the
                // sync. If our generation is stale, the desired state has
                // already changed — bail without starting the engine.
                guard myGen == playbackGen else { return }
                audio.play()
                // Re-anchor wall clock so a slow sync doesn't make the
                // first tick race forward.
                playStartHostTime = CACurrentMediaTime()
                playStartSeconds = playheadTime.seconds
                startDisplayLinkForProgram(generation: myGen)
            }
        } else {
            // Non-1× shuttle (any speed, any direction): silent wall-clock.
            startDisplayLinkForProgram(generation: myGen)
        }
    }

    private func startSourcePlayback(rate: Double) {
        guard let clip = sourceClip else {
            playbackState = .stopped
            return
        }
        playStartHostTime = CACurrentMediaTime()
        playStartSeconds = sourceTimeSeconds
        let myGen = playbackGen

        if abs(rate - 1.0) < 0.01, !clip.audioTracks.isEmpty {
            // 1× with audio: drive through the source audio engine so
            // the visible playhead, audible playback, and the PPE
            // viewer all share one clock.
            Task { @MainActor in
                await sourceAudio.sync(to: clip, startSeconds: playStartSeconds)
                guard myGen == playbackGen else { return }
                sourceAudio.play()
                playStartHostTime = CACurrentMediaTime()
                playStartSeconds = sourceTimeSeconds
                startDisplayLinkForSource(generation: myGen)
            }
        } else {
            // No audio track (or non-1× shuttle): plain wall-clock.
            startDisplayLinkForSource(generation: myGen)
        }
    }

    private func startDisplayLinkForProgram(generation: UInt64) {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            Task { @MainActor in
                guard generation == self.playbackGen else { return }
                self.programTick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        playbackDisplayLink = link
    }

    private func startDisplayLinkForSource(generation: UInt64) {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            Task { @MainActor in
                guard generation == self.playbackGen else { return }
                self.sourceTick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
        playbackDisplayLink = link
    }

    private func programTick() {
        guard case .program(let rate) = playbackState else { return }
        // If the audio engine stopped on its own (end of timeline), mirror.
        if abs(rate - 1.0) < 0.01, !audio.transport.isPlaying {
            setPlayback(.stopped)
            return
        }
        let elapsed = CACurrentMediaTime() - playStartHostTime
        let latencyOffset = (abs(rate - 1.0) < 0.01) ? audio.outputLatencySeconds : 0
        let new = playStartSeconds + elapsed * rate - latencyOffset
        if new <= 0 {
            playheadTime = .zero
            setPlayback(.stopped)
            return
        }
        if let seq = activeSequence {
            let allClips = seq.videoTracks.flatMap(\.clips) + seq.audioTracks.flatMap(\.clips)
            let endSeconds = allClips.map { $0.timelineRange.end.seconds }.max() ?? 0
            if endSeconds > 0, new >= endSeconds {
                playheadTime = RationalTime(value: Int64(endSeconds * 1000), scale: 1000)
                setPlayback(.stopped)
                return
            }
        }
        let q = RationalTime(value: Int64(new * 1000), scale: 1000)
        if q != playheadTime { playheadTime = q }
    }

    private func sourceTick() {
        guard case .source(let rate) = playbackState else { return }
        guard let clip = sourceClip else { setPlayback(.stopped); return }
        // Mirror the program viewer's tick: when running 1× through
        // the audio engine, the visible playhead follows wall-clock
        // minus output latency so what you see lines up with what
        // you hear. End-of-clip detection uses the audio engine's
        // own playing state.
        if abs(rate - 1.0) < 0.01, !clip.audioTracks.isEmpty {
            if !sourceAudio.transport.isPlaying {
                setPlayback(.stopped)
                return
            }
            let elapsed = CACurrentMediaTime() - playStartHostTime
            let latencyOffset = sourceAudio.outputLatencySeconds
            let new = playStartSeconds + elapsed * rate - latencyOffset
            let maxSeconds = clip.duration.seconds
            if new <= 0 {
                sourceTimeSeconds = 0
                setPlayback(.stopped)
            } else if new >= maxSeconds {
                sourceTimeSeconds = maxSeconds
                setPlayback(.stopped)
            } else if new != sourceTimeSeconds {
                sourceTimeSeconds = new
            }
            return
        }
        let elapsed = CACurrentMediaTime() - playStartHostTime
        let new = playStartSeconds + elapsed * rate
        let maxSeconds = clip.duration.seconds
        if new < 0 {
            sourceTimeSeconds = 0
            setPlayback(.stopped)
        } else if new > maxSeconds {
            sourceTimeSeconds = maxSeconds
            setPlayback(.stopped)
        } else if new != sourceTimeSeconds {
            sourceTimeSeconds = new
        }
    }

    // MARK: - Source playback (compat wrappers)

    public func playSource(rate: Double = 1.0) {
        setPlayback(.source(rate: rate))
    }

    public func stopSource() {
        if case .source = playbackState { setPlayback(.stopped) }
    }

    public func toggleSourcePlay() {
        if case .source = playbackState { setPlayback(.stopped) }
        else if sourceClip != nil { setPlayback(.source(rate: 1.0)) }
    }

    // MARK: - Focused-viewer transport routing

    public func toggleFocusedPlay() {
        // If anything is playing, stop. Otherwise start the focused viewer.
        if isPlaying { setPlayback(.stopped); return }
        switch focusedViewer {
        case .source where sourceClip != nil:
            setPlayback(.source(rate: 1.0))
        default:
            setPlayback(.program(rate: 1.0))
        }
    }

    /// J/K/L "L" — play forward. If already playing forward, increment
    /// the rate (1× → 2× → 3× → 4×, then caps).
    public func focusedPlayForward() {
        let nextRate: Double = {
            let current = playbackState.rate
            if current >= 1.0 { return min(4.0, floor(current) + 1.0) }
            return 1.0
        }()
        switch focusedViewer {
        case .source where sourceClip != nil:
            setPlayback(.source(rate: nextRate))
        default:
            setPlayback(.program(rate: nextRate))
        }
    }

    /// J/K/L "J" — play reverse. If already reversing, step faster
    /// (-1× → -2× → -3× → -4×, then caps). Reverse is silent for v0.1.
    public func focusedPlayReverse() {
        let nextRate: Double = {
            let current = playbackState.rate
            if current <= -1.0 { return max(-4.0, floor(current) - 1.0) }
            return -1.0
        }()
        switch focusedViewer {
        case .source where sourceClip != nil:
            setPlayback(.source(rate: nextRate))
        default:
            setPlayback(.program(rate: nextRate))
        }
    }

    /// J/K/L "K" — stop. Always stops everything; targets don't matter.
    public func focusedStop() {
        setPlayback(.stopped)
    }

    public func focusedJumpFrames(_ delta: Int) {
        switch focusedViewer {
        case .source where sourceClip != nil:
            nudgeSourcePlayhead(by: delta)
        default:
            nudgePlayhead(framesAt: activeSequence?.settings.frameRate ?? .twentyFour, by: delta)
        }
    }

    public func nudgeSourcePlayhead(by delta: Int) {
        guard let clip = sourceClip else { return }
        let rate = clip.videoTracks.first?.frameRate ?? .twentyFour
        let frameDur = Double(rate.rationalScale) / Double(rate.rationalRate)
        let new = max(0, min(clip.duration.seconds, sourceTimeSeconds + frameDur * Double(delta)))
        sourceTimeSeconds = new
    }

    // MARK: - Source viewer marks & 3-point edit

    public func setSourceIn() {
        sourceInMark = sourceTimeSeconds
        if let out = sourceOutMark, out <= sourceTimeSeconds {
            sourceOutMark = nil
        }
    }

    public func setSourceOut() {
        sourceOutMark = sourceTimeSeconds
        if let inMark = sourceInMark, inMark >= sourceTimeSeconds {
            sourceInMark = nil
        }
    }

    public func clearSourceMarks() {
        sourceInMark = nil
        sourceOutMark = nil
    }

    /// Load a clip into the Source viewer (a click / double-click). Resets
    /// the playhead + marks + playback when the clip actually changes.
    /// Distinct from `skimSource`, which keeps following the cursor.
    public func loadSourceClip(_ clip: ClipSource) {
        let changing = sourceClip?.id != clip.id
        sourceClip = clip
        focusedViewer = .source
        if changing {
            sourceTimeSeconds = 0
            clearSourceMarks()
            stopSource()
        }
    }

    /// Skim: make `clip` the active source and move its playhead to
    /// `seconds`, WITHOUT the load reset (so the playhead follows the
    /// cursor). Marks are cleared only when crossing to a new clip.
    public func skimSource(to clip: ClipSource, seconds: Double) {
        if sourceClip?.id != clip.id {
            sourceClip = clip
            clearSourceMarks()
            stopSource()
        }
        let t = max(0, min(clip.duration.seconds, seconds))
        if sourceTimeSeconds != t { sourceTimeSeconds = t }
    }

    // MARK: - Favorites (FCP-style subclips)

    /// Mutate a source clip in the media pool and keep the published
    /// `sourceClip` copy in sync so the bin + source viewer refresh.
    private func updateClipSource(_ id: ClipID, _ mutate: (inout ClipSource) -> Void) {
        guard var clip = project.mediaPool.clips[id] else { return }
        mutate(&clip)
        project.mediaPool.clips[id] = clip
        if sourceClip?.id == id { sourceClip = clip }
        project.modifiedAt = Date()
        markDirty()
    }

    /// Favorite the current source In/Out selection (full duration if
    /// unmarked) on the active source clip. Many favorites can be made
    /// from one clip. After favoriting, marks are cleared so the next
    /// selection starts fresh (FCP behavior).
    @discardableResult
    public func favoriteSourceSelection(rating: FavoriteRange.Rating = .favorite) -> FavoriteRange? {
        guard let source = sourceClip else { return nil }
        let total = source.duration.seconds
        let s = max(0, min(sourceInMark ?? 0, total))
        let e = max(s, min(sourceOutMark ?? total, total))
        let dur = e - s
        guard dur > 0.04 else { return nil }
        let range = TimeRange(start: RationalTime(seconds: s), duration: RationalTime(seconds: dur))
        let existing = source.favorites.filter { $0.rating == rating }.count
        let label = rating == .favorite ? "Favorite" : "Reject"
        let fav = FavoriteRange(range: range, name: "\(label) \(existing + 1)", rating: rating)
        updateClipSource(source.id) { $0.favorites.append(fav) }
        clearSourceMarks()
        return fav
    }

    public func removeFavorite(_ favoriteID: UUID, from clipID: ClipID) {
        updateClipSource(clipID) { $0.favorites.removeAll { $0.id == favoriteID } }
    }

    public func renameFavorite(_ favoriteID: UUID, in clipID: ClipID, to name: String) {
        updateClipSource(clipID) { clip in
            if let i = clip.favorites.firstIndex(where: { $0.id == favoriteID }) {
                clip.favorites[i].name = name
            }
        }
    }

    /// Insert source clip's [in, out] (or full duration if marks unset)
    /// at the program playhead, rippling downstream clips forward.
    public func insertFromSource() {
        guard let source = sourceClip else { return }
        let range = effectiveSourceRange(for: source)
        guard range.duration > 0.04 else { return }
        place(source: source, sourceRange: range, atPlayhead: true, overwrite: false)
    }

    /// Overwrite at the program playhead with the source clip's
    /// [in, out] range. Replaces any clips that overlap that span.
    public func overwriteFromSource() {
        guard let source = sourceClip else { return }
        let range = effectiveSourceRange(for: source)
        guard range.duration > 0.04 else { return }
        place(source: source, sourceRange: range, atPlayhead: true, overwrite: true)
    }

    private func effectiveSourceRange(for source: ClipSource) -> (start: Double, duration: Double) {
        let total = source.duration.seconds
        let s = sourceInMark ?? 0
        let e = sourceOutMark ?? total
        let start = max(0, min(s, total))
        let end = max(start, min(e, total))
        return (start, end - start)
    }

    // MARK: - Program (sequence) marks

    /// Read-only seconds accessors so the timeline view and program
    /// viewer can render the In/Out band without reaching into the
    /// project tree.
    public var programInSeconds: Double? { activeSequence?.inMark?.seconds }
    public var programOutSeconds: Double? { activeSequence?.outMark?.seconds }

    public func setProgramIn() {
        let t = playheadTime
        mutateProgramMarks { seq in
            seq.inMark = t
            if let out = seq.outMark, out.seconds <= t.seconds {
                seq.outMark = nil
            }
        }
    }

    public func setProgramOut() {
        let t = playheadTime
        mutateProgramMarks { seq in
            seq.outMark = t
            if let inMark = seq.inMark, inMark.seconds >= t.seconds {
                seq.inMark = nil
            }
        }
    }

    public func clearProgramIn() {
        mutateProgramMarks { $0.inMark = nil }
    }

    public func clearProgramOut() {
        mutateProgramMarks { $0.outMark = nil }
    }

    public func clearProgramMarks() {
        mutateProgramMarks {
            $0.inMark = nil
            $0.outMark = nil
        }
    }

    /// Mark-only mutator. Skips the undo snapshot (marks are transient
    /// like the playhead) and the audio invalidate (marks don't affect
    /// playback yet) that `updateSequence` would force.
    private func mutateProgramMarks(_ mutate: (inout Sequence) -> Void) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        var sequence = project.sequences[idx]
        mutate(&sequence)
        project.sequences[idx] = sequence
        project.modifiedAt = Date()
        markDirty()
    }

    public func goToProgramIn() {
        guard let t = activeSequence?.inMark else { return }
        playheadTime = t
    }

    public func goToProgramOut() {
        guard let t = activeSequence?.outMark else { return }
        playheadTime = t
    }

    // MARK: - Pre-render In → Out

    /// Bake the sequence's In→Out range to a ProRes 422 LT segment in
    /// the per-project cache. Single source of truth for "render": the
    /// same `OfflineSequenceCompositor` will eventually feed the
    /// exporter and the cache-playback path.
    ///
    /// Range fallback when marks aren't set:
    /// - in & out both nil      → 0 to sequence end
    /// - in set, out nil        → in to sequence end
    /// - in nil, out set        → 0 to out
    /// - in & out set           → in to out
    public func renderInToOut() {
        guard let sequence = activeSequence else {
            renderError = "No active sequence."
            return
        }

        // Cancel any in-flight render before starting a new one. The
        // encoder's finally-block clears `activeEncoder`.
        if let prior = activeEncoder {
            prior.cancel()
            activeEncoder = nil
        }
        renderError = nil
        lastRenderURL = nil

        var (startSec, endSec) = renderRange(in: sequence)
        guard endSec > startSec + 0.001 else {
            renderError = "Render range is empty."
            return
        }
        // Snap the render start DOWN to a sequence frame boundary so the
        // cached segment's frame grid matches the live preview grid
        // (which quantizes the playhead to frames anchored at 0). A
        // non-frame-aligned In point otherwise leaves the cached frames
        // offset by up to one frame from live — a visible jump at the
        // cache↔live boundary.
        let fr = sequence.settings.frameRate
        let spf = Double(fr.rationalScale) / Double(max(1, fr.rationalRate))
        if spf > 0 {
            startSec = (startSec / spf).rounded(.down) * spf
            // End on a frame boundary too, so the cache↔live boundary
            // sits on the grid and the prewarm seeds the exact first
            // live frame.
            endSec = (endSec / spf).rounded(.up) * spf
        }

        let projectID = project.id
        let sequenceID = sequence.id
        let startMs = Int64(startSec * 1000)
        let endMs   = Int64(endSec * 1000)
        let outputURL = PreRenderCache.segmentURL(
            forProjectID: projectID,
            sequenceID: sequenceID,
            startMs: startMs,
            endMs: endMs
        )

        // Any older segments overlapping the new range get nuked so the
        // playback-substitution lookup can't pick a stale neighbour.
        PreRenderCache.invalidate(
            overlapping: startMs, endMs,
            forProjectID: projectID, sequenceID: sequenceID
        )
        if sequenceID == activeSequenceID { refreshRenderSegmentCache() }

        let encoder: SequenceEncoder
        do {
            encoder = try SequenceEncoder(sequence: sequence, mediaPool: project.mediaPool)
        } catch {
            renderError = error.localizedDescription
            return
        }
        activeEncoder = encoder
        renderProgress = 0

        // Pre-render cache always uses ProRes 422 LT at sequence specs
        // — fixed-rate, intra-only, fast scrub, and playable directly
        // by AVAssetReader for the substitution path.
        let options = SequenceEncoder.Options(
            outputURL: outputURL,
            videoCodec: .proRes422LT,
            width: sequence.settings.resolution.width,
            height: sequence.settings.resolution.height,
            frameRate: sequence.settings.frameRate,
            startSeconds: startSec,
            endSeconds: endSec,
            audioOutputSettings: Self.defaultPCMAudioOutputSettings(
                sampleRate: sequence.settings.audioSampleRate,
                channelCount: sequence.settings.audioChannelCount
            ),
            audioChannelCount: sequence.settings.audioChannelCount,
            audioSampleRate: sequence.settings.audioSampleRate,
            fileType: .mov,
            progress: { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.renderProgress = p
                }
            }
        )

        Task.detached { [weak self] in
            do {
                try await encoder.encode(options)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.renderProgress = nil
                    self.lastRenderURL = outputURL
                    self.activeEncoder = nil
                    self.refreshRenderSegmentCache()
                    KineDebugLog.log("[Render] wrote \(outputURL.path)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.renderProgress = nil
                    self.activeEncoder = nil
                    self.renderError = error.localizedDescription
                    KineDebugLog.log("[Render] failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// PCM-float audio output settings for MOV containers. Used by the
    /// pre-render cache + Pro presets that want full-quality audio.
    nonisolated static func defaultPCMAudioOutputSettings(sampleRate: Int, channelCount: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    public func cancelRender() {
        activeEncoder?.cancel()
    }

    /// Export the active sequence using the same offline pipeline that
    /// backs Render In to Out. Driven by the new export sheet — the
    /// sheet builds an `ExportSettings`, we translate it into
    /// `SequenceEncoder.Options`, and kick off the encode.
    public func exportSequence(_ settings: ExportSettings) {
        guard let sequence = activeSequence else {
            renderError = "No active sequence."
            return
        }
        guard let outputURL = settings.outputURL else {
            renderError = "No output destination chosen."
            return
        }
        if let prior = activeEncoder {
            prior.cancel()
            activeEncoder = nil
        }
        renderError = nil
        lastRenderURL = nil

        let (startSec, endSec): (Double, Double)
        switch settings.range {
        case .inToOut:       (startSec, endSec) = renderRange(in: sequence)
        case .wholeSequence: (startSec, endSec) = (0, sequenceEndSeconds(sequence))
        }
        guard endSec > startSec + 0.001 else {
            renderError = "Export range is empty."
            return
        }

        let encoder: SequenceEncoder
        do {
            encoder = try SequenceEncoder(sequence: sequence, mediaPool: project.mediaPool)
        } catch {
            renderError = error.localizedDescription
            return
        }
        activeEncoder = encoder
        renderProgress = 0

        let options = Self.encoderOptions(
            from: settings, sequence: sequence,
            startSec: startSec, endSec: endSec,
            outputURL: outputURL,
            progress: { [weak self] p in
                Task { @MainActor [weak self] in
                    self?.renderProgress = p
                }
            }
        )

        Task.detached { [weak self] in
            do {
                try await encoder.encode(options)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.renderProgress = nil
                    self.lastRenderURL = outputURL
                    self.activeEncoder = nil
                    KineDebugLog.log("[Export] wrote \(outputURL.path)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.renderProgress = nil
                    self.activeEncoder = nil
                    self.renderError = error.localizedDescription
                    KineDebugLog.log("[Export] failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Translate the sheet's `ExportSettings` into the lower-level
    /// `SequenceEncoder.Options`. Centralised so the sheet's UI choices
    /// + the encoder's tunables stay in lockstep.
    private static func encoderOptions(
        from settings: ExportSettings,
        sequence: Sequence,
        startSec: Double, endSec: Double,
        outputURL: URL,
        progress: @escaping (Double) -> Void
    ) -> SequenceEncoder.Options {
        let (w, h) = settings.video.resolution.dimensions(seq: sequence)
        let fr = settings.video.frameRateMode.frameRate(seq: sequence)
        let audioChannels = settings.audio.channels.count
        let audioRate = settings.audio.sampleRate.hz(seq: sequence)

        let fileType: AVFileType
        let audioSettings: [String: Any]?

        if settings.isAudioOnly {
            switch settings.audio.codec {
            case .wav:
                fileType = .wav
                audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: audioRate,
                    AVNumberOfChannelsKey: audioChannels,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            case .aiff:
                fileType = .aiff
                audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: audioRate,
                    AVNumberOfChannelsKey: audioChannels,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            case .aac:
                fileType = .m4a
                audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioRate,
                    AVNumberOfChannelsKey: audioChannels,
                    AVEncoderBitRateKey: settings.audio.bitrateKbps * 1000,
                ]
            case .pcm:
                // Treat PCM in audio-only mode as WAV (PCM-in-MOV makes
                // no sense without a video track).
                fileType = .wav
                audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: audioRate,
                    AVNumberOfChannelsKey: audioChannels,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            }
            return SequenceEncoder.Options(
                outputURL: outputURL,
                videoCodec: nil,
                width: w, height: h,
                frameRate: fr,
                startSeconds: startSec,
                endSeconds: endSec,
                audioOutputSettings: audioSettings,
                audioChannelCount: audioChannels,
                audioSampleRate: audioRate,
                fileType: fileType,
                progress: progress
            )
        }

        // Video + audio in MOV. The output-settings builder varies only
        // the channel count, so multi-track export can build one dict per
        // track (channel count differs per track under preserve-channels).
        fileType = .mov
        let audioCodec = settings.audio.codec
        let bitrateKbps = settings.audio.bitrateKbps
        let movAudioSettings: @Sendable (Int) -> [String: Any] = { channels in
            switch audioCodec {
            case .pcm, .wav, .aiff:
                return Self.defaultPCMAudioOutputSettings(sampleRate: audioRate, channelCount: channels)
            case .aac:
                return [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: bitrateKbps * 1000,
                ]
            }
        }

        let multiTrack = settings.audio.include && settings.audio.layout.producesMultipleTracks
        if settings.audio.include {
            audioSettings = movAudioSettings(audioChannels)
        } else {
            audioSettings = nil
        }

        return SequenceEncoder.Options(
            outputURL: outputURL,
            videoCodec: settings.video.codec.av,
            videoBitrate: settings.video.bitrateMbps * 1_000_000,
            videoMaximumBitrate: settings.video.maximumBitrateMbps * 1_000_000,
            videoH264Profile: settings.video.profile.avProfileLevel,
            keyframeIntervalFrames: settings.video.keyframeIntervalFrames,
            width: w, height: h,
            frameRate: fr,
            startSeconds: startSec,
            endSeconds: endSec,
            audioOutputSettings: audioSettings,
            audioChannelCount: audioChannels,
            audioSampleRate: audioRate,
            audioMultiTrack: multiTrack,
            audioPreserveSourceChannels: settings.audio.layout.preservesSourceChannels,
            audioSettingsBuilder: multiTrack ? movAudioSettings : nil,
            fileType: fileType,
            progress: progress
        )
    }

    private func sequenceEndSeconds(_ sequence: Sequence) -> Double {
        let all = sequence.videoTracks.flatMap(\.clips) + sequence.audioTracks.flatMap(\.clips)
        return all.map { $0.timelineRange.end.seconds }.max() ?? 0
    }

    /// On-disk pre-render segment containing the current playhead, if
    /// any. Drives the program viewer's "cache playback" path.
    /// Cache segment covering `seconds`. The realtime host passes its
    /// FRAME-QUANTIZED compose time (not the raw playhead) so the
    /// cache↔live decision lands on the same frame the compositor will
    /// render — otherwise they disagree in the sub-frame sliver at a
    /// segment boundary and the boundary frame is duplicated.
    public func cacheSegment(atSeconds seconds: Double) -> (url: URL, startSeconds: Double, endSeconds: Double)? {
        let tMs = Int64(seconds * 1000)
        for seg in renderSegments() where seg.startMs <= tMs && tMs < seg.endMs {
            return (seg.url, Double(seg.startMs) / 1000.0, Double(seg.endMs) / 1000.0)
        }
        return nil
    }

    /// Every cached segment for the active sequence (start..end seconds).
    /// Used by the timeline ruler to render its green "rendered" bars.
    public func cacheSegmentsForActiveSequence() -> [(startSeconds: Double, endSeconds: Double)] {
        renderSegments().map { (Double($0.startMs) / 1000.0, Double($0.endMs) / 1000.0) }
    }

    // In-memory mirror of the on-disk pre-render segment list. Read by
    // the realtime tick and the ruler; refreshed only on mutation
    // (render complete, cache clear, sequence switch) so the hot path
    // never touches the filesystem.
    private var renderSegmentCache: [(url: URL, startMs: Int64, endMs: Int64)] = []
    private var renderSegmentCacheSequenceID: SequenceID?

    private func renderSegments() -> [(url: URL, startMs: Int64, endMs: Int64)] {
        if renderSegmentCacheSequenceID != activeSequenceID {
            refreshRenderSegmentCache()
        }
        return renderSegmentCache
    }

    private func refreshRenderSegmentCache() {
        guard let sequence = activeSequence else {
            renderSegmentCache = []
            renderSegmentCacheSequenceID = nil
            return
        }
        renderSegmentCache = PreRenderCache.allSegments(
            forProjectID: project.id, sequenceID: sequence.id)
        renderSegmentCacheSequenceID = sequence.id
    }

    private func renderRange(in sequence: Sequence) -> (Double, Double) {
        let endFallback: Double = {
            let allClips = sequence.videoTracks.flatMap(\.clips) + sequence.audioTracks.flatMap(\.clips)
            return allClips.map { $0.timelineRange.end.seconds }.max() ?? 0
        }()
        let inSec  = sequence.inMark?.seconds ?? 0
        let outSec = sequence.outMark?.seconds ?? endFallback
        return (max(0, inSec), max(inSec, outSec))
    }


    private func place(source: ClipSource, sourceRange: (start: Double, duration: Double), atPlayhead: Bool, overwrite: Bool) {
        guard let sequence = activeSequence else { return }
        let dropTime = atPlayhead ? playheadTime.seconds : 0
        let duration = sourceRange.duration

        let hasVideo = !source.videoTracks.isEmpty
        let hasAudio = !source.audioTracks.isEmpty
        let linkID: UUID? = (hasVideo && hasAudio) ? UUID() : nil

        let sRange = TimeRange(
            start: RationalTime(value: Int64(sourceRange.start * 1000), scale: 1000),
            duration: RationalTime(value: Int64(duration * 1000), scale: 1000)
        )
        let tRange = TimeRange(
            start: RationalTime(value: Int64(dropTime * 1000), scale: 1000),
            duration: RationalTime(value: Int64(duration * 1000), scale: 1000)
        )

        // Resolve the destination track indices via the user's target
        // toggles. Fall back to V1/A1 when nothing's targeted so a fresh
        // sequence or an imported project without target flags still
        // accepts 3-point edits.
        let vTarget = firstTargetedVideoIndex(in: sequence)
        let aTarget = firstTargetedAudioIndex(in: sequence)

        updateSequence { seq in
            if overwrite {
                if let v = vTarget, seq.videoTracks.indices.contains(v) {
                    seq.videoTracks[v].clips.removeAll { $0.timelineRange.overlaps(tRange) }
                }
                if let a = aTarget, seq.audioTracks.indices.contains(a) {
                    seq.audioTracks[a].clips.removeAll { $0.timelineRange.overlaps(tRange) }
                }
            } else {
                // Insert: ripple every clip whose start is >= dropTime forward by duration.
                ripple(seq: &seq, fromSeconds: dropTime, byPlusSeconds: duration)
            }

            if hasVideo, let v = vTarget, seq.videoTracks.indices.contains(v) {
                seq.videoTracks[v].clips.append(PlacedClip(
                    sourceClipID: source.id,
                    sourceRange: sRange,
                    timelineRange: tRange,
                    linkID: linkID
                ))
                seq.videoTracks[v].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
            }
            if hasAudio, let a = aTarget, seq.audioTracks.indices.contains(a) {
                seq.audioTracks[a].clips.append(PlacedClip(
                    sourceClipID: source.id,
                    sourceRange: sRange,
                    timelineRange: tRange,
                    linkID: linkID
                ))
                seq.audioTracks[a].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
            }
        }

        if !sequence.videoTracks.isEmpty || !sequence.audioTracks.isEmpty {
            playheadTime = RationalTime(value: Int64((dropTime + duration) * 1000), scale: 1000)
        }
    }

    /// First targeted video track index, falling back to V1 if no track
    /// is explicitly targeted. nil only when there are no video tracks.
    private func firstTargetedVideoIndex(in seq: Sequence) -> Int? {
        if let i = seq.videoTracks.firstIndex(where: { $0.isTargeted }) { return i }
        return seq.videoTracks.isEmpty ? nil : 0
    }

    private func firstTargetedAudioIndex(in seq: Sequence) -> Int? {
        if let i = seq.audioTracks.firstIndex(where: { $0.isTargeted }) { return i }
        return seq.audioTracks.isEmpty ? nil : 0
    }

    /// Set the active V target exclusively — only one V can be targeted
    /// at a time in the chip model. Clicking the same row toggles off,
    /// leaving no V targeted (insertFromSource falls back to V1).
    public func setVideoTarget(at index: Int) {
        updateSequence { sequence in
            guard sequence.videoTracks.indices.contains(index) else { return }
            let alreadyOnlyTarget = sequence.videoTracks[index].isTargeted
                && sequence.videoTracks.enumerated().allSatisfy { $0.offset == index || !$0.element.isTargeted }
            for i in sequence.videoTracks.indices {
                sequence.videoTracks[i].isTargeted = (i == index) && !alreadyOnlyTarget
            }
        }
    }

    public func setAudioTarget(at index: Int) {
        updateSequence { sequence in
            guard sequence.audioTracks.indices.contains(index) else { return }
            let alreadyOnlyTarget = sequence.audioTracks[index].isTargeted
                && sequence.audioTracks.enumerated().allSatisfy { $0.offset == index || !$0.element.isTargeted }
            for i in sequence.audioTracks.indices {
                sequence.audioTracks[i].isTargeted = (i == index) && !alreadyOnlyTarget
            }
        }
    }

    private func ripple(seq: inout Sequence, fromSeconds threshold: Double, byPlusSeconds delta: Double) {
        for vIdx in seq.videoTracks.indices {
            for cIdx in seq.videoTracks[vIdx].clips.indices {
                let clip = seq.videoTracks[vIdx].clips[cIdx]
                if clip.timelineRange.start.seconds >= threshold {
                    let newStart = clip.timelineRange.start.seconds + delta
                    seq.videoTracks[vIdx].clips[cIdx].timelineRange = TimeRange(
                        start: RationalTime(value: Int64(newStart * 1000), scale: 1000),
                        duration: clip.timelineRange.duration
                    )
                }
            }
            seq.videoTracks[vIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
        for aIdx in seq.audioTracks.indices {
            for cIdx in seq.audioTracks[aIdx].clips.indices {
                let clip = seq.audioTracks[aIdx].clips[cIdx]
                if clip.timelineRange.start.seconds >= threshold {
                    let newStart = clip.timelineRange.start.seconds + delta
                    seq.audioTracks[aIdx].clips[cIdx].timelineRange = TimeRange(
                        start: RationalTime(value: Int64(newStart * 1000), scale: 1000),
                        duration: clip.timelineRange.duration
                    )
                }
            }
            seq.audioTracks[aIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
    }

    // MARK: - Selection

    public func select(_ id: PlacedClipID, additive: Bool = false) {
        let target = expandToLinked([id])
        if additive { selectedClipIDs.formUnion(target) }
        else { selectedClipIDs = target }
        selectedGap = nil
        selectedCut = nil
        selectedClipEdge = nil
    }

    public func clearSelection() {
        selectedClipIDs = []
        selectedGap = nil
        selectedCut = nil
        selectedClipEdge = nil
    }

    /// Select a gap (empty space on a track). Mutually exclusive with
    /// clip selection — see `selectedGap` docs.
    public func selectGap(_ gap: GapSelection) {
        selectedClipIDs = []
        selectedCut = nil
        selectedClipEdge = nil
        selectedGap = gap
    }

    /// Select a cut (boundary between two abutting clips on a track).
    public func selectCut(_ cut: CutSelection) {
        selectedClipIDs = []
        selectedGap = nil
        selectedClipEdge = nil
        selectedCut = cut
    }

    /// Select a single clip's edge (in or out point). Used to drive
    /// right-click "Add Fade" menus for solo transitions.
    public func selectClipEdge(_ edge: ClipEdgeSelection) {
        selectedClipIDs = []
        selectedGap = nil
        selectedCut = nil
        selectedClipEdge = edge
    }

    /// Add a fade-in or fade-out to a single clip's edge. `side == .left`
    /// → transitionIn (fade from black at clip's start). `side == .right`
    /// → transitionOut (fade to black at clip's end). Duration comes
    /// from KineSettings; clamped to half the clip's own length;
    /// quantized to the active sequence's frame grid.
    public func applyFadeAtEdge(_ edge: ClipEdgeSelection, durationSeconds: Double? = nil) {
        let kind = KineSettings.shared.defaultTransitionKind
        let rawTotal = durationSeconds ?? KineSettings.shared.defaultTransitionSeconds(for: activeSequence)
        let total = max(quantizeToFrame(rawTotal), 1.0 / max(1.0, activeSequence?.settings.frameRate.fps ?? 30.0))
        let isVideo = edge.trackKind == 0
        updateSequence { sequence in
            func updateVideo(_ track: inout VideoTrack) {
                guard let i = track.clips.firstIndex(where: { $0.id == edge.clipID }) else { return }
                let clipDur = track.clips[i].timelineRange.duration.seconds
                let d = Self.clampHalf(total, neighborDuration: clipDur * 2)
                let t = Transition(kind: kind, duration: RationalTime(value: Int64(d * 1000), scale: 1000))
                switch edge.side {
                case .left:  track.clips[i].transitionIn = t
                case .right: track.clips[i].transitionOut = t
                }
            }
            func updateAudio(_ track: inout AudioTrack) {
                guard let i = track.clips.firstIndex(where: { $0.id == edge.clipID }) else { return }
                let clipDur = track.clips[i].timelineRange.duration.seconds
                let d = Self.clampHalf(total, neighborDuration: clipDur * 2)
                let t = Transition(kind: kind, duration: RationalTime(value: Int64(d * 1000), scale: 1000))
                switch edge.side {
                case .left:  track.clips[i].transitionIn = t
                case .right: track.clips[i].transitionOut = t
                }
            }
            if isVideo, edge.trackIndex < sequence.videoTracks.count {
                updateVideo(&sequence.videoTracks[edge.trackIndex])
            } else if !isVideo, edge.trackIndex < sequence.audioTracks.count {
                updateAudio(&sequence.audioTracks[edge.trackIndex])
            }
        }
    }

    /// Remove the fade at a clip's edge.
    public func removeFadeAtEdge(_ edge: ClipEdgeSelection) {
        let isVideo = edge.trackKind == 0
        updateSequence { sequence in
            func updateVideo(_ track: inout VideoTrack) {
                guard let i = track.clips.firstIndex(where: { $0.id == edge.clipID }) else { return }
                switch edge.side {
                case .left:  track.clips[i].transitionIn = nil
                case .right: track.clips[i].transitionOut = nil
                }
            }
            func updateAudio(_ track: inout AudioTrack) {
                guard let i = track.clips.firstIndex(where: { $0.id == edge.clipID }) else { return }
                switch edge.side {
                case .left:  track.clips[i].transitionIn = nil
                case .right: track.clips[i].transitionOut = nil
                }
            }
            if isVideo, edge.trackIndex < sequence.videoTracks.count {
                updateVideo(&sequence.videoTracks[edge.trackIndex])
            } else if !isVideo, edge.trackIndex < sequence.audioTracks.count {
                updateAudio(&sequence.audioTracks[edge.trackIndex])
            }
        }
    }

    /// Ripple-close the selected gap. Every clip across EVERY track
    /// whose start sits at or beyond the gap's end time slides left by
    /// the gap's duration. Closes the hole AND preserves V/A sync —
    /// shifting only the gap's own track would desync linked siblings.
    public func deleteSelectedGap() {
        guard let gap = selectedGap else { return }
        let threshold = gap.endSeconds
        let shift = gap.durationSeconds
        guard shift > 0 else { selectedGap = nil; return }
        updateSequence { sequence in
            for vIdx in sequence.videoTracks.indices {
                for cIdx in sequence.videoTracks[vIdx].clips.indices {
                    let clip = sequence.videoTracks[vIdx].clips[cIdx]
                    if clip.timelineRange.start.seconds >= threshold {
                        let newStart = max(0, clip.timelineRange.start.seconds - shift)
                        sequence.videoTracks[vIdx].clips[cIdx].timelineRange = TimeRange(
                            start: RationalTime(value: Int64(newStart * 1000), scale: 1000),
                            duration: clip.timelineRange.duration
                        )
                    }
                }
                sequence.videoTracks[vIdx].clips.sort {
                    $0.timelineRange.start.seconds < $1.timelineRange.start.seconds
                }
            }
            for aIdx in sequence.audioTracks.indices {
                for cIdx in sequence.audioTracks[aIdx].clips.indices {
                    let clip = sequence.audioTracks[aIdx].clips[cIdx]
                    if clip.timelineRange.start.seconds >= threshold {
                        let newStart = max(0, clip.timelineRange.start.seconds - shift)
                        sequence.audioTracks[aIdx].clips[cIdx].timelineRange = TimeRange(
                            start: RationalTime(value: Int64(newStart * 1000), scale: 1000),
                            duration: clip.timelineRange.duration
                        )
                    }
                }
                sequence.audioTracks[aIdx].clips.sort {
                    $0.timelineRange.start.seconds < $1.timelineRange.start.seconds
                }
            }
        }
        selectedGap = nil
    }

    // MARK: - Clip mutations

    /// Identifies a specific track in the active sequence (used when
    /// moveClip needs to also change which track the clip lives on).
    public enum TrackTarget: Equatable {
        case video(Int)
        case audio(Int)
    }

    /// Move a placed clip so its `timelineRange.start` becomes `newStart`.
    /// Linked siblings (V+A pairs) move horizontally by the same delta,
    /// but stay on their own tracks — only the directly-dragged clip
    /// can change track via `targetTrack`. If `targetTrack` doesn't
    /// match the dragged clip's media type (e.g. video clip dragged
    /// to an audio track) the track change is ignored.
    public func moveClip(_ id: PlacedClipID, to newStart: RationalTime, targetTrack: TrackTarget? = nil) {
        let linkedIDs = expandToLinked([id])

        updateSequence { sequence in
            guard let driver = findClip(id, in: sequence) else { return }
            let originalStart = driver.timelineRange.start.seconds
            let requested = max(0, newStart.seconds)
            var minLinkedStart = originalStart
            for cid in linkedIDs {
                if let c = findClip(cid, in: sequence) {
                    minLinkedStart = min(minLinkedStart, c.timelineRange.start.seconds)
                }
            }
            let maxNegativeShift = minLinkedStart
            var delta = requested - originalStart
            if delta < 0 { delta = max(delta, -maxNegativeShift) }

            // First, horizontal-shift every linked clip on its current track.
            for cid in linkedIDs {
                updatePlacedClip(cid, in: &sequence) { clip in
                    let newSec = clip.timelineRange.start.seconds + delta
                    clip.timelineRange = TimeRange(
                        start: RationalTime(value: Int64(newSec * 1000), scale: 1000),
                        duration: clip.timelineRange.duration
                    )
                }
            }
            for cid in linkedIDs {
                resortTracksContaining(cid, in: &sequence)
            }

            // Then, if requested, change ONLY the dragged clip's track.
            if let target = targetTrack {
                moveSingleClipToTrack(id, target: target, in: &sequence)
            }
        }
    }

    /// Move several clips to explicit new starts at once (horizontal
    /// multi-selection drag). Each clip keeps its track. Starts are already
    /// clamped/spaced by the caller; we just set + re-sort.
    public func moveSelectedClipsTo(_ targets: [(PlacedClipID, RationalTime)]) {
        guard !targets.isEmpty else { return }
        let map = Dictionary(targets, uniquingKeysWith: { a, _ in a })
        updateSequence { sequence in
            for vIdx in sequence.videoTracks.indices {
                for cIdx in sequence.videoTracks[vIdx].clips.indices {
                    let cid = sequence.videoTracks[vIdx].clips[cIdx].id
                    if let t = map[cid] {
                        sequence.videoTracks[vIdx].clips[cIdx].timelineRange = TimeRange(
                            start: t, duration: sequence.videoTracks[vIdx].clips[cIdx].timelineRange.duration)
                    }
                }
                sequence.videoTracks[vIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
            }
            for aIdx in sequence.audioTracks.indices {
                for cIdx in sequence.audioTracks[aIdx].clips.indices {
                    let cid = sequence.audioTracks[aIdx].clips[cIdx].id
                    if let t = map[cid] {
                        sequence.audioTracks[aIdx].clips[cIdx].timelineRange = TimeRange(
                            start: t, duration: sequence.audioTracks[aIdx].clips[cIdx].timelineRange.duration)
                    }
                }
                sequence.audioTracks[aIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
            }
        }
    }

    private func moveSingleClipToTrack(_ id: PlacedClipID, target: TrackTarget, in sequence: inout Sequence) {
        // Find current location + clip.
        var currentClip: PlacedClip?
        var currentVideoIdx: Int?
        var currentAudioIdx: Int?

        for (vIdx, track) in sequence.videoTracks.enumerated() {
            if let cIdx = track.clips.firstIndex(where: { $0.id == id }) {
                currentClip = track.clips[cIdx]
                currentVideoIdx = vIdx
                break
            }
        }
        if currentClip == nil {
            for (aIdx, track) in sequence.audioTracks.enumerated() {
                if let cIdx = track.clips.firstIndex(where: { $0.id == id }) {
                    currentClip = track.clips[cIdx]
                    currentAudioIdx = aIdx
                    break
                }
            }
        }
        guard let clip = currentClip else { return }

        // Disallow cross-kind moves (video clip → audio track or vice versa).
        switch target {
        case .video(let newIdx):
            guard let vIdx = currentVideoIdx else { return }       // it's an audio clip; ignore
            if vIdx == newIdx { return }                            // no change
            // Grow video tracks if needed
            while newIdx >= sequence.videoTracks.count {
                sequence.videoTracks.append(VideoTrack(name: "V\(sequence.videoTracks.count + 1)"))
            }
            sequence.videoTracks[vIdx].clips.removeAll { $0.id == id }
            // Slice any overlap on the destination
            splitOverlappingClips(in: &sequence.videoTracks[newIdx].clips, removingRange: clip.timelineRange)
            sequence.videoTracks[newIdx].clips.append(clip)
            sequence.videoTracks[newIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }

        case .audio(let newIdx):
            guard let aIdx = currentAudioIdx else { return }       // it's a video clip; ignore
            if aIdx == newIdx { return }
            while newIdx >= sequence.audioTracks.count {
                sequence.audioTracks.append(AudioTrack(name: "A\(sequence.audioTracks.count + 1)"))
            }
            sequence.audioTracks[aIdx].clips.removeAll { $0.id == id }
            splitOverlappingClips(in: &sequence.audioTracks[newIdx].clips, removingRange: clip.timelineRange)
            sequence.audioTracks[newIdx].clips.append(clip)
            sequence.audioTracks[newIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
    }

    private func findClip(_ id: PlacedClipID, in sequence: Sequence) -> PlacedClip? {
        for t in sequence.videoTracks {
            if let c = t.clips.first(where: { $0.id == id }) { return c }
        }
        for t in sequence.audioTracks {
            if let c = t.clips.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    /// Trim the left edge of a clip. Linked siblings trim by the same
    /// delta so V+A stays in sync.
    public func trimLeft(_ id: PlacedClipID, to newStart: RationalTime) {
        let linkedIDs = expandToLinked([id])
        updateSequence { sequence in
            guard let driver = findClip(id, in: sequence) else { return }
            let originalStart = driver.timelineRange.start.seconds
            let rightEdge = driver.timelineRange.end.seconds
            let proposed = max(0, min(newStart.seconds, rightEdge - 0.04))
            let delta = proposed - originalStart

            for cid in linkedIDs {
                updatePlacedClip(cid, in: &sequence) { clip in
                    let newStartSec = max(0, clip.timelineRange.start.seconds + delta)
                    let newSourceStartSec = max(0, clip.sourceRange.start.seconds + delta)
                    let consumedSource = newSourceStartSec - clip.sourceRange.start.seconds
                    let newSourceDur = max(0.04, clip.sourceRange.duration.seconds - consumedSource)
                    let newTimelineDur = max(0.04, clip.timelineRange.end.seconds - newStartSec)

                    clip.sourceRange = TimeRange(
                        start: RationalTime(value: Int64(newSourceStartSec * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(newSourceDur * 1000), scale: 1000)
                    )
                    clip.timelineRange = TimeRange(
                        start: RationalTime(value: Int64(newStartSec * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(newTimelineDur * 1000), scale: 1000)
                    )
                }
            }
            for cid in linkedIDs {
                resortTracksContaining(cid, in: &sequence)
            }
        }
    }

    /// Trim the right edge of a clip. Linked siblings trim by the same
    /// delta.
    public func trimRight(_ id: PlacedClipID, to newEnd: RationalTime) {
        let linkedIDs = expandToLinked([id])
        updateSequence { sequence in
            guard let driver = findClip(id, in: sequence) else { return }
            let leftEdge = driver.timelineRange.start.seconds
            let proposed = max(leftEdge + 0.04, newEnd.seconds)
            let delta = proposed - driver.timelineRange.end.seconds

            for cid in linkedIDs {
                updatePlacedClip(cid, in: &sequence) { clip in
                    let newDur = max(0.04, clip.timelineRange.duration.seconds + delta)
                    let newSourceDur = max(0.04, clip.sourceRange.duration.seconds + delta)
                    clip.sourceRange = TimeRange(
                        start: clip.sourceRange.start,
                        duration: RationalTime(value: Int64(newSourceDur * 1000), scale: 1000)
                    )
                    clip.timelineRange = TimeRange(
                        start: clip.timelineRange.start,
                        duration: RationalTime(value: Int64(newDur * 1000), scale: 1000)
                    )
                }
            }
        }
    }

    /// Remove selected clips from the active sequence. Leaves gaps.
    /// Linked siblings are removed too.
    public func deleteSelected() {
        let ids = expandToLinked(selectedClipIDs)
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for vIdx in sequence.videoTracks.indices {
                sequence.videoTracks[vIdx].clips.removeAll { ids.contains($0.id) }
            }
            for aIdx in sequence.audioTracks.indices {
                sequence.audioTracks[aIdx].clips.removeAll { ids.contains($0.id) }
            }
        }
        selectedClipIDs = []
    }

    /// Remove selected clips AND close the gap left behind — every clip on
    /// the same track whose start was greater than the removed clip's
    /// start shifts left by the removed duration. Linked siblings are
    /// removed together so V/A stays in sync after the ripple.
    public func rippleDeleteSelected() {
        let ids = expandToLinked(selectedClipIDs)
        guard !ids.isEmpty else { return }

        struct Removal { var trackIsVideo: Bool; var trackIdx: Int; var range: TimeRange }
        var removals: [Removal] = []

        updateSequence { sequence in
            for vIdx in sequence.videoTracks.indices {
                for clip in sequence.videoTracks[vIdx].clips where ids.contains(clip.id) {
                    removals.append(Removal(trackIsVideo: true, trackIdx: vIdx, range: clip.timelineRange))
                }
                sequence.videoTracks[vIdx].clips.removeAll { ids.contains($0.id) }
            }
            for aIdx in sequence.audioTracks.indices {
                for clip in sequence.audioTracks[aIdx].clips where ids.contains(clip.id) {
                    removals.append(Removal(trackIsVideo: false, trackIdx: aIdx, range: clip.timelineRange))
                }
                sequence.audioTracks[aIdx].clips.removeAll { ids.contains($0.id) }
            }

            // Close gaps: process per-track from earliest removal to latest so
            // multiple removals on the same track don't mis-shift downstream.
            let perTrack = Dictionary(grouping: removals, by: { TrackKey(isVideo: $0.trackIsVideo, idx: $0.trackIdx) })
            for (key, list) in perTrack {
                let sorted = list.sorted { $0.range.start.seconds < $1.range.start.seconds }
                for removal in sorted {
                    let shift = removal.range.duration.seconds
                    let threshold = removal.range.start.seconds
                    shiftDownstream(
                        in: &sequence,
                        trackIsVideo: key.isVideo,
                        trackIdx: key.idx,
                        afterSeconds: threshold,
                        byMinusSeconds: shift
                    )
                }
            }
        }
        selectedClipIDs = []
    }

    private struct TrackKey: Hashable { let isVideo: Bool; let idx: Int }

    private func shiftDownstream(
        in sequence: inout Sequence,
        trackIsVideo: Bool,
        trackIdx: Int,
        afterSeconds: Double,
        byMinusSeconds: Double
    ) {
        if trackIsVideo {
            for cIdx in sequence.videoTracks[trackIdx].clips.indices {
                let clip = sequence.videoTracks[trackIdx].clips[cIdx]
                if clip.timelineRange.start.seconds >= afterSeconds {
                    let newStart = max(0, clip.timelineRange.start.seconds - byMinusSeconds)
                    sequence.videoTracks[trackIdx].clips[cIdx].timelineRange = TimeRange(
                        start: RationalTime(value: Int64(newStart * 1000), scale: 1000),
                        duration: clip.timelineRange.duration
                    )
                }
            }
            sequence.videoTracks[trackIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        } else {
            for cIdx in sequence.audioTracks[trackIdx].clips.indices {
                let clip = sequence.audioTracks[trackIdx].clips[cIdx]
                if clip.timelineRange.start.seconds >= afterSeconds {
                    let newStart = max(0, clip.timelineRange.start.seconds - byMinusSeconds)
                    sequence.audioTracks[trackIdx].clips[cIdx].timelineRange = TimeRange(
                        start: RationalTime(value: Int64(newStart * 1000), scale: 1000),
                        duration: clip.timelineRange.duration
                    )
                }
            }
            sequence.audioTracks[trackIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
    }

    /// Add (or replace) a cross-dissolve transition at every abutting
    /// pair within tolerance of the playhead across all V/A tracks.
    /// `totalDuration` is the dissolve's full length, split evenly on
    /// either side of the cut (centered). Clipped so neither side
    /// outruns its source clip's duration.
    public func addCrossDissolveAtPlayhead(totalDuration: Double? = nil) {
        let duration = totalDuration ?? KineSettings.shared.defaultTransitionSeconds(for: activeSequence)
        let kind = KineSettings.shared.defaultTransitionKind
        applyTransitionAtPlayhead(kind: kind, totalDuration: duration)
    }

    /// Apply a transition (centered on the cut) to abutting pairs near
    /// the playhead. Shared by the keyboard shortcut + the right-click
    /// "Add Transition" menu item.
    @discardableResult
    public func applyTransitionAtPlayhead(kind: String, totalDuration: Double) -> Bool {
        let t = playheadTime.seconds
        let proximityTolerance = 0.25
        let abutTolerance = 0.001

        var didApply = false
        updateSequence { sequence in
            func apply(toClipsAt vIdx: Int, isVideo: Bool) {
                var clips = isVideo ? sequence.videoTracks[vIdx].clips : sequence.audioTracks[vIdx].clips
                guard clips.count >= 2 else { return }
                clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
                if isVideo { sequence.videoTracks[vIdx].clips = clips }
                else       { sequence.audioTracks[vIdx].clips = clips }

                var bestIdx: Int?
                var bestDelta: Double = .infinity
                for i in 0..<(clips.count - 1) {
                    let cut = clips[i].timelineRange.end.seconds
                    guard abs(cut - clips[i + 1].timelineRange.start.seconds) < abutTolerance else { continue }
                    let delta = abs(cut - t)
                    if delta < bestDelta { bestDelta = delta; bestIdx = i }
                }
                guard let i = bestIdx, bestDelta <= proximityTolerance else { return }
                let leftHalf = Self.clampHalf(totalDuration / 2, neighborDuration: clips[i].timelineRange.duration.seconds)
                let rightHalf = Self.clampHalf(totalDuration / 2, neighborDuration: clips[i + 1].timelineRange.duration.seconds)
                let leftT = Transition(kind: kind, duration: RationalTime(value: Int64(leftHalf * 1000), scale: 1000))
                let rightT = Transition(kind: kind, duration: RationalTime(value: Int64(rightHalf * 1000), scale: 1000))
                if isVideo {
                    sequence.videoTracks[vIdx].clips[i].transitionOut = leftT
                    sequence.videoTracks[vIdx].clips[i + 1].transitionIn = rightT
                } else {
                    sequence.audioTracks[vIdx].clips[i].transitionOut = leftT
                    sequence.audioTracks[vIdx].clips[i + 1].transitionIn = rightT
                }
                didApply = true
            }
            for vIdx in sequence.videoTracks.indices { apply(toClipsAt: vIdx, isVideo: true) }
            for aIdx in sequence.audioTracks.indices { apply(toClipsAt: aIdx, isVideo: false) }
        }
        if !didApply {
            KineDebugLog.log("[Transitions] no abutting cut near playhead (t=\(t)) — nothing to add")
        }
        return didApply
    }

    nonisolated private static func clampHalf(_ half: Double, neighborDuration: Double) -> Double {
        max(0.05, min(half, neighborDuration / 2))
    }

    /// Round seconds to the active sequence's frame grid. Mirrors what
    /// Premiere does on transition durations so resizing reads as
    /// "professional" instead of sub-pixel jitter. Returns the input
    /// unchanged when no active sequence (no fps available).
    private func quantizeToFrame(_ seconds: Double) -> Double {
        guard let fps = activeSequence?.settings.frameRate.fps, fps > 0 else { return seconds }
        let frames = (seconds * fps).rounded()
        return frames / fps
    }

    /// Remove transitions from the cut nearest the playhead on every
    /// track that has one within tolerance. Inverse of `addCrossDissolveAtPlayhead`.
    public func removeTransitionAtPlayhead() {
        let t = playheadTime.seconds
        let proximityTolerance = 0.25
        let abutTolerance = 0.001
        updateSequence { sequence in
            func clear(_ vIdx: Int, isVideo: Bool) {
                let clips = isVideo ? sequence.videoTracks[vIdx].clips : sequence.audioTracks[vIdx].clips
                guard clips.count >= 2 else { return }
                for i in 0..<(clips.count - 1) {
                    let cut = clips[i].timelineRange.end.seconds
                    guard abs(cut - clips[i + 1].timelineRange.start.seconds) < abutTolerance else { continue }
                    guard abs(cut - t) <= proximityTolerance else { continue }
                    if isVideo {
                        sequence.videoTracks[vIdx].clips[i].transitionOut = nil
                        sequence.videoTracks[vIdx].clips[i + 1].transitionIn = nil
                    } else {
                        sequence.audioTracks[vIdx].clips[i].transitionOut = nil
                        sequence.audioTracks[vIdx].clips[i + 1].transitionIn = nil
                    }
                }
            }
            for vIdx in sequence.videoTracks.indices { clear(vIdx, isVideo: true) }
            for aIdx in sequence.audioTracks.indices { clear(aIdx, isVideo: false) }
        }
    }

    /// Apply a transition (per-side half durations) to the specific cut
    /// identified by `cut`. Used by the right-click "Add Transition" menu.
    public func applyTransitionAtCut(_ cut: CutSelection, kind: String? = nil, leftHalf: Double? = nil, rightHalf: Double? = nil) {
        let chosenKind = kind ?? KineSettings.shared.defaultTransitionKind
        let half = (leftHalf ?? KineSettings.shared.defaultTransitionSeconds(for: activeSequence) / 2)
        let halfL = leftHalf ?? half
        let halfR = rightHalf ?? half
        let isVideo = cut.trackKind == 0
        updateSequence { sequence in
            if isVideo, cut.trackIndex < sequence.videoTracks.count {
                guard let lIdx = sequence.videoTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.leftClipID }),
                      let rIdx = sequence.videoTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.rightClipID }) else { return }
                let leftDur = Self.clampHalf(halfL, neighborDuration: sequence.videoTracks[cut.trackIndex].clips[lIdx].timelineRange.duration.seconds)
                let rightDur = Self.clampHalf(halfR, neighborDuration: sequence.videoTracks[cut.trackIndex].clips[rIdx].timelineRange.duration.seconds)
                sequence.videoTracks[cut.trackIndex].clips[lIdx].transitionOut = Transition(
                    kind: chosenKind, duration: RationalTime(value: Int64(leftDur * 1000), scale: 1000)
                )
                sequence.videoTracks[cut.trackIndex].clips[rIdx].transitionIn = Transition(
                    kind: chosenKind, duration: RationalTime(value: Int64(rightDur * 1000), scale: 1000)
                )
            } else if !isVideo, cut.trackIndex < sequence.audioTracks.count {
                guard let lIdx = sequence.audioTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.leftClipID }),
                      let rIdx = sequence.audioTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.rightClipID }) else { return }
                let leftDur = Self.clampHalf(halfL, neighborDuration: sequence.audioTracks[cut.trackIndex].clips[lIdx].timelineRange.duration.seconds)
                let rightDur = Self.clampHalf(halfR, neighborDuration: sequence.audioTracks[cut.trackIndex].clips[rIdx].timelineRange.duration.seconds)
                sequence.audioTracks[cut.trackIndex].clips[lIdx].transitionOut = Transition(
                    kind: chosenKind, duration: RationalTime(value: Int64(leftDur * 1000), scale: 1000)
                )
                sequence.audioTracks[cut.trackIndex].clips[rIdx].transitionIn = Transition(
                    kind: chosenKind, duration: RationalTime(value: Int64(rightDur * 1000), scale: 1000)
                )
            }
        }
    }

    /// Remove the transition at a specific cut.
    public func removeTransitionAtCut(_ cut: CutSelection) {
        let isVideo = cut.trackKind == 0
        updateSequence { sequence in
            if isVideo, cut.trackIndex < sequence.videoTracks.count {
                if let lIdx = sequence.videoTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.leftClipID }) {
                    sequence.videoTracks[cut.trackIndex].clips[lIdx].transitionOut = nil
                }
                if let rIdx = sequence.videoTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.rightClipID }) {
                    sequence.videoTracks[cut.trackIndex].clips[rIdx].transitionIn = nil
                }
            } else if !isVideo, cut.trackIndex < sequence.audioTracks.count {
                if let lIdx = sequence.audioTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.leftClipID }) {
                    sequence.audioTracks[cut.trackIndex].clips[lIdx].transitionOut = nil
                }
                if let rIdx = sequence.audioTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.rightClipID }) {
                    sequence.audioTracks[cut.trackIndex].clips[rIdx].transitionIn = nil
                }
            }
        }
    }

    /// Resize the transition at a specific cut. Pass either side
    /// individually — the other keeps its current value. Frame-quantized.
    public func resizeTransition(at cut: CutSelection, leftHalf: Double? = nil, rightHalf: Double? = nil) {
        let isVideo = cut.trackKind == 0
        let fallbackKind = KineSettings.shared.defaultTransitionKind
        let leftHalf = leftHalf.map { quantizeToFrame($0) }
        let rightHalf = rightHalf.map { quantizeToFrame($0) }
        updateSequence { sequence in
            if isVideo, cut.trackIndex < sequence.videoTracks.count {
                if let v = leftHalf,
                   let lIdx = sequence.videoTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.leftClipID }) {
                    let clipDur = sequence.videoTracks[cut.trackIndex].clips[lIdx].timelineRange.duration.seconds
                    let d = Self.clampHalf(v, neighborDuration: clipDur)
                    sequence.videoTracks[cut.trackIndex].clips[lIdx].transitionOut = Transition(
                        kind: sequence.videoTracks[cut.trackIndex].clips[lIdx].transitionOut?.kind ?? fallbackKind,
                        duration: RationalTime(value: Int64(d * 1000), scale: 1000)
                    )
                }
                if let v = rightHalf,
                   let rIdx = sequence.videoTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.rightClipID }) {
                    let clipDur = sequence.videoTracks[cut.trackIndex].clips[rIdx].timelineRange.duration.seconds
                    let d = Self.clampHalf(v, neighborDuration: clipDur)
                    sequence.videoTracks[cut.trackIndex].clips[rIdx].transitionIn = Transition(
                        kind: sequence.videoTracks[cut.trackIndex].clips[rIdx].transitionIn?.kind ?? fallbackKind,
                        duration: RationalTime(value: Int64(d * 1000), scale: 1000)
                    )
                }
            } else if !isVideo, cut.trackIndex < sequence.audioTracks.count {
                if let v = leftHalf,
                   let lIdx = sequence.audioTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.leftClipID }) {
                    let clipDur = sequence.audioTracks[cut.trackIndex].clips[lIdx].timelineRange.duration.seconds
                    let d = Self.clampHalf(v, neighborDuration: clipDur)
                    sequence.audioTracks[cut.trackIndex].clips[lIdx].transitionOut = Transition(
                        kind: sequence.audioTracks[cut.trackIndex].clips[lIdx].transitionOut?.kind ?? fallbackKind,
                        duration: RationalTime(value: Int64(d * 1000), scale: 1000)
                    )
                }
                if let v = rightHalf,
                   let rIdx = sequence.audioTracks[cut.trackIndex].clips.firstIndex(where: { $0.id == cut.rightClipID }) {
                    let clipDur = sequence.audioTracks[cut.trackIndex].clips[rIdx].timelineRange.duration.seconds
                    let d = Self.clampHalf(v, neighborDuration: clipDur)
                    sequence.audioTracks[cut.trackIndex].clips[rIdx].transitionIn = Transition(
                        kind: sequence.audioTracks[cut.trackIndex].clips[rIdx].transitionIn?.kind ?? fallbackKind,
                        duration: RationalTime(value: Int64(d * 1000), scale: 1000)
                    )
                }
            }
        }
    }

    /// Split every clip that the playhead intersects into two new clips
    /// at the playhead time. Left halves keep the original `linkID`;
    /// right halves of linked clips share a new common `linkID` so the
    /// V/A pair stays grouped on each side of the cut.
    public func splitAtPlayhead() {
        splitAtTime(playheadTime.seconds)
    }

    /// Blade-tool entry point: split ONLY the clip with the given id
    /// (and its linked siblings) at time `t`. Other clips on other
    /// tracks are untouched — matches Premiere's default razor.
    public func splitClipAndLinked(_ clipID: PlacedClipID, atSeconds t: Double) {
        guard t > 0 else { return }
        let ids = expandToLinked([clipID])
        updateSequence { sequence in
            var rightLinkIDForLeft: [UUID: UUID] = [:]
            for track in sequence.videoTracks {
                for clip in track.clips where ids.contains(clip.id) {
                    if t > clip.timelineRange.start.seconds + 0.001,
                       t < clip.timelineRange.end.seconds - 0.001,
                       let lid = clip.linkID,
                       rightLinkIDForLeft[lid] == nil {
                        rightLinkIDForLeft[lid] = UUID()
                    }
                }
            }
            for track in sequence.audioTracks {
                for clip in track.clips where ids.contains(clip.id) {
                    if t > clip.timelineRange.start.seconds + 0.001,
                       t < clip.timelineRange.end.seconds - 0.001,
                       let lid = clip.linkID,
                       rightLinkIDForLeft[lid] == nil {
                        rightLinkIDForLeft[lid] = UUID()
                    }
                }
            }
            for vIdx in sequence.videoTracks.indices {
                sequence.videoTracks[vIdx].clips = splitClips(
                    sequence.videoTracks[vIdx].clips,
                    atSeconds: t,
                    rightLinkIDForLeft: rightLinkIDForLeft,
                    onlyIDs: ids
                )
            }
            for aIdx in sequence.audioTracks.indices {
                sequence.audioTracks[aIdx].clips = splitClips(
                    sequence.audioTracks[aIdx].clips,
                    atSeconds: t,
                    rightLinkIDForLeft: rightLinkIDForLeft,
                    onlyIDs: ids
                )
            }
        }
    }

    /// Split every clip on every track that intersects `t`. Used by both
    /// the V keyboard shortcut (splits at playhead) and the blade tool
    /// (splits at click position).
    public func splitAtTime(_ t: Double) {
        guard t > 0 else { return }

        updateSequence { sequence in
            // Build linkID → newRightLinkID map across all tracks that
            // contain a clip the playhead intersects.
            var rightLinkIDForLeft: [UUID: UUID] = [:]
            for track in sequence.videoTracks {
                for clip in track.clips {
                    if t > clip.timelineRange.start.seconds + 0.001,
                       t < clip.timelineRange.end.seconds - 0.001,
                       let lid = clip.linkID,
                       rightLinkIDForLeft[lid] == nil {
                        rightLinkIDForLeft[lid] = UUID()
                    }
                }
            }
            for track in sequence.audioTracks {
                for clip in track.clips {
                    if t > clip.timelineRange.start.seconds + 0.001,
                       t < clip.timelineRange.end.seconds - 0.001,
                       let lid = clip.linkID,
                       rightLinkIDForLeft[lid] == nil {
                        rightLinkIDForLeft[lid] = UUID()
                    }
                }
            }

            for vIdx in sequence.videoTracks.indices {
                sequence.videoTracks[vIdx].clips = splitClips(
                    sequence.videoTracks[vIdx].clips,
                    atSeconds: t,
                    rightLinkIDForLeft: rightLinkIDForLeft
                )
            }
            for aIdx in sequence.audioTracks.indices {
                sequence.audioTracks[aIdx].clips = splitClips(
                    sequence.audioTracks[aIdx].clips,
                    atSeconds: t,
                    rightLinkIDForLeft: rightLinkIDForLeft
                )
            }
        }
    }

    /// Shift every selected clip (and its linked siblings) by `frames`
    /// frames on the timeline. Negative = left, positive = right.
    /// Frame-precise: snaps the clip's start to an integer frame
    /// boundary so repeated nudges don't accumulate sub-frame drift.
    /// No overlap-finalize pass — nudge just moves, never overwrites
    /// or slices, so the selected clips stay selected with their IDs
    /// intact. (Drag-move still slices because that's the user's
    /// explicit gesture.)
    // MARK: - Transform / Crop on a clip (effect controls)

    /// Read the current `ClipTransform` for the given placed clip,
    /// sampled at the program playhead's clip-local time. Used by the
    /// Effect Controls panel to populate fields — when the user
    /// scrubs, the panel reflects the keyframe-interpolated value.
    public func clipTransform(_ id: PlacedClipID) -> ClipTransform? {
        guard let sequence = activeSequence else { return nil }
        let localT: (PlacedClip) -> Double = { clip in
            self.playheadTime.seconds - clip.timelineRange.start.seconds
        }
        for t in sequence.videoTracks {
            if let c = t.clips.first(where: { $0.id == id }) {
                return c.transform(at: localT(c))
            }
        }
        for t in sequence.audioTracks {
            if let c = t.clips.first(where: { $0.id == id }) {
                return c.transform(at: localT(c))
            }
        }
        return nil
    }

    /// Look up the clip-local time (seconds since the clip's
    /// `timelineRange.start`) at the program playhead.
    public func clipLocalSecondsAtPlayhead(_ id: PlacedClipID) -> Double? {
        guard let sequence = activeSequence else { return nil }
        for track in sequence.videoTracks {
            if let c = track.clips.first(where: { $0.id == id }) {
                return playheadTime.seconds - c.timelineRange.start.seconds
            }
        }
        for track in sequence.audioTracks {
            if let c = track.clips.first(where: { $0.id == id }) {
                return playheadTime.seconds - c.timelineRange.start.seconds
            }
        }
        return nil
    }

    /// Set one Transform/Crop parameter on the clip. When the parameter
    /// is currently keyframed, writes a keyframe at the playhead's
    /// clip-local time; otherwise replaces the constant value.
    public func setTransformParameter(
        _ id: PlacedClipID,
        _ parameter: TransformParameter,
        _ value: Double
    ) {
        let localT = clipLocalSecondsAtPlayhead(id)
        updateSequence { sequence in
            updatePlacedClip(id, in: &sequence) { clip in
                clip.setParameter(parameter, value: value, at: localT)
            }
        }
    }

    /// Apply one Transform/Crop parameter to every currently selected
    /// VIDEO clip — inspector multi-edit path. Audio clips can't
    /// carry transform/crop so they're skipped. Each clip's keyframe
    /// write uses its own clip-local playhead time.
    public func setTransformParameterOnSelection(
        _ parameter: TransformParameter,
        _ value: Double
    ) {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                let localT = clipLocalSecondsAtPlayhead(id, in: sequence)
                updatePlacedClip(id, in: &sequence) { clip in
                    clip.setParameter(parameter, value: value, at: localT)
                }
            }
        }
    }

    /// Light variant of `setTransformParameterOnSelection` for use DURING
    /// a slider drag: mutates the sequence and drives the viewer, but
    /// skips undo, audio, and pre-render cache invalidation. Bracket the
    /// drag with `beginUndoBatch()` / (`endUndoBatch()` + `commitTransformEdits()`).
    public func setTransformParameterOnSelectionLight(
        _ parameter: TransformParameter,
        _ value: Double
    ) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        var sequence = project.sequences[idx]
        for id in ids {
            let localT = clipLocalSecondsAtPlayhead(id, in: sequence)
            updatePlacedClip(id, in: &sequence) { clip in
                clip.setParameter(parameter, value: value, at: localT)
            }
        }
        project.sequences[idx] = sequence
    }

    /// Flush the invalidation a light-edit drag skipped: one pre-render
    /// cache clear + dirty mark. Transform edits don't affect audio.
    public func commitTransformEdits() {
        guard let sequence = activeSequence else { return }
        markDirty()
        invalidatePreRenderCache(for: sequence.id)
    }

    // MARK: - Color grade setters (kine.color)

    /// `ColorGrade` sampled at the playhead for one clip — inspector read path.
    public func clipColorGrade(_ id: PlacedClipID) -> ColorGrade? {
        guard let sequence = activeSequence else { return nil }
        for t in sequence.videoTracks where true {
            if let c = t.clips.first(where: { $0.id == id }) {
                return c.colorGrade(at: playheadTime.seconds - c.timelineRange.start.seconds)
            }
        }
        return nil
    }

    public func setColorParameterOnSelection(_ p: ColorGradeParameter, _ value: Double) {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                let localT = clipLocalSecondsAtPlayhead(id, in: sequence)
                updatePlacedClip(id, in: &sequence) { $0.setColorParameter(p, value: value, at: localT) }
            }
        }
    }

    /// Light variant for slider drags — bracket with `beginUndoBatch()` /
    /// (`endUndoBatch()` + `commitTransformEdits()`).
    public func setColorParameterOnSelectionLight(_ p: ColorGradeParameter, _ value: Double) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        var sequence = project.sequences[idx]
        for id in ids {
            let localT = clipLocalSecondsAtPlayhead(id, in: sequence)
            updatePlacedClip(id, in: &sequence) { $0.setColorParameter(p, value: value, at: localT) }
        }
        project.sequences[idx] = sequence
    }

    public func toggleColorKeyframingOnSelection(_ p: ColorGradeParameter) {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                let localT = clipLocalSecondsAtPlayhead(id, in: sequence) ?? 0
                updatePlacedClip(id, in: &sequence) { $0.toggleColorKeyframing(p, at: localT) }
            }
        }
    }

    public func setColorInputSpaceOnSelection(_ space: ColorTransferSpace) {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                updatePlacedClip(id, in: &sequence) { $0.setColorInputSpace(space) }
            }
        }
    }

    public func setColorCurveOnSelection(_ name: String, _ points: [CurvePoint]) {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                updatePlacedClip(id, in: &sequence) { $0.setColorCurve(name, points) }
            }
        }
    }

    /// Light variant for live curve dragging — bracket with `beginUndoBatch()`
    /// / (`endUndoBatch()` + `commitTransformEdits()`).
    public func setColorCurveOnSelectionLight(_ name: String, _ points: [CurvePoint]) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        var sequence = project.sequences[idx]
        for id in ids {
            updatePlacedClip(id, in: &sequence) { $0.setColorCurve(name, points) }
        }
        project.sequences[idx] = sequence
    }

    public func setColorLUTOnSelection(_ path: String?) {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                updatePlacedClip(id, in: &sequence) { $0.setColorLUT(path: path) }
            }
        }
    }

    /// Strip the whole color grade from the selection.
    public func resetColorOnSelection() {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                updatePlacedClip(id, in: &sequence) { clip in
                    clip.effects.removeAll { $0.effectKey == "kine.color" }
                }
            }
        }
    }

    /// Toggle keyframing for one Transform/Crop parameter on the clip.
    /// Going ON converts the constant value into a single keyframe at
    /// the playhead; going OFF collapses to a constant at the value
    /// sampled at the playhead (no visual jump). Video clips only —
    /// audio clips can't carry transform/crop.
    public func toggleKeyframingOnSelection(_ parameter: TransformParameter) {
        let ids = selectedVideoClipIDs
        guard !ids.isEmpty else { return }
        updateSequence { sequence in
            for id in ids {
                let localT = clipLocalSecondsAtPlayhead(id, in: sequence) ?? 0
                updatePlacedClip(id, in: &sequence) { clip in
                    clip.toggleKeyframing(parameter, at: localT)
                }
            }
        }
    }

    /// Remove the keyframe at (or near) the playhead for one parameter.
    public func removeKeyframeAtPlayhead(_ id: PlacedClipID, _ parameter: TransformParameter) {
        guard let localT = clipLocalSecondsAtPlayhead(id) else { return }
        updateSequence { sequence in
            updatePlacedClip(id, in: &sequence) { clip in
                clip.removeKeyframe(parameter, at: localT)
            }
        }
    }

    /// Move the keyframe at `fromClipLocal` to `toClipLocal` (both in
    /// clip-local seconds). Used by drag-on-keyframe-strip gestures.
    public func moveKeyframe(
        _ id: PlacedClipID,
        _ parameter: TransformParameter,
        from fromClipLocal: Double,
        to toClipLocal: Double
    ) {
        updateSequence { sequence in
            updatePlacedClip(id, in: &sequence) { clip in
                clip.moveKeyframe(parameter, from: fromClipLocal, to: toClipLocal)
            }
        }
    }

    /// Lightweight variant of `moveKeyframe` for use INSIDE a drag's
    /// onChanged. Skips undo, audio invalidation, and pre-render cache
    /// invalidation — those happen once when the drag ends via the
    /// usual `endUndoBatch` + a final `moveKeyframe` commit. Calling
    /// `moveKeyframe` 60×/second during a drag was hammering
    /// PreRenderCache.clearAll and AudioPipeline.invalidate, which
    /// made the diamond feel sluggish under the cursor.
    public func moveKeyframeLight(
        _ id: PlacedClipID,
        _ parameter: TransformParameter,
        from fromClipLocal: Double,
        to toClipLocal: Double
    ) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        var sequence = project.sequences[idx]
        updatePlacedClip(id, in: &sequence) { clip in
            clip.moveKeyframe(parameter, from: fromClipLocal, to: toClipLocal)
        }
        project.sequences[idx] = sequence
        // No cache or audio invalidation here — those run when the
        // drag ends. Transform changes don't affect audio anyway, and
        // the pre-render cache will be regenerated lazily next render.
    }

    /// Add (or update) a keyframe at a specific clip-local time —
    /// used by click-on-strip in the keyframe editor (not the playhead).
    /// The parameter must already be keyframed; if it's still constant,
    /// this is a no-op (toggle the stopwatch first).
    public func addKeyframe(
        _ id: PlacedClipID,
        _ parameter: TransformParameter,
        atClipLocal clipLocalTime: Double,
        value: Double
    ) {
        updateSequence { sequence in
            updatePlacedClip(id, in: &sequence) { clip in
                guard clip.hasKeyframes(for: parameter) else { return }
                clip.setParameter(parameter, value: value, at: clipLocalTime)
            }
        }
    }

    /// Remove the keyframe nearest a specific clip-local time. Used by
    /// double-click-on-diamond in the keyframe strip.
    public func removeKeyframeAt(
        _ id: PlacedClipID,
        _ parameter: TransformParameter,
        atClipLocal clipLocalTime: Double
    ) {
        updateSequence { sequence in
            updatePlacedClip(id, in: &sequence) { clip in
                clip.removeKeyframe(parameter, at: clipLocalTime)
            }
        }
    }

    /// Set the interpolation mode on the keyframe nearest a given
    /// clip-local time. Used by the strip's right-click menu.
    public func setKeyframeInterpolation(
        _ id: PlacedClipID,
        _ parameter: TransformParameter,
        atClipLocal clipLocalTime: Double,
        _ interpolation: Interpolation
    ) {
        updateSequence { sequence in
            updatePlacedClip(id, in: &sequence) { clip in
                clip.setKeyframeInterpolation(parameter, at: clipLocalTime, interpolation)
            }
        }
    }

    /// Look up a placed clip by id (cross-track). Read-only — used by
    /// the inspector to inspect keyframe arrays for UI rendering.
    public func findPlacedClip(_ id: PlacedClipID) -> PlacedClip? {
        guard let sequence = activeSequence else { return nil }
        for t in sequence.videoTracks {
            if let c = t.clips.first(where: { $0.id == id }) { return c }
        }
        for t in sequence.audioTracks {
            if let c = t.clips.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    /// True if the given placed clip lives on a video track. Used by
    /// the Effect Controls inspector to filter audio-linked siblings
    /// out of transform operations — audio clips can't carry
    /// Transform/Crop, so including them in a multi-set would do
    /// nothing meaningful and would lie about the "selection count"
    /// in the keyframe strip header.
    public func isVideoClip(_ id: PlacedClipID) -> Bool {
        guard let sequence = activeSequence else { return false }
        for t in sequence.videoTracks where t.clips.contains(where: { $0.id == id }) {
            return true
        }
        return false
    }

    /// Selected clip IDs filtered to video-track residents only —
    /// what the Effect Controls panel should treat as the "real"
    /// transform-applicable selection.
    public var selectedVideoClipIDs: Set<PlacedClipID> {
        selectedClipIDs.filter { isVideoClip($0) }
    }

    /// Set the `ClipTransform` on the given placed clip in one shot —
    /// used by the direct-manipulation path in the program viewer
    /// (drag-to-move, drag-corner-to-scale). Translated internally to
    /// per-parameter writes so keyframed parameters get keyframes at
    /// the playhead and constant parameters get their constants
    /// replaced — never destroys existing keyframe arrays.
    public func setClipTransform(_ id: PlacedClipID, _ transform: ClipTransform) {
        let localT = clipLocalSecondsAtPlayhead(id)
        updateSequence { sequence in
            updatePlacedClip(id, in: &sequence) { clip in
                Self.applyTransform(transform, to: &clip, at: localT)
            }
        }
    }

    /// Light variant for on-canvas direct manipulation: drives the
    /// viewer but skips undo / audio / pre-render invalidation. Bracket
    /// the drag with `beginUndoBatch()` / (`endUndoBatch()` +
    /// `commitTransformEdits()`).
    public func setClipTransformLight(_ id: PlacedClipID, _ transform: ClipTransform) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        let localT = clipLocalSecondsAtPlayhead(id)
        var sequence = project.sequences[idx]
        updatePlacedClip(id, in: &sequence) { clip in
            Self.applyTransform(transform, to: &clip, at: localT)
        }
        project.sequences[idx] = sequence
    }

    private static func applyTransform(_ transform: ClipTransform, to clip: inout PlacedClip, at localT: Double?) {
        clip.setParameter(.positionX,  value: transform.positionX,       at: localT)
        clip.setParameter(.positionY,  value: transform.positionY,       at: localT)
        clip.setParameter(.scaleX,     value: transform.scaleX,          at: localT)
        clip.setParameter(.scaleY,     value: transform.scaleY,          at: localT)
        clip.setParameter(.opacity,    value: transform.opacity,         at: localT)
        clip.setParameter(.rotation,   value: transform.rotationDegrees, at: localT)
        clip.setParameter(.cropTop,     value: transform.cropTop,         at: localT)
        clip.setParameter(.cropRight,   value: transform.cropRight,       at: localT)
        clip.setParameter(.cropBottom,  value: transform.cropBottom,      at: localT)
        clip.setParameter(.cropLeft,    value: transform.cropLeft,        at: localT)
        clip.setParameter(.cropFeather, value: transform.cropFeather,     at: localT)

        // stretchToFill is not keyframable.
        var i = clip.effects.firstIndex { $0.effectKey == "kine.transform" }
        if i == nil {
            clip.effects.append(EffectInstance(effectKey: "kine.transform", parameters: [:]))
            i = clip.effects.count - 1
        }
        clip.effects[i!].parameters["stretchToFill"] = .bool(transform.stretchToFill)
    }

    /// Convenience: set the transform on every selected clip at once.
    public func setSelectedClipsTransform(_ transform: ClipTransform) {
        guard !selectedClipIDs.isEmpty else { return }
        for id in selectedClipIDs {
            setClipTransform(id, transform)
        }
    }

    private func clipLocalSecondsAtPlayhead(_ id: PlacedClipID, in sequence: Sequence) -> Double? {
        for track in sequence.videoTracks {
            if let c = track.clips.first(where: { $0.id == id }) {
                return playheadTime.seconds - c.timelineRange.start.seconds
            }
        }
        for track in sequence.audioTracks {
            if let c = track.clips.first(where: { $0.id == id }) {
                return playheadTime.seconds - c.timelineRange.start.seconds
            }
        }
        return nil
    }

    public func nudgeSelectedClips(frames: Int) {
        guard !selectedClipIDs.isEmpty else { return }
        guard let sequence = activeSequence else { return }
        let fps = sequence.settings.frameRate.fps
        guard fps > 0 else { return }
        let ids = expandToLinked(selectedClipIDs)

        updateSequence { sequence in
            // Snap to frame boundary, shift, snap back. Ensures a
            // 1-frame nudge moves exactly one frame even after many
            // sequential nudges (no sub-millisecond drift).
            func shifted(_ clip: PlacedClip) -> TimeRange {
                let currentFrames = (clip.timelineRange.start.seconds * fps).rounded()
                let newFrames = max(0, currentFrames + Double(frames))
                let newStart = newFrames / fps
                return TimeRange(
                    start: RationalTime(value: Int64((newStart * 1000).rounded()), scale: 1000),
                    duration: clip.timelineRange.duration
                )
            }
            for vIdx in sequence.videoTracks.indices {
                for cIdx in sequence.videoTracks[vIdx].clips.indices {
                    if ids.contains(sequence.videoTracks[vIdx].clips[cIdx].id) {
                        sequence.videoTracks[vIdx].clips[cIdx].timelineRange =
                            shifted(sequence.videoTracks[vIdx].clips[cIdx])
                    }
                }
                sequence.videoTracks[vIdx].clips.sort {
                    $0.timelineRange.start.seconds < $1.timelineRange.start.seconds
                }
            }
            for aIdx in sequence.audioTracks.indices {
                for cIdx in sequence.audioTracks[aIdx].clips.indices {
                    if ids.contains(sequence.audioTracks[aIdx].clips[cIdx].id) {
                        sequence.audioTracks[aIdx].clips[cIdx].timelineRange =
                            shifted(sequence.audioTracks[aIdx].clips[cIdx])
                    }
                }
                sequence.audioTracks[aIdx].clips.sort {
                    $0.timelineRange.start.seconds < $1.timelineRange.start.seconds
                }
            }
        }
    }

    private func splitClips(
        _ clips: [PlacedClip],
        atSeconds t: Double,
        rightLinkIDForLeft: [UUID: UUID],
        onlyIDs: Set<PlacedClipID>? = nil
    ) -> [PlacedClip] {
        var out: [PlacedClip] = []
        out.reserveCapacity(clips.count + 2)
        for clip in clips {
            let s = clip.timelineRange.start.seconds
            let e = clip.timelineRange.end.seconds
            let allowed = onlyIDs.map { $0.contains(clip.id) } ?? true
            if allowed, t > s + 0.001 && t < e - 0.001 {
                let leftDuration = t - s
                let rightDuration = e - t
                let sourceSplit = clip.sourceRange.start.seconds + leftDuration

                let rightLinkID: UUID? = {
                    guard let lid = clip.linkID else { return nil }
                    return rightLinkIDForLeft[lid]
                }()

                let leftClip = PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(
                        start: clip.sourceRange.start,
                        duration: RationalTime(value: Int64(leftDuration * 1000), scale: 1000)
                    ),
                    timelineRange: TimeRange(
                        start: clip.timelineRange.start,
                        duration: RationalTime(value: Int64(leftDuration * 1000), scale: 1000)
                    ),
                    isEnabled: clip.isEnabled,
                    effects: clip.effects,
                    transitionIn: clip.transitionIn,
                    transitionOut: nil,
                    linkID: clip.linkID
                )
                let rightClip = PlacedClip(
                    sourceClipID: clip.sourceClipID,
                    sourceRange: TimeRange(
                        start: RationalTime(value: Int64(sourceSplit * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(rightDuration * 1000), scale: 1000)
                    ),
                    timelineRange: TimeRange(
                        start: RationalTime(value: Int64(t * 1000), scale: 1000),
                        duration: RationalTime(value: Int64(rightDuration * 1000), scale: 1000)
                    ),
                    isEnabled: clip.isEnabled,
                    effects: clip.effects,
                    transitionIn: nil,
                    transitionOut: clip.transitionOut,
                    linkID: rightLinkID
                )
                out.append(leftClip)
                out.append(rightClip)
            } else {
                out.append(clip)
            }
        }
        return out
    }

    // MARK: - Sequence mutation plumbing

    private func updateSequence(_ mutate: (inout Sequence) -> Void) {
        guard let idx = project.sequences.firstIndex(where: { $0.id == activeSequenceID }) else { return }
        pushUndoSnapshot()
        var sequence = project.sequences[idx]
        mutate(&sequence)
        project.sequences[idx] = sequence
        project.modifiedAt = Date()
        audio.invalidate(); sourceAudio.invalidate()
        markDirty()
        invalidatePreRenderCache(for: sequence.id)
    }

    private func updatePlacedClip(_ id: PlacedClipID, in sequence: inout Sequence, _ mutate: (inout PlacedClip) -> Void) {
        for vIdx in sequence.videoTracks.indices {
            if let cIdx = sequence.videoTracks[vIdx].clips.firstIndex(where: { $0.id == id }) {
                mutate(&sequence.videoTracks[vIdx].clips[cIdx])
                return
            }
        }
        for aIdx in sequence.audioTracks.indices {
            if let cIdx = sequence.audioTracks[aIdx].clips.firstIndex(where: { $0.id == id }) {
                mutate(&sequence.audioTracks[aIdx].clips[cIdx])
                return
            }
        }
    }

    private func resortTracksContaining(_ id: PlacedClipID, in sequence: inout Sequence) {
        for vIdx in sequence.videoTracks.indices where sequence.videoTracks[vIdx].clips.contains(where: { $0.id == id }) {
            sequence.videoTracks[vIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
        for aIdx in sequence.audioTracks.indices where sequence.audioTracks[aIdx].clips.contains(where: { $0.id == id }) {
            sequence.audioTracks[aIdx].clips.sort { $0.timelineRange.start.seconds < $1.timelineRange.start.seconds }
        }
    }

    // MARK: - Transport (thin compat wrappers → setPlayback)

    public func togglePlay() {
        if isPlaying { setPlayback(.stopped) }
        else { setPlayback(.program(rate: 1.0)) }
    }

    public func play() {
        if !isPlaying { setPlayback(.program(rate: 1.0)) }
    }

    public func stop() {
        setPlayback(.stopped)
    }

    /// Call after any edit that affects audio (move, trim, delete, split,
    /// ripple, insert) so the next play rebuilds buffers.
    public func invalidateAudio() {
        audio.invalidate(); sourceAudio.invalidate()
    }

    public func nudgePlayhead(framesAt rate: FrameRate, by delta: Int) {
        let frameDurationSeconds = Double(rate.rationalScale) / Double(rate.rationalRate)
        let newSeconds = max(0, playheadTime.seconds + frameDurationSeconds * Double(delta))
        playheadTime = RationalTime(value: Int64(newSeconds * 1000), scale: 1000)
    }

    public func jumpToStart() {
        playheadTime = .zero
    }

    public func jumpToEnd() {
        guard let seq = activeSequence else { return }
        let allClips = seq.videoTracks.flatMap(\.clips) + seq.audioTracks.flatMap(\.clips)
        let endSeconds = allClips.map { $0.timelineRange.end.seconds }.max() ?? 0
        playheadTime = RationalTime(value: Int64(endSeconds * 1000), scale: 1000)
    }

    public func ingest(urls: [URL]) {
        Task { @MainActor in
            importing = true
            defer { importing = false }
            for url in urls {
                await ingestSingle(url: url)
            }
        }
    }

    private func ingestSingle(url: URL) async {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

        if isDir.boolValue || StillsIngest.stillExtensions.contains(url.pathExtension.lowercased()) {
            await ingestStills(url: url)
            return
        }

        guard isProbablyMediaFile(url) else { return }
        do {
            let clip = try await prober.probe(url: url)
            project.mediaPool.clips[clip.id] = clip
            project.mediaPool.rootBin.children.append(.clip(clip.id))
            project.modifiedAt = Date()
            markDirty()
            if sourceClip == nil { sourceClip = clip }

            schedulePreviews(for: clip)
        } catch {
            // M1: swallow. M2 adds a real import-error panel.
        }
    }

    private func isProbablyMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mov", "mp4", "m4v", "wav", "aif", "aiff", "mp3"].contains(ext)
    }

    // MARK: - Burst shots

    /// Ingest a folder (or a loose still) into burst shots: EXIF probe →
    /// gap grouping → shots in the pool. Videos found alongside go through
    /// the normal clip path so they sit in the bin with the same look/feel.
    private func ingestStills(url: URL) async {
        let ingester = stillsIngest
        let gap = project.settings.burst.gapThreshold
        let (shots, videos) = await Task.detached(priority: .userInitiated) {
            ingester.ingest(folder: url, gapThreshold: gap)
        }.value

        for shot in shots where !shot.frames.isEmpty {
            project.mediaPool.shots[shot.id] = shot
            project.mediaPool.rootBin.children.append(.shot(shot.id))
            scheduleShotThumbnails(for: shot)
        }
        if !shots.isEmpty {
            project.modifiedAt = Date()
            markDirty()
        }
        for video in videos {
            await ingestSingle(url: video)
        }
    }

    public func removeShot(_ id: ShotID) {
        project.mediaPool.shots[id] = nil
        project.mediaPool.rootBin.children.removeAll {
            if case .shot(let s) = $0 { return s == id }
            return false
        }
        shotThumbnails[id] = nil
        project.modifiedAt = Date()
        markDirty()
    }

    public func setShotTiming(_ mode: ShotTimingMode?, for id: ShotID) {
        guard var shot = project.mediaPool.shots[id] else { return }
        shot.timingOverride = mode
        project.mediaPool.shots[id] = shot
        project.modifiedAt = Date()
        markDirty()
    }

    public func setDefaultShotTiming(_ mode: ShotTimingMode) {
        project.settings.burst.timing = mode
        project.modifiedAt = Date()
        markDirty()
    }

    public func setBurstGapThreshold(_ seconds: TimeInterval) {
        project.settings.burst.gapThreshold = seconds
        project.modifiedAt = Date()
        markDirty()
    }

    // MARK: - Shot grading

    /// Shot targeted by the Shot grade tab (set by clicking a bin row).
    @Published public var selectedShotID: ShotID?
    /// Clipboard for copy/paste grade across shots.
    @Published public var copiedShotGrade: ShotGrade?

    public var selectedShot: BurstShot? {
        selectedShotID.flatMap { project.mediaPool.shots[$0] }
    }

    public func selectShot(_ id: ShotID) {
        selectedShotID = id
        sourcePaneTab = .shotGrade
        focusedViewer = .source
    }

    public func setShotGrade(_ grade: ShotGrade, for id: ShotID) {
        guard var shot = project.mediaPool.shots[id] else { return }
        shot.grade = grade
        project.mediaPool.shots[id] = shot
        project.modifiedAt = Date()
        markDirty()
    }

    public func setShotRamp(_ ramp: [CurvePoint], for id: ShotID) {
        guard var shot = project.mediaPool.shots[id] else { return }
        shot.speedRamp = ramp
        project.mediaPool.shots[id] = shot
        project.modifiedAt = Date()
        markDirty()
    }

    public func copyGrade(from id: ShotID) {
        copiedShotGrade = project.mediaPool.shots[id]?.grade
    }

    public func pasteGrade(to id: ShotID) {
        guard let grade = copiedShotGrade else { return }
        setShotGrade(grade, for: id)
    }

    // MARK: - Looks (saved grades)

    public static var looksDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kinestasis", isDirectory: true)
            .appendingPathComponent("Looks", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public func saveLook(_ grade: ShotGrade, name: String) {
        let url = Self.looksDirectory.appendingPathComponent("\(name).kinelook")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(grade) {
            try? data.write(to: url)
            objectWillChange.send()
        }
    }

    public func availableLooks() -> [(name: String, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.looksDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "kinelook" }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    public func loadLook(from url: URL) -> ShotGrade? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShotGrade.self, from: data)
    }

    /// The frame rate shot stats and exports use: the active sequence's
    /// rate when one exists, else the project default.
    public var shotFrameRate: FrameRate {
        activeSequence?.settings.frameRate ?? project.settings.defaultFrameRate
    }

    public var orderedShots: [BurstShot] {
        project.mediaPool.rootBin.children.compactMap {
            if case .shot(let id) = $0 { return project.mediaPool.shots[id] }
            return nil
        }
    }

    // MARK: - Shot filmstrip thumbnails

    public func scheduleShotThumbnails(for shot: BurstShot) {
        guard shotThumbnails[shot.id] == nil, !shotThumbsInFlight.contains(shot.id) else { return }
        shotThumbsInFlight.insert(shot.id)
        let frames = shot.frames
        let shotID = shot.id
        Task.detached(priority: .utility) {
            let count = min(Self.shotThumbMax, frames.count)
            let urls: [URL] = (0..<count).map { i in
                let idx = count == 1 ? 0
                    : Int((Double(i) / Double(count - 1) * Double(frames.count - 1)).rounded())
                return frames[idx].url
            }
            let images = urls.compactMap { StillDecoder.preview(url: $0, maxPixel: 200) }
            await MainActor.run {
                self.shotThumbnails[shotID] = images
                self.shotThumbsInFlight.remove(shotID)
                self.previewVersion += 1
            }
        }
    }

    // MARK: - Shot batch export

    /// Batch-export shots to ProRes, one movie per shot, into a directory
    /// the user picks. `ids` nil → every shot in bin order.
    public func exportShots(_ ids: [ShotID]? = nil, codec: BurstShotExporter.Codec) {
        let shots = ids.map { list in list.compactMap { project.mediaPool.shots[$0] } } ?? orderedShots
        guard !shots.isEmpty, shotExportProgress == nil else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export \(shots.count) Shot\(shots.count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let defaults = project.settings.burst.timing
        let rate = shotFrameRate
        let exporter = BurstShotExporter()
        shotExportProgress = 0

        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for (i, shot) in shots.enumerated() {
                do {
                    try exporter.export(
                        shot: shot,
                        mode: shot.timing(projectDefault: defaults),
                        rate: rate,
                        codec: codec,
                        to: directory
                    )
                } catch {
                    failures.append("\(shot.name): \(error.localizedDescription)")
                }
                let fraction = Double(i + 1) / Double(shots.count)
                await MainActor.run { self.shotExportProgress = fraction }
            }
            await MainActor.run {
                self.shotExportProgress = nil
                if !failures.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Some shots failed to export"
                    alert.informativeText = failures.joined(separator: "\n")
                    alert.runModal()
                }
            }
        }
    }
}
