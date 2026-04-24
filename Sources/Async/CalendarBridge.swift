import EventKit
import Foundation

/// EventKit bridge for the rmux Async workspace ↔ Google Calendar
/// integration. rmux does **not** talk to Google's API directly; it reads
/// and writes through macOS's system Calendar (Calendar.app + EventKit),
/// which takes care of syncing back to Google via the user's account added
/// under System Settings → Internet Accounts. See docs-rmux/spec.md §9.
///
/// Every Sync session that leaves `syncing` for `selfRunning` is mirrored as
/// a `EKEvent` in the user's default (primary) calendar. The event's
/// `eventIdentifier` is persisted on the Workspace so future reschedules /
/// cancellations resolve it directly.
///
/// Access to EventKit is gated by a TCC permission prompt the first time
/// we call `requestFullAccessToEvents(...)`. Before permission is granted,
/// all mutating APIs are no-ops (return nil) and `busyIntervals(...)`
/// returns empty — rmux degrades gracefully to "calendar-agnostic" mode.
///
/// Identity marker: the event's `notes` field carries a machine-readable
/// line `rmux://workspace/<workspaceId>` so an external viewer (or a
/// future rmux version) can round-trip the link even if the eventIdentifier
/// is lost.
@MainActor
final class CalendarBridge {
    static let shared = CalendarBridge()

    /// The single event store instance for the app's lifetime. Creating
    /// multiple `EKEventStore` objects is wasteful and confuses the change
    /// notifier; share one.
    private let eventStore = EKEventStore()

    /// The workspace-id marker rmux writes into every event's `notes` field.
    /// Format: `rmux://workspace/<uuid>` on its own line.
    static let notesMarkerPrefix = "rmux://workspace/"

    private init() {}

    // MARK: - Access

    /// Current authorization for Calendar access.
    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Returns `true` once the user has granted full-access to events.
    /// `fullAccess` is the only level that lets us create/edit events
    /// (the older `authorized` constant maps to it on macOS 14+).
    var hasFullAccess: Bool {
        if #available(macOS 14.0, *) {
            return authorizationStatus == .fullAccess
        }
        return authorizationStatus == .authorized
    }

    /// Prompt for Calendar access if we haven't asked yet. Safe to call
    /// multiple times; after the first outcome macOS remembers the choice.
    /// Returns `true` if access is granted.
    @discardableResult
    func requestAccessIfNeeded() async -> Bool {
        if hasFullAccess { return true }
        do {
            if #available(macOS 14.0, *) {
                return try await eventStore.requestFullAccessToEvents()
            } else {
                return try await withCheckedThrowingContinuation { continuation in
                    eventStore.requestAccess(to: .event) { granted, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: granted)
                        }
                    }
                }
            }
        } catch {
            return false
        }
    }

    // MARK: - Event CRUD

    /// Create (or re-create) an event for this workspace's next Sync at
    /// `at`. Returns the event's identifier on success, `nil` if access is
    /// denied or EventKit rejects the save. Duration defaults to 30 minutes
    /// when the caller has no signal yet (most scheduled Syncs start from
    /// self-running, where `plannedDuration` is cleared).
    @discardableResult
    func createEvent(
        for workspaceId: UUID,
        title: String,
        at startDate: Date,
        duration: TimeInterval = 30 * 60
    ) -> String? {
        guard hasFullAccess else { return nil }
        guard let calendar = eventStore.defaultCalendarForNewEvents else { return nil }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(duration)
        event.notes = Self.notesMarkerLine(for: workspaceId)

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    /// Move an existing event to `at`. Also refreshes title/duration so
    /// rescheduling during rename lines up. Returns the effective event id
    /// (may differ from input if EventKit re-assigns; typically the same).
    /// `nil` when the event can no longer be found (user deleted it in
    /// Calendar.app) or access is denied — the caller should create a new
    /// event in that case.
    @discardableResult
    func updateEvent(
        id: String,
        for workspaceId: UUID,
        title: String,
        at startDate: Date,
        duration: TimeInterval = 30 * 60
    ) -> String? {
        guard hasFullAccess else { return nil }
        guard let event = eventStore.event(withIdentifier: id) else { return nil }

        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(duration)
        // Refresh the marker so long-lived events stay tagged even if
        // the user edited the notes in Calendar.app.
        event.notes = Self.mergeNotesMarker(into: event.notes, workspaceId: workspaceId)

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }

    /// Delete the event. Silent no-op when the event is already gone or
    /// access is denied.
    func deleteEvent(id: String) {
        guard hasFullAccess else { return }
        guard let event = eventStore.event(withIdentifier: id) else { return }
        try? eventStore.remove(event, span: .thisEvent, commit: true)
    }

    // MARK: - Free/busy

    /// Busy intervals from all calendars between `start` and `end`, merged
    /// and sorted. Used by `ScheduleNextSyncSheet` to disable quick-pick
    /// candidates that collide with existing meetings. Returns an empty
    /// array when access hasn't been granted.
    func busyIntervals(from start: Date, to end: Date) -> [DateInterval] {
        guard hasFullAccess else { return [] }
        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
        let intervals: [DateInterval] = events
            .filter { !$0.isAllDay || $0.availability == .busy }
            .filter { $0.availability != .free }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
        return mergeOverlapping(intervals)
    }

    // MARK: - Helpers

    static func notesMarkerLine(for workspaceId: UUID) -> String {
        "\(notesMarkerPrefix)\(workspaceId.uuidString)"
    }

    /// Merge the rmux marker line into `existing` notes without duplicating.
    /// If a marker for this workspace is already present, returns `existing`
    /// unchanged. If a marker for a *different* workspace is present, the
    /// new marker is appended (rare: event got re-assigned to another
    /// workspace — shouldn't happen in normal flow but don't stomp).
    static func mergeNotesMarker(into existing: String?, workspaceId: UUID) -> String {
        let marker = notesMarkerLine(for: workspaceId)
        let current = existing ?? ""
        if current.contains(marker) { return current }
        if current.isEmpty { return marker }
        return current + "\n" + marker
    }

    private func mergeOverlapping(_ sorted: [DateInterval]) -> [DateInterval] {
        guard let first = sorted.first else { return [] }
        var merged: [DateInterval] = [first]
        for interval in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.start <= last.end {
                let newEnd = max(last.end, interval.end)
                merged[merged.count - 1] = DateInterval(start: last.start, end: newEnd)
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
