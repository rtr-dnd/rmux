import SwiftUI

/// Compact floating bar rendered over the top-right of a workspace while it
/// is in the `syncing` phase. Hosts the "Sync を終える / 次回を予定…" affordance
/// that ends the current session and transitions to `selfRunning` with a
/// user-picked next-sync time. See docs-rmux/plan.md §8 Step 5 and §6.7.
///
/// Phase 1 Step 9 (elapsed-time HUD) will expand this bar with the live
/// HH:MM:SS counter and overrun warning; until then the bar carries the
/// end-sync button alone.
struct SyncingActionBar: View {
    let onEndSync: (ScheduledSync) -> Void

    @State private var isSchedulingSheetPresented = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isSchedulingSheetPresented = true
            } label: {
                Label("Sync を終える / 次回を予定…", systemImage: "calendar.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
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
}
