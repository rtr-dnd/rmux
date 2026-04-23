import AppKit
import Bonsplit
import Combine
import Foundation
import UserNotifications

/// Fires Async workspace phase transitions when their scheduled Sync time
/// arrives. At any moment the scheduler keeps a single `DispatchSourceTimer`
/// armed for the nearest `selfRunning` workspace's `nextSyncAt`; on fire it
/// transitions the workspace to `awaitingAttendance` and posts a macOS
/// notification.
///
/// Registration is per `TabManager` (one per window). The scheduler observes
/// each registered `TabManager.$tabs` and each live `Workspace.objectWillChange`,
/// re-scanning the minimum future `nextSyncAt` on any change.
///
/// Collision checking across multiple Async workspaces is intentionally out
/// of scope for Phase 1; this scheduler just fires the earliest timer
/// (docs-rmux/plan.md §1.2, §11 Phase 5).
@MainActor
final class SyncSessionScheduler {
    static let shared = SyncSessionScheduler()

    private var registeredTabManagers: [Weak<TabManager>] = []
    private var tabManagerCancellables: [AnyCancellable] = []
    private var workspaceCancellables: [AnyCancellable] = []

    private var timer: DispatchSourceTimer?
    private var armedWorkspaceID: UUID?
    private var armedFireDate: Date?

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
    /// nearest future `nextSyncAt`. Called on any change that could affect it.
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

        let now = Date()
        let pendingTargets: [(Workspace, Date)] = allWorkspaces.compactMap { ws in
            guard ws.mode == .async,
                  ws.asyncPhase == .selfRunning,
                  let nextAt = ws.nextSyncAt,
                  nextAt > now else { return nil }
            return (ws, nextAt)
        }

        #if DEBUG
        dlog("rmux.scheduler.rescan workspaces=\(allWorkspaces.count) pending=\(pendingTargets.count)")
        #endif

        guard let (nextWorkspace, nextAt) = pendingTargets.min(by: { $0.1 < $1.1 }) else {
            cancelTimer()
            return
        }

        arm(workspace: nextWorkspace, at: nextAt)
    }

    // MARK: - Timer

    private func arm(workspace: Workspace, at date: Date) {
        // Already armed for this exact target → skip re-creating the timer.
        if armedWorkspaceID == workspace.id, armedFireDate == date {
            #if DEBUG
            dlog("rmux.scheduler.arm skip=alreadyArmed workspace=\(workspace.id.uuidString.prefix(8)) at=\(date)")
            #endif
            return
        }
        cancelTimer()

        let delay = max(0, date.timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(Int(delay * 1000)))
        let workspaceID = workspace.id
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.fire(for: workspaceID)
            }
        }
        source.resume()

        timer = source
        armedWorkspaceID = workspaceID
        armedFireDate = date
        #if DEBUG
        dlog("rmux.scheduler.arm workspace=\(workspace.id.uuidString.prefix(8)) at=\(date) delay=\(delay)s")
        #endif
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        armedWorkspaceID = nil
        armedFireDate = nil
    }

    private func fire(for workspaceID: UUID) {
        #if DEBUG
        dlog("rmux.scheduler.fire workspace=\(workspaceID.uuidString.prefix(8))")
        #endif
        // Re-resolve the workspace (it could have been released or its phase
        // moved on since the timer armed).
        compactRegistrations()
        let candidate = registeredTabManagers
            .compactMap(\.value)
            .flatMap(\.tabs)
            .first(where: { $0.id == workspaceID })
        guard let workspace = candidate else {
            #if DEBUG
            dlog("rmux.scheduler.fire skip=workspaceGone")
            #endif
            rescan()
            return
        }
        guard workspace.mode == .async, workspace.asyncPhase == .selfRunning else {
            #if DEBUG
            dlog("rmux.scheduler.fire skip=phaseMoved mode=\(workspace.mode.rawValue) phase=\(workspace.asyncPhase?.rawValue ?? "nil")")
            #endif
            rescan()
            return
        }
        do {
            try workspace.transition(.markAwaitingAttendance)
            postNotification(for: workspace)
            #if DEBUG
            dlog("rmux.scheduler.fire success transition+notification posted")
            #endif
        } catch {
            #if DEBUG
            dlog("rmux.scheduler.fire failed transition error=\(error)")
            #endif
        }
        rescan()
    }

    // MARK: - Notification

    private func postNotification(for workspace: Workspace) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Sync の時間です"
        content.body = workspace.title.isEmpty ? "Async workspace" : workspace.title
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
