import SwiftUI

/// HUD + "End Sync" affordance that lives in the window's titlebar right
/// accessory while the workspace is `syncing`. No chrome of its own (no
/// pill background, border, or shadow) so it blends into the titlebar.
/// Combines:
///   - the elapsed-time HUD (`HH:MM:SS / 予定 HH:MM:SS`, with red flashing
///     overrun display — docs-rmux/plan.md §6.5 & spec.md §6.1.4), and
///   - the "Sync を終える / 次回を予定…" affordance that ends the session via
///     `ScheduleNextSyncSheet` (plan.md §8 Step 5).
struct SyncingActionBar: View {
    let syncStartedAt: Date
    let plannedDuration: TimeInterval
    let onEndSync: (ScheduledSync) -> Void
    /// Invoked when the user picks "スケジュールせずに終了" inside the end-sync
    /// sheet — end the Sync without committing to a next session. Threaded
    /// to the sheet so "End Sync" and "End without scheduling" live in the
    /// same modal. See docs-rmux/spec.md §4.6.
    let onEndSyncAndRevert: () -> Void

    @State private var isSchedulingSheetPresented = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(syncStartedAt))
            let overrunSeconds = elapsed - plannedDuration
            let isOverrun = overrunSeconds > 0
            // 1 Hz blink when over time: on at even seconds, dim at odd seconds.
            let blinkVisible = !isOverrun || (Int(elapsed) % 2 == 0)

            HStack(spacing: 8) {
                hudView(
                    elapsed: elapsed,
                    overrun: overrunSeconds,
                    isOverrun: isOverrun,
                    blinkVisible: blinkVisible
                )
                Button {
                    isSchedulingSheetPresented = true
                } label: {
                    Label(
                        String(localized: "async.syncing.endSyncButton", defaultValue: "End Sync"),
                        systemImage: "calendar.badge.plus"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $isSchedulingSheetPresented) {
            // Pre-fill the next Sync's duration with the current session's
            // planned duration — users who picked 45m for this Sync often
            // want 45m for the next one too. The revert-to-Normal path
            // lives here as an explicit "End without scheduling" action in
            // the sheet's footer; that way all end-of-sync choices live in
            // one modal instead of scattering buttons across the pill.
            ScheduleNextSyncSheet(
                initialDate: nil,
                initialPlannedDuration: plannedDuration,
                onConfirm: { scheduled in
                    isSchedulingSheetPresented = false
                    onEndSync(scheduled)
                },
                onCancel: {
                    isSchedulingSheetPresented = false
                },
                onEndWithoutSchedule: {
                    isSchedulingSheetPresented = false
                    onEndSyncAndRevert()
                }
            )
        }
    }

    @ViewBuilder
    private func hudView(
        elapsed: TimeInterval,
        overrun: TimeInterval,
        isOverrun: Bool,
        blinkVisible: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(Self.formatHMS(elapsed))
                .monospacedDigit()
                .foregroundStyle(isOverrun ? .red : .primary)
                .opacity(blinkVisible ? 1.0 : 0.45)
            let plannedLabel = Self.formatHMS(plannedDuration)
            Text(String(localized: "async.syncing.plannedSuffix",
                        defaultValue: "/ planned \(plannedLabel)"))
                .foregroundStyle(.secondary)
            if isOverrun {
                Text(" (+\(Self.formatHMS(overrun)))")
                    .foregroundStyle(.red)
                    .monospacedDigit()
                    .opacity(blinkVisible ? 1.0 : 0.45)
            }
        }
        .font(.body)
    }

    /// Render a non-negative `TimeInterval` as `HH:MM:SS`.
    static func formatHMS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
