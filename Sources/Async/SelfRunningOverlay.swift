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
                Text("次の Sync は \(Self.formatRemaining(remaining)) 後")
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
            }

            Text(nextSyncAt.formatted(date: .abbreviated, time: .shortened))
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("スケジュール変更") {
                    isSchedulingSheetPresented = true
                }
                Button("今すぐ Sync") {
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
        .alert("今すぐ Sync しますか？", isPresented: $isSyncNowConfirmPresented) {
            Button("キャンセル", role: .cancel) {}
            Button("開始") { onSyncNow() }
        } message: {
            Text("裏で走っている自走作業が中断されます。")
        }
    }

    /// Formats a future interval as "2h 14m", "18m", or "1分未満" (floor).
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
        return "1分未満"
    }
}
