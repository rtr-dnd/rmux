import SwiftUI

/// Compact pill rendered over the top-right of a workspace while it is in
/// the `syncing` phase. Combines:
///   - the elapsed-time HUD (`HH:MM:SS / 予定 HH:MM:SS`, with red flashing
///     overrun display — docs-rmux/plan.md §6.5 & spec.md §6.1.4), and
///   - the "Sync を終える / 次回を予定…" affordance that ends the session via
///     `ScheduleNextSyncSheet` (plan.md §8 Step 5).
struct SyncingActionBar: View {
    let syncStartedAt: Date
    let plannedDuration: TimeInterval
    let onEndSync: (ScheduledSync) -> Void

    @State private var isSchedulingSheetPresented = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(syncStartedAt))
            let overrunSeconds = elapsed - plannedDuration
            let isOverrun = overrunSeconds > 0
            // 1 Hz blink when over time: on at even seconds, dim at odd seconds.
            let blinkVisible = !isOverrun || (Int(elapsed) % 2 == 0)

            HStack(spacing: 10) {
                hudView(
                    elapsed: elapsed,
                    overrun: overrunSeconds,
                    isOverrun: isOverrun,
                    blinkVisible: blinkVisible
                )
                Button {
                    isSchedulingSheetPresented = true
                } label: {
                    Label("Sync を終える", systemImage: "calendar.badge.plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        }
        .sheet(isPresented: $isSchedulingSheetPresented) {
            ScheduleNextSyncSheet(
                initialDate: nil,
                onConfirm: { scheduled in
                    isSchedulingSheetPresented = false
                    onEndSync(scheduled)
                },
                onCancel: {
                    isSchedulingSheetPresented = false
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
            Text("/ 予定 \(Self.formatHMS(plannedDuration))")
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
