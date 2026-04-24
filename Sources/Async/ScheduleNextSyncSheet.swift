import SwiftUI

/// Result of `ScheduleNextSyncSheet`. Wrapped in a struct (rather than a bare
/// `Date`) so Phase 2 can extend with `calendarEventId` without breaking call
/// sites. See docs-rmux/spec.md §9 and plan.md §6.7.
struct ScheduledSync: Equatable {
    /// Absolute time the next Sync session is due. Always in the future
    /// (enforced by the picker UI).
    let at: Date
    /// Planned Sync duration (seconds) chosen at schedule-time. Used both
    /// for the calendar event's endDate and to pre-fill the Ready-to-sync
    /// overlay's duration picker. Defaults to 30 min.
    let plannedDuration: TimeInterval
    /// Google Calendar event identifier, set in Phase 2 when the integration
    /// is active. Always `nil` in Phase 1.
    let calendarEventId: String?

    init(
        at: Date,
        plannedDuration: TimeInterval = 30 * 60,
        calendarEventId: String? = nil
    ) {
        self.at = at
        self.plannedDuration = plannedDuration
        self.calendarEventId = calendarEventId
    }
}

/// Modal for picking the next Sync session's time and duration.
///
/// Layout (Phase 2):
///   - Duration picker (segmented): 15 / 30 / 45 / 1h / 1.5h / 2h / 3h
///   - Graphical `DatePicker` on the left (select the day)
///   - Vertical scroll of 30-min time slots on the right for the selected
///     day, showing busy blocks from `CalendarBridge` as disabled rows
///   - Summary line + Confirm / Cancel
///
/// Busy information is pulled from `CalendarBridge.busyIntervals(...)` —
/// all calendars merged. When Calendar access is denied the sheet still
/// works; all slots just show as free.
struct ScheduleNextSyncSheet: View {
    let initialDate: Date?
    let initialPlannedDuration: TimeInterval?
    let onConfirm: (ScheduledSync) -> Void
    let onCancel: () -> Void
    /// Optional "end without scheduling" path. When set (typically from
    /// the syncing pill's "Sync を終える" flow), the sheet shows an extra
    /// button that ends the current Sync and reverts to Normal instead of
    /// scheduling a next session. `nil` hides the button.
    let onEndWithoutSchedule: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var anchorDay: Date
    @State private var selectedSlot: Date?
    @State private var durationMinutes: Int

    /// Duration options (minutes).
    static let durationOptions: [Int] = [15, 30, 45, 60, 90, 120, 180]
    private static let defaultDurationMinutes = 30

    init(
        initialDate: Date? = nil,
        initialPlannedDuration: TimeInterval? = nil,
        onConfirm: @escaping (ScheduledSync) -> Void,
        onCancel: @escaping () -> Void,
        onEndWithoutSchedule: (() -> Void)? = nil
    ) {
        self.initialDate = initialDate
        self.initialPlannedDuration = initialPlannedDuration
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onEndWithoutSchedule = onEndWithoutSchedule
        let defaultSlot = Self.roundUpTo30Minutes(Date()).addingTimeInterval(3600)
        let candidate = initialDate.map { max($0, defaultSlot) } ?? defaultSlot
        // Anchor the 3-day window on the day that contains the initial
        // slot (or today, whichever is later).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let today = calendar.startOfDay(for: Date())
        let initialDay = calendar.startOfDay(for: candidate)
        _anchorDay = State(initialValue: max(initialDay, today))
        _selectedSlot = State(initialValue: initialDate == nil ? nil : candidate)
        let minutes = initialPlannedDuration
            .map { Int($0 / 60) }
            .flatMap { proposed in
                Self.durationOptions.min(by: { abs($0 - proposed) < abs($1 - proposed) })
            } ?? Self.defaultDurationMinutes
        _durationMinutes = State(initialValue: minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "async.schedule.sheet.title", defaultValue: "Next Sync time"))
                .font(.title2.weight(.semibold))

            durationPicker

            MultiDayCalendarView(
                duration: TimeInterval(durationMinutes * 60),
                selectedSlot: $selectedSlot,
                anchorDay: $anchorDay,
                daysShown: 3
            )

            summaryLine

            HStack {
                if let onEndWithoutSchedule {
                    Button(role: .destructive) {
                        onEndWithoutSchedule()
                        dismiss()
                    } label: {
                        Text(String(localized: "async.schedule.sheet.endWithoutSchedule",
                                    defaultValue: "End without scheduling"))
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button(String(localized: "async.common.cancel", defaultValue: "Cancel")) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "async.schedule.sheet.confirm", defaultValue: "Confirm")) {
                    guard let slot = selectedSlot else { return }
                    let scheduled = ScheduledSync(
                        at: slot,
                        plannedDuration: TimeInterval(durationMinutes * 60)
                    )
                    onConfirm(scheduled)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedSlot.map { $0 <= Date() } ?? true)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 640)
    }

    // MARK: - Duration

    @ViewBuilder
    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "async.schedule.sheet.duration",
                        defaultValue: "Meeting duration"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $durationMinutes) {
                ForEach(Self.durationOptions, id: \.self) { minutes in
                    Text(Self.formatDuration(minutes: minutes)).tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Summary line

    @ViewBuilder
    private var summaryLine: some View {
        if let slot = selectedSlot {
            Text(Self.formatSummary(
                at: slot,
                durationMinutes: durationMinutes
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Text(String(localized: "async.schedule.sheet.pickSlotHint",
                        defaultValue: "Pick an open time slot."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Busy overlap

    /// A window starting at `candidate` for `durationSeconds` is considered
    /// busy when it overlaps any busy interval. Boundary touches (candidate
    /// end == busy start, or busy end == candidate start) are allowed.
    static func intersectsBusy(
        _ candidate: Date,
        durationSeconds: TimeInterval = 30 * 60,
        busy: [DateInterval]
    ) -> Bool {
        let candidateEnd = candidate.addingTimeInterval(durationSeconds)
        return busy.contains { interval in
            interval.start < candidateEnd && candidate < interval.end
        }
    }

    // MARK: - Formatting

    static func formatSummary(at slot: Date, durationMinutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M/d (EEE) HH:mm"
        let timeStr = formatter.string(from: slot)
        let durationStr = formatDuration(minutes: durationMinutes)
        return String(
            localized: "async.schedule.sheet.summary",
            defaultValue: "Sync on \(timeStr), \(durationStr)"
        )
    }

    static func formatDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        let hours = Double(minutes) / 60.0
        return String(format: "%.1fh", hours)
    }

    // MARK: - Math

    /// Round a date forward to the next 30-minute boundary. Matches the
    /// candidate granularity specified in plan.md §6.7.
    static func roundUpTo30Minutes(_ date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let minute = calendar.component(.minute, from: date)
        let remainder = minute % 30
        let secondsToAdd = remainder == 0 ? 0 : (30 - remainder) * 60
        let second = calendar.component(.second, from: date)
        var result = date.addingTimeInterval(TimeInterval(secondsToAdd - second))
        if result <= date {
            result = result.addingTimeInterval(30 * 60)
        }
        return result
    }
}

