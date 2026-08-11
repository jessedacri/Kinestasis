import Foundation
import SwiftUI
import KineCore

/// App-wide settings persisted to UserDefaults. Currently scoped to
/// transition defaults; future preferences (autosave interval, proxy
/// directory, etc.) land here too.
@MainActor
public final class KineSettings: ObservableObject {
    public static let shared = KineSettings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let defaultTransitionKind = "kine.transition.defaultKind"
        static let defaultTransitionFrames = "kine.transition.defaultFrames"
        static let snappingEnabled = "kine.timeline.snappingEnabled"
    }

    /// Whether timeline drags snap to neighboring edges + the playhead.
    /// Toggleable with the `N` key (Premiere-style). Persists across
    /// launches.
    @Published public var snappingEnabled: Bool {
        didSet { defaults.set(snappingEnabled, forKey: Keys.snappingEnabled) }
    }

    /// Identifier of the transition kind applied when the user invokes
    /// "Add Transition" without specifying one (⌘D or the right-click
    /// menu). Currently only `"crossDissolve"` is rendered; other
    /// values round-trip in the settings UI as a forward path.
    @Published public var defaultTransitionKind: String {
        didSet { defaults.set(defaultTransitionKind, forKey: Keys.defaultTransitionKind) }
    }

    /// Default transition length, expressed in frames. Converted to
    /// seconds against the active sequence's frame rate at apply time.
    /// Default 30 frames (~1 s at 30 fps, ~1.25 s at 24 fps).
    @Published public var defaultTransitionFrames: Int {
        didSet { defaults.set(defaultTransitionFrames, forKey: Keys.defaultTransitionFrames) }
    }

    private init() {
        if let kind = defaults.string(forKey: Keys.defaultTransitionKind), !kind.isEmpty {
            self.defaultTransitionKind = kind
        } else {
            self.defaultTransitionKind = "crossDissolve"
        }
        let storedFrames = defaults.integer(forKey: Keys.defaultTransitionFrames)
        self.defaultTransitionFrames = storedFrames > 0 ? storedFrames : 30
        if defaults.object(forKey: Keys.snappingEnabled) == nil {
            self.snappingEnabled = true
        } else {
            self.snappingEnabled = defaults.bool(forKey: Keys.snappingEnabled)
        }
    }

    /// Default transition duration in seconds, derived from
    /// `defaultTransitionFrames` and the given sequence's frame rate.
    /// Falls back to 1.0 s if no sequence is provided.
    public func defaultTransitionSeconds(for sequence: Sequence?) -> Double {
        let fps = sequence?.settings.frameRate.fps ?? 30.0
        guard fps > 0 else { return 1.0 }
        return Double(defaultTransitionFrames) / fps
    }
}

/// Catalog of transition kinds shown in the settings picker. Today
/// only `crossDissolve` actually renders; the others are placeholders
/// so the UI's shape matches where the feature is going.
public enum TransitionKindCatalog {
    public static let all: [(id: String, label: String)] = [
        ("crossDissolve", "Cross Dissolve"),
        ("dipToBlack", "Dip to Black (coming soon)"),
        ("dipToWhite", "Dip to White (coming soon)"),
    ]
}

/// Preferences pane shown from the macOS `Settings…` menu item.
public struct KineSettingsView: View {
    @ObservedObject private var settings = KineSettings.shared

    public init() {}

    public var body: some View {
        Form {
            Section("Transitions") {
                Picker("Default style", selection: $settings.defaultTransitionKind) {
                    ForEach(TransitionKindCatalog.all, id: \.id) { kind in
                        Text(kind.label).tag(kind.id)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Text("Default length")
                    Spacer()
                    TextField(
                        "",
                        value: Binding(
                            get: { settings.defaultTransitionFrames },
                            set: { settings.defaultTransitionFrames = max(1, $0) }
                        ),
                        format: .number
                    )
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    Stepper(
                        "",
                        value: Binding(
                            get: { settings.defaultTransitionFrames },
                            set: { settings.defaultTransitionFrames = max(1, $0) }
                        ),
                        in: 1...600
                    )
                    .labelsHidden()
                    Text("frames").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(KineTheme.bg)
        .frame(width: 460, height: 200)
        .preferredColorScheme(.dark)
        .tint(KineTheme.accent)
    }
}
