import SwiftUI
import AppKit
import KineCore

/// Develop View: one specimen at a time. The selected shot fills the
/// space; scrub, grade, trim, mark, ramp, then move to the next with the
/// arrows or the strip. Selectable from the project bar (Bin | Develop);
/// Cmd+F jumps here and toggles native fullscreen with it. The project
/// bar rides above, the inspector sits at the side, and the skimmable
/// shot strip stays reachable below.
struct ShotDevelopView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ShotPlayerView(workspace: workspace, large: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                KeyGlyphBar(glyphs: workspace.keyGlyphs)
                Divider()
                if !ProcessInfo.processInfo.arguments.contains("--nostrip") {
                    shotStrip
                }
            }
            Divider()
            ShotGradePanel(workspace: workspace, showPlayer: false)
                .frame(width: 330)
        }
        .background(KineTheme.bg)
    }

    /// The whole folder within reach: the same skimmable cards as the
    /// grid, one row, following the selection.
    private var shotStrip: some View {
        HStack(spacing: 0) {
            stepButton(systemImage: "chevron.left", delta: -1, key: "Up arrow")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(workspace.orderedShots) { shot in
                            ShotCard(workspace: workspace, previews: workspace.previewTicker, shot: shot)
                                .frame(width: 230)
                                .id(shot.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: workspace.selectedShotID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onAppear {
                    if let id = workspace.selectedShotID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            stepButton(systemImage: "chevron.right", delta: 1, key: "Down arrow")
        }
        .frame(height: 132)
        .background(KineTheme.bgPanel)
    }

    private func stepButton(systemImage: String, delta: Int, key: String) -> some View {
        Button {
            workspace.selectAdjacentShot(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 100)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(KineTheme.textMuted)
        .help("\(delta < 0 ? "Previous" : "Next") shot (key: \(key))")
    }
}

/// Keycap chips that light while their key is held, so the controls teach
/// themselves (the Swipe Verify pattern from npoc).
struct KeyGlyphBar: View {
    @ObservedObject var glyphs: WorkspaceModel.KeyGlyphState

    var body: some View {
        HStack(spacing: 14) {
            glyph(["space"], "play")
            glyph(["j", "k", "l"], "shuttle")
            glyph(["left", "right"], "step")
            glyph(["i", "o"], "in / out")
            glyph(["i+o"], "clear")
            glyph(["m"], "mark still")
            glyph(["up", "down"], "prev / next")
            Spacer()
            Text("Esc leaves fullscreen, then Develop")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(KineTheme.bgPanel)
    }

    private func glyph(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(display(key))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(pressed(key) ? KineTheme.accent : Color.white.opacity(0.08))
                    .foregroundStyle(pressed(key) ? Color.black : KineTheme.textMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func pressed(_ key: String) -> Bool {
        if key == "i+o" { return glyphs.pressed.contains("i") && glyphs.pressed.contains("o") }
        return glyphs.pressed.contains(key)
    }

    private func display(_ key: String) -> String {
        switch key {
        case "space": return "SPACE"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "i+o": return "I+O"
        default: return key.uppercased()
        }
    }
}
