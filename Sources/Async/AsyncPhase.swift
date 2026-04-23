import Foundation

// Core value types for the rmux Async workspace feature.
// See docs-rmux/spec.md §2 for concepts, §3 for lifecycle.
// State mutations live in Sources/Async/Workspace+AsyncPhase.swift and
// must flow through `Workspace.transition(_:reason:)`.

/// Workspace operational mode.
enum WorkspaceMode: String, Codable {
    case normal
    case async
}

/// Phase of an Async workspace.
enum AsyncPhase: String, Codable {
    case preparing          // Ready to sync — planned duration being set
    case syncing            // In sync — human is talking to the agent
    case selfRunning        // Agent runs autonomously until nextSyncAt
    case awaitingAttendance // nextSyncAt has passed; human hasn't started the sync
}

/// Explicit transition intents. The parameters embedded in each case carry the
/// associated data required for the transition. See docs-rmux/spec.md §3.1.
enum AsyncPhaseTransition {
    /// Convert Normal → Async. `initialPhase` is `.preparing` for "今すぐ" or
    /// `.selfRunning` for "後で (時刻選択)".
    case convertToAsync(initialPhase: AsyncPhase, nextSyncAt: Date?)
    /// Convert Async → Normal. Clears all async state (preserves `lastSyncEndedAt`).
    case revertToNormal
    /// Preparing → Syncing. Starts a sync session with the given planned duration.
    case enterSyncing(plannedDuration: TimeInterval, at: Date)
    /// Syncing → Self-running. Ends current sync and schedules the next.
    case endSyncing(nextSyncAt: Date, at: Date)
    /// Self-running → Awaiting-attendance. Fired automatically at `nextSyncAt`.
    case markAwaitingAttendance
    /// Self-running → Preparing. User-initiated interrupt ("今すぐ Sync").
    case interruptToPreparing
    /// Awaiting-attendance → Preparing. User starts the overdue sync ("今すぐ開始").
    case startOverdueSession
    /// Reschedule the next Sync to a new future date. Valid in both
    /// `selfRunning` (user presses "スケジュール変更") and `awaitingAttendance`
    /// (user presses "リスケ"); the resulting phase is always `selfRunning`.
    case reschedule(nextSyncAt: Date)
    /// Preparing → previous phase. Target is inferred from `nextSyncAt`:
    /// nil → revert to Normal; future → selfRunning; past → awaitingAttendance.
    case cancelPreparing
}

/// Errors thrown when an invalid `AsyncPhaseTransition` is attempted.
enum AsyncPhaseTransitionError: Error, Equatable {
    /// The current (mode, phase) does not permit this transition.
    case invalidSource(mode: WorkspaceMode, phase: AsyncPhase?)
    /// `plannedDuration` must be > 0.
    case invalidPlannedDuration(TimeInterval)
    /// `nextSyncAt` supplied to `endSyncing` or `reschedule` must be in the future
    /// (relative to the `at` anchor for `endSyncing`, or `Date()` for `reschedule`).
    case nextSyncAtInPast(Date)
    /// `convertToAsync(initialPhase: .selfRunning, ...)` requires a non-nil `nextSyncAt`.
    case missingNextSyncAt
    /// `convertToAsync` is only valid with `.preparing` or `.selfRunning` as the initial phase.
    case unsupportedInitialPhase(AsyncPhase)
}
