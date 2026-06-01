import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics
import PreemCore

/// FCP-style media browser. Master clips render as horizontal filmstrips
/// you can skim (mouse across → live in the Source viewer). Mark In/Out
/// on the skimmer and press F to favorite the selection — favorites are
/// sub-range "subclips" (many per clip) that the Favorites filter pulls
/// into their own draggable rows.
struct BinBrowserView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scrollableContent
        }
        .background(PreemTheme.bgPanel)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusedViewer = .bin
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private var scrollableContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sequencesSection
                switch workspace.binFilter {
                case .all:       clipsSection
                case .favorites: favoritesSection
                }
            }
            .padding(.vertical, 4)
        }
        .overlay(emptyState)
    }

    @ViewBuilder private var sequencesSection: some View {
        if !workspace.project.sequences.isEmpty {
            sectionHeader(title: "Sequences", count: workspace.project.sequences.count)
            ForEach(workspace.project.sequences) { sequence in
                SequenceRow(
                    sequence: sequence,
                    isActive: workspace.activeSequenceID == sequence.id
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    workspace.activateSequence(sequence.id)
                }
                .onTapGesture {
                    workspace.activateSequence(sequence.id)
                }
            }
        }
    }

    @ViewBuilder private var clipsSection: some View {
        if !orderedClips.isEmpty {
            sectionHeader(title: "Master Clips", count: orderedClips.count)
            ForEach(orderedClips, id: \.id) { clip in
                FilmstripClipRow(workspace: workspace, clip: clip)
            }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        let favs = allFavorites
        if !favs.isEmpty {
            sectionHeader(title: "Favorites", count: favs.count)
            ForEach(favs, id: \.favorite.id) { entry in
                FavoriteClipRow(workspace: workspace, clip: entry.clip, favorite: entry.favorite)
            }
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Master")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            filterToggle
            if workspace.importing {
                ProgressView().controlSize(.small)
            } else {
                Text("\(workspace.project.mediaPool.clips.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterToggle: some View {
        HStack(spacing: 0) {
            ForEach(BinFilter.allCases, id: \.self) { f in
                let active = workspace.binFilter == f
                Text(f == .favorites ? "★ \(f.rawValue)" : f.rawValue)
                    .font(.system(size: 10, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(active ? PreemTheme.accent : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.binFilter = f }
            }
        }
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var orderedClips: [ClipSource] {
        workspace.project.mediaPool.rootBin.children.compactMap { item in
            if case .clip(let id) = item { return workspace.project.mediaPool.clips[id] }
            return nil
        }
    }

    private var allFavorites: [(clip: ClipSource, favorite: FavoriteRange)] {
        orderedClips.flatMap { clip in
            clip.favorites.map { (clip, $0) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if orderedClips.isEmpty && workspace.project.sequences.isEmpty && !workspace.importing {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Drop media here").foregroundStyle(.secondary)
            }
            .padding()
        } else if workspace.binFilter == .favorites && allFavorites.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "star")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No favorites yet")
                    .foregroundStyle(.secondary)
                Text("Skim a clip, mark In/Out, press F")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            workspace.ingest(urls: urls)
        }
        return true
    }
}

// MARK: - Master-clip filmstrip row

private struct FilmstripClipRow: View {
    @ObservedObject var workspace: WorkspaceModel
    let clip: ClipSource

    private var isActive: Bool { workspace.sourceClip?.id == clip.id }
    private var duration: Double { max(0.001, clip.duration.seconds) }
    private var aspect: CGFloat {
        if let v = clip.videoTracks.first, v.resolution.height > 0 {
            return CGFloat(v.resolution.width) / CGFloat(v.resolution.height)
        }
        return 16.0 / 9.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            stripArea
            metadataLine
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? PreemTheme.accent.opacity(0.10) : Color.clear)
        .onAppear {
            if !clip.videoTracks.isEmpty {
                workspace.previewCache.ensureThumbnails(clipID: clip.id, url: clip.url)
            } else if !clip.audioTracks.isEmpty {
                workspace.previewCache.ensureWaveform(clipID: clip.id, url: clip.url)
            }
        }
    }

    private var stripArea: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                // Filmstrip thumbnails (or waveform / placeholder).
                stripContent
                    .frame(width: w, height: geo.size.height)
                    .clipped()

                // Favorite / reject bands across their sub-ranges.
                ForEach(clip.favorites) { fav in
                    let f0 = fav.range.start.seconds / duration
                    let f1 = fav.range.end.seconds / duration
                    Rectangle()
                        .fill(bandColor(fav.rating).opacity(0.9))
                        .frame(width: max(2, CGFloat(f1 - f0) * w), height: 3)
                        .offset(x: CGFloat(f0) * w, y: 0)
                }

                // In/Out selection band (only when this is the active clip).
                if isActive, let band = selectionBand(width: w) {
                    Rectangle()
                        .fill(PreemTheme.accent.opacity(0.22))
                        .frame(width: band.width, height: geo.size.height)
                        .offset(x: band.x, y: 0)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(PreemTheme.accent).frame(width: 1.5)
                                .offset(x: band.x)
                        }
                }

                // Skimmer / playhead line — reflects the live source time.
                if isActive {
                    let x = CGFloat(min(1, max(0, workspace.sourceTimeSeconds / duration))) * w
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1.5)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .offset(x: x - 0.75)
                }

                // Name + badges overlay.
                nameOverlay
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isActive ? PreemTheme.accent : Color.black.opacity(0.4),
                            lineWidth: isActive ? 1.5 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    // Hovering hands transport focus to the source viewer so
                    // Space / J-K-L / I-O / F act on the skimmed clip (FCP).
                    if workspace.focusedViewer != .source { workspace.focusedViewer = .source }
                    let frac = w > 0 ? Double(p.x / w) : 0
                    workspace.skimSource(to: clip, seconds: frac * duration)
                case .ended:
                    break
                }
            }
            .onTapGesture {
                workspace.loadSourceClip(clip)
            }
            .onDrag {
                NSItemProvider(object: clip.id.rawValue.uuidString as NSString)
            }
        }
        .frame(height: 50)
    }

    @ViewBuilder private var stripContent: some View {
        let images = workspace.previewCache.thumbnails(for: clip.id)?.images ?? []
        if !clip.videoTracks.isEmpty {
            if images.isEmpty {
                Rectangle().fill(Color.black.opacity(0.35))
                    .overlay(ProgressView().controlSize(.small))
            } else {
                Filmstrip(images: images, aspect: aspect)
            }
        } else if !clip.audioTracks.isEmpty {
            WaveformStrip(peaks: workspace.previewCache.waveform(for: clip.id)?.peaks ?? [])
        } else {
            Rectangle().fill(Color.black.opacity(0.35))
        }
    }

    private var nameOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                Text(clip.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                ForEach(slateBadges, id: \.self) { SlateBadge(label: $0) }
                if workspace.mlInFlight.contains(clip.id) {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                if !clip.favorites.isEmpty {
                    Label("\(clip.favorites.count)", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.65)],
                               startPoint: .top, endPoint: .bottom)
            )
            .foregroundStyle(.white)
        }
    }

    private var metadataLine: some View {
        Text(secondaryLine)
            .font(PreemTheme.monoSmall)
            .foregroundStyle(PreemTheme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 2)
    }

    private func selectionBand(width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        let inS = workspace.sourceInMark
        let outS = workspace.sourceOutMark
        guard inS != nil || outS != nil else { return nil }
        let s = max(0, min(inS ?? 0, duration))
        let e = max(s, min(outS ?? duration, duration))
        let x0 = CGFloat(s / duration) * width
        let x1 = CGFloat(e / duration) * width
        return (x0, max(2, x1 - x0))
    }

    private func bandColor(_ rating: FavoriteRange.Rating) -> Color {
        rating == .favorite ? .yellow : .red
    }

    private var slateBadges: [String] {
        var out: [String] = []
        if let s = clip.scene { out.append("SC \(s)") }
        if let t = clip.take  { out.append("T \(t)") }
        if let r = clip.roll  { out.append("R \(r)") }
        if let shot = clip.ml.shotType, let abbr = shotAbbreviation(shot) { out.append(abbr) }
        if let transcript = clip.ml.transcript, !transcript.segments.isEmpty { out.append("\u{1F4AC}") }
        return out
    }

    private var secondaryLine: String {
        var bits: [String] = []
        if let v = clip.videoTracks.first {
            bits.append("\(v.resolution.width)×\(v.resolution.height) @ \(v.frameRate.rawValue)")
        }
        if let a = clip.audioTracks.first {
            bits.append("\(a.channelCount)ch \(a.sampleRate)Hz")
        }
        bits.append(String(format: "%.1fs", clip.duration.seconds))
        return bits.joined(separator: " · ")
    }
}

// MARK: - Favorite (subclip) row

private struct FavoriteClipRow: View {
    @ObservedObject var workspace: WorkspaceModel
    let clip: ClipSource
    let favorite: FavoriteRange

    private var duration: Double { max(0.001, clip.duration.seconds) }
    private var favStart: Double { favorite.range.start.seconds }
    private var favDur: Double { max(0.001, favorite.range.duration.seconds) }
    private var f0: Double { favStart / duration }
    private var f1: Double { favorite.range.end.seconds / duration }
    private var aspect: CGFloat {
        if let v = clip.videoTracks.first, v.resolution.height > 0 {
            return CGFloat(v.resolution.width) / CGFloat(v.resolution.height)
        }
        return 16.0 / 9.0
    }
    private var isActive: Bool {
        workspace.sourceClip?.id == clip.id &&
        workspace.sourceTimeSeconds >= favStart &&
        workspace.sourceTimeSeconds <= favorite.range.end.seconds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    stripContent
                        .frame(width: w, height: geo.size.height)
                        .clipped()
                    if isActive {
                        let pos = (workspace.sourceTimeSeconds - favStart) / favDur
                        let x = CGFloat(min(1, max(0, pos))) * w
                        Rectangle().fill(Color.white).frame(width: 1.5)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .offset(x: x - 0.75)
                    }
                    nameOverlay
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.yellow.opacity(isActive ? 0.9 : 0.5),
                                lineWidth: isActive ? 1.5 : 0.75)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p):
                        if workspace.focusedViewer != .source { workspace.focusedViewer = .source }
                        let frac = w > 0 ? Double(p.x / w) : 0
                        workspace.skimSource(to: clip, seconds: favStart + frac * favDur)
                    case .ended:
                        break
                    }
                }
                .onTapGesture {
                    workspace.loadSourceClip(clip)
                    workspace.sourceInMark = favStart
                    workspace.sourceOutMark = favorite.range.end.seconds
                    workspace.sourceTimeSeconds = favStart
                }
                .onDrag {
                    let payload = "\(clip.id.rawValue.uuidString)|\(favStart)|\(favDur)"
                    return NSItemProvider(object: payload as NSString)
                }
                .contextMenu {
                    Button("Remove Favorite", role: .destructive) {
                        workspace.removeFavorite(favorite.id, from: clip.id)
                    }
                }
            }
            .frame(height: 44)
            metadataLine
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onAppear {
            if !clip.videoTracks.isEmpty {
                workspace.previewCache.ensureThumbnails(clipID: clip.id, url: clip.url)
            }
        }
    }

    @ViewBuilder private var stripContent: some View {
        let images = workspace.previewCache.thumbnails(for: clip.id)?.images ?? []
        if !clip.videoTracks.isEmpty && !images.isEmpty {
            Filmstrip(images: images, aspect: aspect, range: (f0, f1))
        } else {
            Rectangle().fill(Color.black.opacity(0.35))
                .overlay(images.isEmpty && !clip.videoTracks.isEmpty
                         ? AnyView(ProgressView().controlSize(.small)) : AnyView(EmptyView()))
        }
    }

    private var nameOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                Text(favorite.name ?? "Favorite")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(clip.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.65)],
                               startPoint: .top, endPoint: .bottom)
            )
            .foregroundStyle(.white)
        }
    }

    private var metadataLine: some View {
        Text(String(format: "%@ · %.1fs", clip.name, favDur))
            .font(PreemTheme.monoSmall)
            .foregroundStyle(PreemTheme.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 2)
    }
}

// MARK: - Filmstrip drawing

/// Tiles evenly-spaced still frames across the available width at the
/// source's natural aspect (no squish — the trailing cell is clipped).
/// `range` selects a sub-span [0,1] of the source (used by favorites).
private struct Filmstrip: View {
    let images: [CGImage]
    let aspect: CGFloat
    var range: (Double, Double) = (0, 1)

    var body: some View {
        Canvas { ctx, size in
            guard !images.isEmpty, size.width > 0, size.height > 0 else { return }
            let h = size.height
            let cellW = max(8, h * aspect)
            let n = max(1, Int(ceil(size.width / cellW)))
            let lo = max(0, min(1, range.0))
            let hi = max(lo, min(1, range.1))
            for i in 0..<n {
                let cellFrac = n == 1 ? 0.5 : (Double(i) + 0.5) / Double(n)
                let frac = lo + (hi - lo) * cellFrac
                let idx = min(images.count - 1,
                              max(0, Int((frac * Double(images.count - 1)).rounded())))
                let rect = CGRect(x: CGFloat(i) * cellW, y: 0, width: cellW, height: h)
                ctx.draw(Image(decorative: images[idx], scale: 1), in: rect)
            }
        }
        .background(Color.black)
    }
}

/// Simple peak waveform fill for audio-only clips.
private struct WaveformStrip: View {
    let peaks: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            let mid = size.height / 2
            var path = Path()
            let n = peaks.count
            for x in stride(from: 0, to: size.width, by: 1) {
                let i = min(n - 1, Int(Double(x) / Double(size.width) * Double(n)))
                let amp = CGFloat(peaks[i]) * (size.height / 2)
                path.move(to: CGPoint(x: x, y: mid - amp))
                path.addLine(to: CGPoint(x: x, y: mid + amp))
            }
            ctx.stroke(path, with: .color(PreemTheme.accent.opacity(0.7)), lineWidth: 1)
        }
        .background(Color.black.opacity(0.4))
    }
}

// MARK: - Shared bits

private func shotAbbreviation(_ shot: ShotType) -> String? {
    switch shot {
    case .extremeWide:     return "EW"
    case .wide:            return "WS"
    case .medium:          return "MS"
    case .mediumCloseUp:   return "MCU"
    case .closeUp:         return "CU"
    case .extremeCloseUp:  return "ECU"
    case .insert:          return "INS"
    case .unknown:         return nil
    }
}

private struct SlateBadge: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(PreemTheme.accent.opacity(0.85))
            .foregroundStyle(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

private struct SequenceRow: View {
    let sequence: Sequence
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .frame(width: 18)
                .foregroundStyle(isActive ? PreemTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(sequence.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isActive ? PreemTheme.accent.opacity(0.22) : Color.clear)
    }

    private var secondaryLine: String {
        let res = sequence.settings.resolution
        let fr = sequence.settings.frameRate.rawValue
        let videoClips = sequence.videoTracks.flatMap(\.clips).count
        let audioClips = sequence.audioTracks.flatMap(\.clips).count
        let total = videoClips + audioClips
        return "\(res.width)×\(res.height) @ \(fr) · \(total) clip\(total == 1 ? "" : "s")"
    }
}
