import AppKit
import SwiftUI

/// Presentation helpers for the "new Async workspace" user flows.
/// See docs-rmux/plan.md §8 Step 13 and spec.md §3.1 (`convertToAsync`).
///
/// Two entry points:
///   - `createAsyncWorkspaceNow` — creates a new workspace and immediately
///     converts it to `.preparing` (the Ready-to-sync overlay takes over).
///   - `createAsyncWorkspaceLater` — creates a new workspace, asks the user
///     for the next Sync time via `ScheduleNextSyncSheet`, then converts it
///     to `.selfRunning` anchored to that time.
enum NewAsyncWorkspaceFlow {

    /// Create a new workspace in the preferred main window and convert it to
    /// `.preparing`. Returns the new workspace's id, or `nil` if creation
    /// failed (e.g. no main window context).
    @discardableResult
    @MainActor
    static func createNow(debugSource: String) -> UUID? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        guard let id = appDelegate.addWorkspaceInPreferredMainWindow(
            debugSource: debugSource
        ) else {
            return nil
        }
        // The workspace may live in any window's TabManager — search them all.
        // Searching only `appDelegate.tabManager` misses workspaces created in
        // additional windows and silently drops the Async transition.
        guard let workspace = appDelegate.findWorkspace(id: id) else {
            return id
        }
        do {
            try workspace.transition(
                .convertToAsync(initialPhase: .preparing, nextSyncAt: nil),
                reason: debugSource
            )
        } catch {
            // Leave the workspace in Normal mode; the user can still use it.
        }
        return id
    }

    /// Ask the user for the next Sync time, then create a workspace in
    /// `.selfRunning` anchored to that time. If the user cancels the sheet
    /// no workspace is created.
    @MainActor
    static func createLater(debugSource: String) {
        presentScheduleNextSyncSheet(
            parentWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            onConfirm: { scheduled in
                guard let appDelegate = AppDelegate.shared else { return }
                guard let id = appDelegate.addWorkspaceInPreferredMainWindow(
                    debugSource: debugSource
                ) else { return }
                guard let workspace = appDelegate.findWorkspace(id: id) else { return }
                workspace.nextSyncPlannedDuration = scheduled.plannedDuration
                do {
                    try workspace.transition(
                        .convertToAsync(initialPhase: .selfRunning, nextSyncAt: scheduled.at),
                        reason: debugSource
                    )
                } catch {
                    // Leave the workspace in Normal mode.
                }
            },
            onCancel: {}
        )
    }

    /// Present `ScheduleNextSyncSheet` as an AppKit sheet on `parentWindow`
    /// when available, or as a standalone floating window otherwise.
    @MainActor
    static func presentScheduleNextSyncSheet(
        parentWindow: NSWindow?,
        initialDate: Date? = nil,
        initialPlannedDuration: TimeInterval? = nil,
        onConfirm: @escaping (ScheduledSync) -> Void,
        onCancel: @escaping () -> Void = {},
        onEndWithoutSchedule: (() -> Void)? = nil
    ) {
        let presenter = ScheduleNextSyncSheetPresenter(
            initialDate: initialDate,
            initialPlannedDuration: initialPlannedDuration,
            onConfirm: onConfirm,
            onCancel: onCancel,
            onEndWithoutSchedule: onEndWithoutSchedule
        )
        presenter.present(on: parentWindow)
    }
}

/// Lifecycle owner for a single presentation of `ScheduleNextSyncSheet`.
/// Retains itself for the duration of the sheet so SwiftUI's captured
/// closures keep working after the call site returns.
@MainActor
private final class ScheduleNextSyncSheetPresenter {
    private let initialDate: Date?
    private let initialPlannedDuration: TimeInterval?
    private let onConfirm: (ScheduledSync) -> Void
    private let onCancel: () -> Void
    private let onEndWithoutSchedule: (() -> Void)?
    private var sheetWindow: NSWindow?
    private weak var parentWindow: NSWindow?
    /// Self-retain for the duration of the sheet (AppKit only weakly holds
    /// the sheet owner here). Cleared on dismiss.
    private var retainedSelf: ScheduleNextSyncSheetPresenter?

    init(
        initialDate: Date?,
        initialPlannedDuration: TimeInterval?,
        onConfirm: @escaping (ScheduledSync) -> Void,
        onCancel: @escaping () -> Void,
        onEndWithoutSchedule: (() -> Void)?
    ) {
        self.initialDate = initialDate
        self.initialPlannedDuration = initialPlannedDuration
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onEndWithoutSchedule = onEndWithoutSchedule
    }

    func present(on parent: NSWindow?) {
        let root = ScheduleNextSyncSheet(
            initialDate: initialDate,
            initialPlannedDuration: initialPlannedDuration,
            onConfirm: { [weak self] scheduled in
                guard let self else { return }
                self.dismiss(confirmed: scheduled)
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.dismiss(confirmed: nil)
            },
            onEndWithoutSchedule: onEndWithoutSchedule.map { inner in
                { [weak self] in
                    inner()
                    self?.dismiss(confirmed: nil, skipOnCancel: true)
                }
            }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable]
        sheetWindow = window
        parentWindow = parent
        retainedSelf = self
        if let parent {
            parent.beginSheet(window) { [weak self] _ in
                guard let self else { return }
                // Ensure the retain is released even if we dismiss via the
                // window's close button rather than a button action.
                self.retainedSelf = nil
            }
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func dismiss(confirmed: ScheduledSync?, skipOnCancel: Bool = false) {
        if let confirmed {
            onConfirm(confirmed)
        } else if !skipOnCancel {
            onCancel()
        }
        guard let window = sheetWindow else {
            retainedSelf = nil
            return
        }
        if let parent = parentWindow {
            parent.endSheet(window)
        } else {
            window.orderOut(nil)
        }
        sheetWindow = nil
    }
}
