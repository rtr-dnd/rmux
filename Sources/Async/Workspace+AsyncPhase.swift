import Combine
import Foundation

// rmux Async workspace state mutations and derived helpers.
//
// All Async phase writes flow through `Workspace.transition(_:reason:)` so that
// invariant validation and downstream effects (AgentStateEmitter — Phase 1
// Step 6) are centralised in one place.
// See docs-rmux/spec.md §3 and docs-rmux/plan.md §2.2 for the state machine.

extension Workspace {
    /// Apply an Async phase transition with invariant validation.
    /// Callers should not mutate `mode` / `asyncPhase` / `nextSyncAt` /
    /// `syncStartedAt` / `plannedDuration` / `lastSyncEndedAt` directly.
    ///
    /// - Parameters:
    ///   - transition: The transition intent. Associated values carry any
    ///     data required by the target phase (e.g., `plannedDuration`).
    ///   - reason: Free-form label for telemetry / future logging. Unused today.
    /// - Throws: `AsyncPhaseTransitionError` if the transition would violate the
    ///   state-machine invariants documented in `docs-rmux/plan.md` §2.2.
    func transition(_ transition: AsyncPhaseTransition, reason: String = "") throws {
        switch transition {
        case .convertToAsync(let initialPhase, let nextSyncAt):
            guard mode == .normal else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            switch initialPhase {
            case .preparing:
                mode = .async
                asyncPhase = .preparing
                self.nextSyncAt = nextSyncAt
                syncStartedAt = nil
                plannedDuration = nil
            case .selfRunning:
                guard let nextSyncAt else {
                    throw AsyncPhaseTransitionError.missingNextSyncAt
                }
                mode = .async
                asyncPhase = .selfRunning
                self.nextSyncAt = nextSyncAt
                syncStartedAt = nil
                plannedDuration = nil
                syncCalendarEvent(scheduledAt: nextSyncAt)
            case .syncing, .awaitingAttendance:
                throw AsyncPhaseTransitionError.unsupportedInitialPhase(initialPhase)
            }

        case .revertToNormal:
            guard mode == .async else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            mode = .normal
            asyncPhase = nil
            nextSyncAt = nil
            syncStartedAt = nil
            plannedDuration = nil
            // lastSyncEndedAt is preserved as a historical record.
            discardCalendarEvent()

        case .enterSyncing(let plannedDuration, let at):
            guard mode == .async, asyncPhase == .preparing else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            guard plannedDuration > 0 else {
                throw AsyncPhaseTransitionError.invalidPlannedDuration(plannedDuration)
            }
            asyncPhase = .syncing
            nextSyncAt = nil
            syncStartedAt = at
            self.plannedDuration = plannedDuration

        case .endSyncing(let nextSyncAt, let at):
            guard mode == .async, asyncPhase == .syncing else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            guard nextSyncAt > at else {
                throw AsyncPhaseTransitionError.nextSyncAtInPast(nextSyncAt)
            }
            asyncPhase = .selfRunning
            self.nextSyncAt = nextSyncAt
            syncStartedAt = nil
            plannedDuration = nil
            lastSyncEndedAt = at
            syncCalendarEvent(scheduledAt: nextSyncAt)

        case .endSyncingAndRevert(let at):
            guard mode == .async, asyncPhase == .syncing else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            mode = .normal
            asyncPhase = nil
            nextSyncAt = nil
            syncStartedAt = nil
            plannedDuration = nil
            lastSyncEndedAt = at
            discardCalendarEvent()

        case .scheduledSyncArrived:
            guard mode == .async, asyncPhase == .selfRunning else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            asyncPhase = .preparing
            // nextSyncAt is preserved (just passed) so the scheduler can
            // arm its escalation timer off nextSyncAt + graceInterval.

        case .markAwaitingAttendance:
            guard mode == .async,
                  asyncPhase == .selfRunning || asyncPhase == .preparing else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            asyncPhase = .awaitingAttendance

        case .interruptToPreparing:
            guard mode == .async, asyncPhase == .selfRunning else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            asyncPhase = .preparing
            // nextSyncAt is preserved so that cancel can infer the previous phase.
            // Calendar event is now misaligned (user jumped in before the
            // scheduled time) — delete so it doesn't linger in the user's
            // calendar as a stale future item. If the user bails and goes
            // back to self-running via cancelPreparing, the next endSyncing
            // will write a fresh one.
            discardCalendarEvent()

        case .startOverdueSession:
            guard mode == .async, asyncPhase == .awaitingAttendance else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            asyncPhase = .preparing
            // nextSyncAt is preserved (in the past) for cancel inference.

        case .reschedule(let newNextSyncAt):
            // Accepts selfRunning (user tweaks future time) and awaitingAttendance
            // (user re-schedules an overdue slot). Either way the result is a
            // selfRunning phase anchored to the new future time.
            guard mode == .async,
                  asyncPhase == .awaitingAttendance || asyncPhase == .selfRunning else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            guard newNextSyncAt > Date() else {
                throw AsyncPhaseTransitionError.nextSyncAtInPast(newNextSyncAt)
            }
            asyncPhase = .selfRunning
            nextSyncAt = newNextSyncAt
            syncCalendarEvent(scheduledAt: newNextSyncAt)

        case .cancelPreparing:
            guard mode == .async, asyncPhase == .preparing else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            if let pending = nextSyncAt {
                // Returning to whichever phase we came from.
                asyncPhase = pending > Date() ? .selfRunning : .awaitingAttendance
            } else {
                // First-time conversion; no prior schedule to return to.
                mode = .normal
                asyncPhase = nil
                nextSyncAt = nil
                syncStartedAt = nil
                plannedDuration = nil
            }
        }

        // Notify the agent-facing contracts. Hook installation runs only
        // while the workspace is Async (idempotent, so every transition can
        // call it without harm). No in-tree documentation is planted —
        // operational guidance flows through the per-turn hook output only.
        if mode == .async {
            AgentStateEmitter.ensureClaudeCodeHook(for: self)
            installCwdTracking()
        } else {
            asyncCwdRetryCancellable = nil
        }
        AgentStateEmitter.writeState(for: self)
        _ = reason  // kept for future telemetry / logging
    }

    /// Create or move the calendar event mirroring this workspace's next
    /// Sync. On create success the workspace's `calendarEventId` is updated.
    /// Silent when Calendar access is denied (returns early, leaves the
    /// workspace otherwise functional — calendar sync is best-effort).
    /// See docs-rmux/spec.md §9.
    @MainActor
    private func syncCalendarEvent(scheduledAt: Date) {
        let title = calendarEventTitle()
        // Fire the TCC prompt on first use. Fire-and-forget: if the user
        // is granting now, they can reschedule after and we'll succeed.
        // If they deny, we stay in "no calendar" mode silently.
        if !CalendarBridge.shared.hasFullAccess {
            Task { @MainActor in
                await CalendarBridge.shared.requestAccessIfNeeded()
            }
        }
        if let existingId = calendarEventId,
           let updatedId = CalendarBridge.shared.updateEvent(
               id: existingId,
               for: id,
               title: title,
               at: scheduledAt
           ) {
            calendarEventId = updatedId
            return
        }
        // Either no existing id, or update failed (event was deleted in
        // Calendar.app). Create a fresh one.
        if let newId = CalendarBridge.shared.createEvent(
            for: id,
            title: title,
            at: scheduledAt
        ) {
            calendarEventId = newId
        } else {
            // Calendar access denied or save failed — leave id nil so we
            // retry on the next transition. No error surfaced to the user.
            calendarEventId = nil
        }
    }

    /// Delete any existing calendar event and clear `calendarEventId`.
    /// Called on Async → Normal conversions, "Sync を終える → Normal" path,
    /// workspace close, and user-initiated interrupt-to-preparing.
    @MainActor
    private func discardCalendarEvent() {
        if let id = calendarEventId {
            CalendarBridge.shared.deleteEvent(id: id)
        }
        calendarEventId = nil
    }

    /// Title for the calendar event. "rmux Sync: <workspace title>" — the
    /// "rmux Sync:" prefix lets users identify rmux-managed events at a
    /// glance in Calendar.app.
    private func calendarEventTitle() -> String {
        let fallback = "rmux Sync"
        let label = customTitle ?? title
        if label.isEmpty { return fallback }
        return "\(fallback): \(label)"
    }

    /// Install a cwd subscription that re-runs `ensureClaudeCodeHook` +
    /// `writeState` on every cwd change. The subscription stays alive for
    /// the workspace's entire `.async` lifetime (cancelled on
    /// `revertToNormal`). This handles three overlapping scenarios:
    ///   1. workspace inherits cwd=$HOME at transition time, real cwd
    ///      arrives later via OSC 7 (terminal shell integration)
    ///   2. workspace inherits cwd=project-A, then user `cd project-B` in
    ///      the terminal — hook follows
    ///   3. user `cd` mid-session in Normal workspace before Async
    ///      conversion (not relevant here but symmetric)
    /// Writes to `.claude/settings.local.json` are gitignored and idempotent,
    /// so multiple installs across different cwds are additive without
    /// clobbering each other's state.
    @MainActor
    private func installCwdTracking() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        asyncCwdRetryCancellable = $currentDirectory
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == home { return }
                Task { @MainActor [weak self] in
                    guard let self, self.mode == .async else { return }
                    AgentStateEmitter.ensureClaudeCodeHook(for: self)
                    AgentStateEmitter.writeState(for: self)
                }
            }
    }

    // MARK: Derived helpers (for UI / observers)

    /// Seconds until `nextSyncAt`. Positive when future, negative when past.
    /// `nil` when `nextSyncAt` is not set (i.e. normal, fresh-converted preparing, or syncing).
    var remainingUntilSync: TimeInterval? {
        nextSyncAt?.timeIntervalSinceNow
    }

    /// Seconds the workspace has been overdue. Positive while in awaitingAttendance.
    /// `nil` outside of awaitingAttendance or when `nextSyncAt` is not set.
    var overdueDuration: TimeInterval? {
        guard asyncPhase == .awaitingAttendance, let at = nextSyncAt else { return nil }
        return -at.timeIntervalSinceNow
    }

    /// Wall-clock seconds since `syncStartedAt`. `nil` when not syncing.
    var elapsedSinceSyncStart: TimeInterval? {
        guard asyncPhase == .syncing, let start = syncStartedAt else { return nil }
        return -start.timeIntervalSinceNow
    }

    /// Seconds past `plannedDuration`. Positive when over. `nil` when not syncing.
    var syncOverrun: TimeInterval? {
        guard let elapsed = elapsedSinceSyncStart, let planned = plannedDuration else { return nil }
        return elapsed - planned
    }
}
