import SwiftUI
import PreemCore

/// Shown the first time a clip is dropped onto an empty sequence whose
/// specs don't match the clip. Three outcomes: match sequence to clip
/// (sequence gets the clip's settings), keep sequence as-is (the clip
/// will be scaled / conformed at playback), or cancel the drop.
public struct SequenceMismatchSheet: View {
    public let pending: PendingMismatch
    public let onMatch: () -> Void
    public let onKeep: () -> Void
    public let onCancel: () -> Void

    public init(pending: PendingMismatch,
                onMatch: @escaping () -> Void,
                onKeep: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.pending = pending
        self.onMatch = onMatch
        self.onKeep = onKeep
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
                Text("Clip settings differ from sequence")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("The clip you dropped doesn't match this sequence's settings:")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))

                ForEach(Array(pending.mismatch.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(field.description).font(.system(size: 12))
                    }
                }

                Text("Match Sequence to Clip will change the sequence to use the clip's settings. Keep Sequence as-is will conform the clip at playback (it'll be scaled / resampled to fit).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .padding(16)

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Keep Sequence", action: onKeep)
                Button("Match Sequence to Clip", action: onMatch)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 480)
    }
}
