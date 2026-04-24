import SwiftUI

/// Overlay shown while an Async workspace is in the `selfRunning` phase.
/// See docs-rmux/spec.md §6.1.1 and plan.md §6.3.
struct SelfRunningOverlay: View {
    let workspaceTitle: String
    let nextSyncAt: Date
    /// Invoked with the user's picked time when "スケジュール変更" is confirmed.
    let onReschedule: (ScheduledSync) -> Void
    /// Invoked when the user taps "今すぐ Sync".
    let onSyncNow: () -> Void

    @State private var isSchedulingSheetPresented = false
    @State private var isSyncNowConfirmPresented = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Text(workspaceTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            TimelineView(.periodic(from: .now, by: 30)) { context in
                let remaining = nextSyncAt.timeIntervalSince(context.date)
                let remainingLabel = Self.formatRemaining(remaining)
                Text(String(localized: "async.selfRunning.nextSyncCountdown",
                            defaultValue: "Next Sync in \(remainingLabel)"))
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
            }

            Text(nextSyncAt.formatted(date: .abbreviated, time: .shortened))
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(String(localized: "async.selfRunning.rescheduleButton", defaultValue: "Reschedule")) {
                    isSchedulingSheetPresented = true
                }
                Button(String(localized: "async.selfRunning.syncNowButton", defaultValue: "Sync Now")) {
                    isSyncNowConfirmPresented = true
                }
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
                initialDate: nextSyncAt,
                onConfirm: { scheduled in
                    isSchedulingSheetPresented = false
                    onReschedule(scheduled)
                },
                onCancel: {
                    isSchedulingSheetPresented = false
                }
            )
        }
        // Phase 1 Step 10: minimal confirmation before the self-running
        // interrupt. The stronger cwd-full-path friction lives in Phase 2
        // (spec.md §6.1.6); this covers the MVP floor.
        .alert(
            String(localized: "async.selfRunning.confirmSyncNow.title", defaultValue: "Start Sync now?"),
            isPresented: $isSyncNowConfirmPresented
        ) {
            Button(String(localized: "async.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(String(localized: "async.common.start", defaultValue: "Start")) { onSyncNow() }
        } message: {
            Text(String(localized: "async.selfRunning.confirmSyncNow.message",
                        defaultValue: "The self-running agent session will be interrupted."))
        }
    }

    /// Formats a future interval as "2h 14m", "18m", or "<1m" (floor).
    /// Negative values (past) render as "0m" so the UI never shows negatives.
    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return String(localized: "async.selfRunning.remainingUnderMinute", defaultValue: "<1m")
    }
}
