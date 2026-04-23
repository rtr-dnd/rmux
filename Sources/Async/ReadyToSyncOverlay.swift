import SwiftUI

/// Overlay shown when an Async workspace is in the `preparing` phase.
/// See docs-rmux/spec.md §6.1.3 and plan.md §6.2. This is a Phase 1 Step 3
/// shell: layout + buttons only; copy is not yet localised.
struct ReadyToSyncOverlay: View {
    /// Workspace label displayed at the top. Passed in to keep this view
    /// independent of the Workspace model (easier to preview).
    let workspaceTitle: String
    /// Invoked with the picked duration (seconds) when the user taps Start.
    let onStart: (TimeInterval) -> Void
    /// Invoked when the user taps Cancel.
    let onCancel: () -> Void

    /// Planned-duration options in minutes. Matches spec.md §4.1.
    private static let durationMinuteOptions: [Int] = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let defaultDurationMinutes = 30

    @State private var plannedMinutes: Int = ReadyToSyncOverlay.defaultDurationMinutes

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Text(workspaceTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Ready to sync")
                .font(.system(size: 40, weight: .semibold, design: .default))

            VStack(alignment: .leading, spacing: 8) {
                Text("予定時間")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("予定時間", selection: $plannedMinutes) {
                    ForEach(Self.durationMinuteOptions, id: \.self) { minutes in
                        Text(Self.formatDuration(minutes: minutes))
                            .tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("開始") {
                    onStart(TimeInterval(plannedMinutes * 60))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture {}  // absorb taps so nothing leaks through to the terminal
    }

    private static func formatDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        let hours = Double(minutes) / 60.0
        return String(format: "%.1fh", hours)
    }
}
