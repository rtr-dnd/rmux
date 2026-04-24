import AppKit
import Bonsplit
import Combine
import Foundation
import UserNotifications

/// Fires Async workspace phase transitions when their scheduled Sync time
/// arrives. Two kinds of pending fires per workspace:
///   - **arrival** (`.selfRunning` → `.preparing`) at `nextSyncAt` — so the
///     human lands on the Ready-to-sync screen instead of the "Overdue" one
///     when they are right there at the scheduled time
///   - **escalation** (`.preparing` → `.awaitingAttendance`) at
///     `nextSyncAt + overdueGraceInterval` — only fires if the user didn't
///     start the Sync within the grace window
///
/// At any moment the scheduler arms a single `DispatchSourceTimer` for the
/// nearest of all pending fires across all registered workspaces. On fire it
/// applies the matching transition and posts a macOS notification for
/// arrivals (escalations stay silent since the user was already notified on
/// arrival).
///
/// Registration is per `TabManager` (one per window). The scheduler observes
/// each registered `TabManager.$tabs` and each live `Workspace.objectWillChange`,
/// re-scanning on any change.
///
/// Collision checking across multiple Async workspaces is intentionally out
/// of scope for Phase 1; this scheduler just fires the earliest timer
/// (docs-rmux/plan.md §1.2, §11 Phase 5).
@MainActor
final class SyncSessionScheduler {
    static let shared = SyncSessionScheduler()

    /// Grace window after `nextSyncAt` during which `.preparing` is shown
    /// (rather than `.awaitingAttendance`) so the user has a calm "start
    /// when ready" affordance. See spec.md §3.1 / §4.4.
    static let overdueGraceInterval: TimeInterval = 10 * 60

    private enum PendingFireKind {
        /// `.selfRunning` → `.preparing` at the workspace's `nextSyncAt`.
        case arrival
        /// `.preparing` → `.awaitingAttendance` at
        /// `nextSyncAt + overdueGraceInterval`.
        case escalation
    }

    private struct PendingFire {
        let workspaceID: UUID
        let at: Date
        let kind: PendingFireKind
    }

    private var registeredTabManagers: [Weak<TabManager>] = []
    private var tabManagerCancellables: [AnyCancellable] = []
    private var workspaceCancellables: [AnyCancellable] = []

    private var timer: DispatchSourceTimer?
    private var armedFire: PendingFire?

    private init() {}

    /// Register a `TabManager` so its workspaces are considered by the
    /// scheduler. Idempotent per instance.
    func register(_ tabManager: TabManager) {
        compactRegistrations()
        if registeredTabManagers.contains(where: { $0.value === tabManager }) {
            #if DEBUG
            dlog("rmux.scheduler.register skip=alreadyRegistered tabs=\(tabManager.tabs.count)")
            #endif
            return
        }
        registeredTabManagers.append(Weak(tabManager))
        let cancellable = tabManager.$tabs.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.rescan() }
        }
        tabManagerCancellables.append(cancellable)
        #if DEBUG
        dlog("rmux.scheduler.register tabs=\(tabManager.tabs.count) totalRegistered=\(registeredTabManagers.count)")
        #endif
        rescan()
    }

    /// Re-evaluate all registered workspaces and (re)arm the timer for the
    /// nearest pending fire. Called on any change that could affect it.
    func rescan() {
        compactRegistrations()
        let allWorkspaces = registeredTabManagers
            .compactMap(\.value)
            .flatMap(\.tabs)

        // Resubscribe to every live workspace so any phase / nextSyncAt update
        // triggers another rescan. Reset the subscription list each rescan to
        // keep the bookkeeping simple.
        workspaceCancellables = allWorkspaces.map { workspace in
            workspace.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.rescan() }
            }
        }

        let pending = pendingFires(for: allWorkspaces)

        #if DEBUG
        dlog("rmux.scheduler.rescan workspaces=\(allWorkspaces.count) pending=\(pending.count)")
        #endif

        guard let next = pending.min(by: { $0.at < $1.at }) else {
            cancelTimer()
            return
        }

        arm(fire: next)
    }

    private func pendingFires(for workspaces: [Workspace]) -> [PendingFire] {
        workspaces.compactMap { ws -> PendingFire? in
            guard ws.mode == .async, let nextAt = ws.nextSyncAt else { return nil }
            switch ws.asyncPhase {
            case .selfRunning:
                return PendingFire(workspaceID: ws.id, at: nextAt, kind: .arrival)
            case .preparing:
                // Only scheduler-arrived preparing (nextSyncAt in past-ish)
                // has an escalation. User-initiated preparing via
                // `.interruptToPreparing` keeps nextSyncAt in the future, so
                // escalation would be `nextAt + grace` — still future, never
                // ripe before the workspace leaves preparing.
                return PendingFire(
                    workspaceID: ws.id,
                    at: nextAt.addingTimeInterval(Self.overdueGraceInterval),
                    kind: .escalation
                )
            default:
                return nil
            }
        }
    }

    // MARK: - Timer

    private func arm(fire: PendingFire) {
        // Already armed for this exact target → skip re-creating the timer.
        if let armed = armedFire,
           armed.workspaceID == fire.workspaceID,
           armed.at == fire.at,
           armed.kind == fire.kind {
            #if DEBUG
            dlog("rmux.scheduler.arm skip=alreadyArmed workspace=\(fire.workspaceID.uuidString.prefix(8)) at=\(fire.at) kind=\(fire.kind)")
            #endif
            return
        }
        cancelTimer()

        let delay = max(0, fire.at.timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(Int(delay * 1000)))
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.fire(fire)
            }
        }
        source.resume()

        timer = source
        armedFire = fire
        #if DEBUG
        dlog("rmux.scheduler.arm workspace=\(fire.workspaceID.uuidString.prefix(8)) at=\(fire.at) delay=\(delay)s kind=\(fire.kind)")
        #endif
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        armedFire = nil
    }

    private func fire(_ fire: PendingFire) {
        #if DEBUG
        dlog("rmux.scheduler.fire workspace=\(fire.workspaceID.uuidString.prefix(8)) kind=\(fire.kind)")
        #endif
        // Re-resolve the workspace (it could have been released or its phase
        // moved on since the timer armed).
        compactRegistrations()
        let candidate = registeredTabManagers
            .compactMap(\.value)
            .flatMap(\.tabs)
            .first(where: { $0.id == fire.workspaceID })
        guard let workspace = candidate else {
            #if DEBUG
            dlog("rmux.scheduler.fire skip=workspaceGone")
            #endif
            rescan()
            return
        }
        guard workspace.mode == .async else {
            rescan()
            return
        }
        do {
            switch fire.kind {
            case .arrival:
                guard workspace.asyncPhase == .selfRunning else {
                    rescan()
                    return
                }
                try workspace.transition(.scheduledSyncArrived(at: Date()))
                postNotification(for: workspace)
            case .escalation:
                guard workspace.asyncPhase == .preparing else {
                    rescan()
                    return
                }
                try workspace.transition(.markAwaitingAttendance)
                // Escalation is silent: we already posted a notification on
                // arrival. A second one after 10 minutes would be noise.
            }
            #if DEBUG
            dlog("rmux.scheduler.fire success kind=\(fire.kind) transition posted")
            #endif
        } catch {
            #if DEBUG
            dlog("rmux.scheduler.fire failed kind=\(fire.kind) error=\(error)")
            #endif
        }
        rescan()
    }

    // MARK: - Notification

    private func postNotification(for workspace: Workspace) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "async.notification.title", defaultValue: "Sync time")
        content.body = workspace.title.isEmpty
            ? String(localized: "async.notification.fallbackBody", defaultValue: "Async workspace")
            : workspace.title
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "rmux.sync.\(workspace.id.uuidString).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: { error in
            if let error {
                NSLog("[rmux scheduler] notification add failed: \(error)")
            }
        })
    }

    // MARK: - Bookkeeping

    private func compactRegistrations() {
        registeredTabManagers.removeAll { $0.value == nil }
    }

    private struct Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
}
