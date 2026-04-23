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

        case .markAwaitingAttendance:
            guard mode == .async, asyncPhase == .selfRunning else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            asyncPhase = .awaitingAttendance

        case .interruptToPreparing:
            guard mode == .async, asyncPhase == .selfRunning else {
                throw AsyncPhaseTransitionError.invalidSource(mode: mode, phase: asyncPhase)
            }
            asyncPhase = .preparing
            // nextSyncAt is preserved so that cancel can infer the previous phase.

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

        // TODO(rmux Phase 1 Step 6): notify AgentStateEmitter to rewrite .cmux/state.json
        // and deliver the transition to connected agents via env/state/hook.
        _ = reason  // kept for future telemetry / logging
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
