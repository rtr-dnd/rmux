import SwiftUI

/// Overlay shown when an Async workspace is in the `awaitingAttendance` phase.
/// See docs-rmux/spec.md §6.1.2 and plan.md §6.4.
struct OverdueOverlay: View {
    let workspaceTitle: String
    let scheduledAt: Date
    let onStartNow: () -> Void
    /// Invoked with the user's picked future time when "リスケ" is confirmed.
    let onReschedule: (ScheduledSync) -> Void

    @State private var isSchedulingSheetPresented = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Text(workspaceTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                let overdue = context.date.timeIntervalSince(scheduledAt)
                let overdueLabel = SelfRunningOverlay.formatRemaining(overdue)
                Text(String(localized: "async.overdue.title",
                            defaultValue: "Overdue — \(overdueLabel) ago"))
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }

            Text(scheduledAt.formatted(date: .abbreviated, time: .shortened))
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(String(localized: "async.overdue.rescheduleButton", defaultValue: "Reschedule")) {
                    isSchedulingSheetPresented = true
                }
                Button(String(localized: "async.overdue.startNowButton", defaultValue: "Start Now"),
                       action: onStartNow)
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
        .sheet(isPresented: $isSchedulingSheetPresented) {
            ScheduleNextSyncSheet(
                initialDate: nil,  // overdue → don't pre-fill the past date
                onConfirm: { scheduled in
                    isSchedulingSheetPresented = false
                    onReschedule(scheduled)
                },
                onCancel: {
                    isSchedulingSheetPresented = false
                }
            )
        }
    }
}
