import SwiftUI
import UniformTypeIdentifiers
import PreemCore

struct BinBrowserView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scrollableContent
        }
        .background(Color(NSColor.windowBackgroundColor))
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
                clipsSection
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
                ClipRow(
                    clip: clip,
                    isSelected: workspace.sourceClip?.id == clip.id,
                    mlInFlight: workspace.mlInFlight.contains(clip.id)
                )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        workspace.sourceClip = clip
                        workspace.focusedViewer = .bin
                    }
                    .onDrag {
                        NSItemProvider(object: clip.id.rawValue.uuidString as NSString)
                    }
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
        HStack {
            Text("Master")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
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

    private var orderedClips: [ClipSource] {
        workspace.project.mediaPool.rootBin.children.compactMap { item in
            if case .clip(let id) = item { return workspace.project.mediaPool.clips[id] }
            return nil
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

private struct ClipRow: View {
    let clip: ClipSource
    let isSelected: Bool
    let mlInFlight: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(clip.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    ForEach(slateBadges, id: \.self) { badge in
                        SlateBadge(label: badge)
                    }
                    if mlInFlight {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(secondaryLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
    }

    private var iconName: String {
        if !clip.videoTracks.isEmpty { return "film" }
        if !clip.audioTracks.isEmpty { return "waveform" }
        return "doc"
    }

    private var slateBadges: [String] {
        var out: [String] = []
        if let s = clip.scene { out.append("SC \(s)") }
        if let t = clip.take  { out.append("T \(t)") }
        if let r = clip.roll  { out.append("R \(r)") }
        if let shot = clip.ml.shotType, let abbr = shotAbbreviation(shot) {
            out.append(abbr)
        }
        if let transcript = clip.ml.transcript, !transcript.segments.isEmpty {
            out.append("\u{1F4AC}")   // 💬 — has transcript
        }
        return out
    }

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

private struct SlateBadge: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18))
            .foregroundStyle(Color.accentColor)
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
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
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
        .background(isActive ? Color.accentColor.opacity(0.22) : Color.clear)
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
