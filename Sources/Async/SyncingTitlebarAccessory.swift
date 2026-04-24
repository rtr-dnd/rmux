import AppKit
import Combine
import SwiftUI

/// Titlebar accessory that hosts one of two rmux Async affordances,
/// depending on the currently-selected workspace in this window:
///   - **syncing workspace**: the elapsed-time HUD + "End Sync" button
///     (`SyncingActionBar`).
///   - **any other state** (Normal workspace, preparing, selfRunning,
///     awaitingAttendance): an "Async 作業を開始" menu button that expands
///     into "今すぐ Sync / 後で Sync…" — the same two affordances already
///     in the File menu, surfaced in the toolbar for one-click access.
///
/// Per-window: each main window owns its own instance and observes its
/// own `TabManager` for the currently-selected workspace. The menu
/// button always creates a new Async workspace (inheriting the focused
/// workspace's cwd); it never mutates the currently-selected one.
///
/// See docs-rmux/spec.md §6.1.4.
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

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
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
/// Observes `TabManager` (selectedTabId + tabs list) and flips between
/// the syncing pill and the "Async 作業を開始" menu based on the
/// selected workspace's phase. Two-level structure so the inner pill can
/// separately observe the workspace: `TabManager` changes trigger
/// re-selection, `Workspace` changes trigger phase-aware re-rendering.
struct SyncingTitlebarContent: View {
    @ObservedObject var tabManager: TabManager

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let workspace = syncingCandidate() {
                SyncingTitlebarInner(workspace: workspace)
            } else {
                AsyncStartMenu()
            }
        }
        .frame(maxWidth: .infinity)
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
/// Falls back to the `AsyncStartMenu` for any non-syncing phase so the
/// titlebar slot stays useful even in preparing / selfRunning /
/// awaitingAttendance.
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
            AsyncStartMenu()
        }
    }
}

/// Menu button shown in the titlebar accessory when no syncing workspace
/// is selected. Expands into the two new-Async-workspace creation flows
/// that live in the File menu (`NewAsyncWorkspaceFlow.createNow` /
/// `createLater`), so the user doesn't have to hunt through menus to
/// start a Sync.
private struct AsyncStartMenu: View {
    var body: some View {
        Menu {
            Button {
                _ = NewAsyncWorkspaceFlow.createNow(
                    debugSource: "titlebar.asyncStart.now"
                )
            } label: {
                Text(String(localized: "async.titlebar.start.now",
                            defaultValue: "Sync Now"))
            }
            Button {
                NewAsyncWorkspaceFlow.createLater(
                    debugSource: "titlebar.asyncStart.later"
                )
            } label: {
                Text(String(localized: "async.titlebar.start.later",
                            defaultValue: "Sync Later…"))
            }
        } label: {
            // Manual primary-blue styling: SwiftUI's Menu doesn't play
            // nicely with `.buttonStyle(.borderedProminent)` on macOS, so
            // we paint the label ourselves (accent fill + white text) to
            // get a visible primary-action button in the titlebar.
            HStack(spacing: 5) {
                Image(systemName: "calendar.badge.plus")
                Text(String(localized: "async.titlebar.start.menu",
                            defaultValue: "Start Async Session"))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .opacity(0.85)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 8)
    }
}
