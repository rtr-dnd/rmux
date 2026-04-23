import SwiftUI

/// Overlay shown when an Async workspace is in the `awaitingAttendance` phase.
/// See docs-rmux/spec.md §6.1.2 and plan.md §6.4. Phase 1 Step 3 shell.
struct OverdueOverlay: View {
    let workspaceTitle: String
    let scheduledAt: Date
    let onStartNow: () -> Void
    let onReschedule: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Text(workspaceTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                let overdue = context.date.timeIntervalSince(scheduledAt)
                Text("Overdue — 予定は \(SelfRunningOverlay.formatRemaining(overdue)) 前")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }

            Text(scheduledAt.formatted(date: .abbreviated, time: .shortened))
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("リスケ", action: onReschedule)
                Button("今すぐ開始", action: onStartNow)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}
