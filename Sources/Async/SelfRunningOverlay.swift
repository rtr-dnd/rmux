import SwiftUI

/// Overlay shown while an Async workspace is in the `selfRunning` phase.
/// See docs-rmux/spec.md §6.1.1 and plan.md §6.3. Phase 1 Step 3 shell.
struct SelfRunningOverlay: View {
    let workspaceTitle: String
    let nextSyncAt: Date
    let onChangeSchedule: () -> Void
    let onSyncNow: () -> Void

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
                Button("スケジュール変更", action: onChangeSchedule)
                Button("今すぐ Sync", action: onSyncNow)
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

    /// Formats a future interval as "2h 14m", "18m", or "1m" (floor).
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
        return "1m未満"
    }
}
