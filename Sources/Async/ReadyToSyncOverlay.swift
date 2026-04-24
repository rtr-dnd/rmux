import SwiftUI

/// Overlay shown when an Async workspace is in the `preparing` phase.
/// See docs-rmux/spec.md §6.1.3 and plan.md §6.2. This is a Phase 1 Step 3
/// shell: layout + buttons only; copy is not yet localised.
struct ReadyToSyncOverlay: View {
    /// Workspace label displayed at the top. Passed in to keep this view
    /// independent of the Workspace model (easier to preview).
    let workspaceTitle: String
    /// Current working directory (raw path) — rendered abbreviated under
    /// the title so the human knows which project this Sync is for.
    let cwd: String?
    /// Current git branch name (if any).
    let branch: String?
    /// Whether the working tree has uncommitted changes.
    let isDirty: Bool
    /// Duration (seconds) chosen at schedule-time for this upcoming Sync.
    /// When set, the picker pre-selects the nearest option so the user
    /// doesn't re-pick. `nil` → default 30 min. See spec.md §4.1.
    let initialPlannedDuration: TimeInterval?
    /// Invoked with the picked duration (seconds) when the user taps Start.
    let onStart: (TimeInterval) -> Void
    /// Invoked when the user taps Cancel.
    let onCancel: () -> Void

    /// Planned-duration options in minutes. Matches spec.md §4.1.
    private static let durationMinuteOptions: [Int] = [15, 30, 45, 60, 90, 120, 180, 240]
    private static let defaultDurationMinutes = 30

    @State private var plannedMinutes: Int

    init(
        workspaceTitle: String,
        cwd: String? = nil,
        branch: String? = nil,
        isDirty: Bool = false,
        initialPlannedDuration: TimeInterval? = nil,
        onStart: @escaping (TimeInterval) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workspaceTitle = workspaceTitle
        self.cwd = cwd
        self.branch = branch
        self.isDirty = isDirty
        self.initialPlannedDuration = initialPlannedDuration
        self.onStart = onStart
        self.onCancel = onCancel
        let proposed = initialPlannedDuration
            .map { Int($0 / 60) }
            .flatMap { value in
                Self.durationMinuteOptions.min(by: { abs($0 - value) < abs($1 - value) })
            } ?? Self.defaultDurationMinutes
        _plannedMinutes = State(initialValue: proposed)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Text(workspaceTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            AsyncOverlayContextLine(cwd: cwd, branch: branch, isDirty: isDirty)

            Text(String(localized: "async.readyToSync.title", defaultValue: "Ready to sync"))
                .font(.system(size: 40, weight: .semibold, design: .default))

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "async.readyToSync.plannedDuration", defaultValue: "Planned duration"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker(String(localized: "async.readyToSync.plannedDuration", defaultValue: "Planned duration"), selection: $plannedMinutes) {
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
                Button(String(localized: "async.common.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "async.common.start", defaultValue: "Start")) {
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
