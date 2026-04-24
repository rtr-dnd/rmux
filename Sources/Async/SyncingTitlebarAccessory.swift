import AppKit
import Combine
import SwiftUI

/// Titlebar accessory that hosts the syncing-phase HUD + End Sync button
/// in the main window's toolbar area, replacing the old child-window pill
/// that floated over the terminal. Users kept asking for the pill to live
/// somewhere less obtrusive, and AppKit's `NSTitlebarAccessoryViewController`
/// gives us a right-aligned slot that stays out of the way of terminal
/// content. See docs-rmux/spec.md §6.1.4.
///
/// Per-window: each main window owns its own instance and observes its
/// own `TabManager` for the currently-selected workspace. When that
/// workspace is in `.syncing`, the accessory renders `SyncingActionBar`;
/// otherwise the hosting view is empty (width 0) and effectively invisible
/// but still attached — avoids flicker from repeatedly adding/removing.
@MainActor
final class SyncingTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    static let accessoryIdentifier = NSUserInterfaceItemIdentifier("rmux.syncing.titlebar.accessory")

    private let tabManager: TabManager
    private var hostingView: NSHostingView<SyncingTitlebarContent>!
    private var cancellables: Set<AnyCancellable> = []

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)

        let content = SyncingTitlebarContent(tabManager: tabManager)
        hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        hostingView.frame = container.bounds
        view = container
        view.identifier = Self.accessoryIdentifier
        layoutAttribute = .right
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) unavailable")
    }
}

/// SwiftUI content hosted by `SyncingTitlebarAccessoryViewController`.
/// Observes `TabManager` (selectedTabId + tabs list) so the pill appears
/// when the *selected* workspace transitions into `.syncing`. Two-level
/// structure so the inner view can separately observe the workspace:
/// `TabManager` changes trigger re-selection, `Workspace` changes
/// trigger phase-aware re-rendering.
struct SyncingTitlebarContent: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        if let workspace = syncingCandidate() {
            SyncingTitlebarInner(workspace: workspace)
        } else {
            // Not syncing — collapse to zero width so the accessory slot
            // doesn't steal titlebar space.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @MainActor
    private func syncingCandidate() -> Workspace? {
        guard let id = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == id }),
              workspace.mode == .async else {
            return nil
        }
        return workspace
    }
}

/// Inner view that observes the candidate workspace's own state so the
/// pill's internal content (elapsed HUD, overrun blink) refreshes when
/// the workspace mutates without waiting on a TabManager-level signal.
private struct SyncingTitlebarInner: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if workspace.asyncPhase == .syncing,
           let startedAt = workspace.syncStartedAt,
           let planned = workspace.plannedDuration {
            SyncingActionBar(
                syncStartedAt: startedAt,
                plannedDuration: planned,
                onEndSync: { scheduled in
                    workspace.nextSyncPlannedDuration = scheduled.plannedDuration
                    try? workspace.transition(
                        .endSyncing(nextSyncAt: scheduled.at, at: Date())
                    )
                },
                onEndSyncAndRevert: {
                    try? workspace.transition(.endSyncingAndRevert(at: Date()))
                }
            )
            .padding(.trailing, 8)
            .fixedSize()
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}
