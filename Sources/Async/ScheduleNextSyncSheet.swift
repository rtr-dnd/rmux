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

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDay: Date
    @State private var selectedSlot: Date?
    @State private var durationMinutes: Int

    /// Slot grid spans 07:00 through 23:00 in 30-min increments.
    private static let slotHourStart = 7
    private static let slotHourEnd = 23
    private static let slotStepMinutes = 30

    /// Duration options (minutes).
    static let durationOptions: [Int] = [15, 30, 45, 60, 90, 120, 180]
    private static let defaultDurationMinutes = 30

    init(
        initialDate: Date? = nil,
        initialPlannedDuration: TimeInterval? = nil,
        onConfirm: @escaping (ScheduledSync) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialDate = initialDate
        self.initialPlannedDuration = initialPlannedDuration
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        let defaultSlot = Self.roundUpTo30Minutes(Date()).addingTimeInterval(3600)
        let candidate = initialDate.map { max($0, defaultSlot) } ?? defaultSlot
        _selectedDay = State(initialValue: Calendar(identifier: .gregorian).startOfDay(for: candidate))
        _selectedSlot = State(initialValue: candidate)
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

            HStack(alignment: .top, spacing: 20) {
                calendarColumn
                slotColumn
            }

            summaryLine

            HStack {
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
        .frame(minWidth: 640, minHeight: 520)
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

    // MARK: - Calendar column

    @ViewBuilder
    private var calendarColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "async.schedule.sheet.dateColumn",
                        defaultValue: "Date"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            DatePicker(
                "",
                selection: Binding(
                    get: { selectedDay },
                    set: { newValue in
                        let day = Calendar(identifier: .gregorian).startOfDay(for: newValue)
                        if day != selectedDay {
                            selectedDay = day
                            // Carry the chosen hour into the new day so the
                            // slot highlight stays on the same offset when
                            // possible.
                            if let slot = selectedSlot {
                                selectedSlot = Self.carryTimeOfDay(from: slot, to: day)
                            }
                        }
                    }
                ),
                in: Calendar(identifier: .gregorian).startOfDay(for: Date())...,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.graphical)
            .frame(width: 260)
        }
    }

    // MARK: - Slot column

    @ViewBuilder
    private var slotColumn: some View {
        let busy = CalendarBridge.shared.busyIntervals(
            from: selectedDay,
            to: Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: 1,
                to: selectedDay
            ) ?? selectedDay.addingTimeInterval(24 * 3600)
        )
        let slots = Self.slots(for: selectedDay)
        let duration = TimeInterval(durationMinutes * 60)
        let now = Date()

        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "async.schedule.sheet.slotColumn",
                        defaultValue: "Time"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(slots, id: \.self) { slot in
                        let isBusy = Self.intersectsBusy(
                            slot,
                            durationSeconds: duration,
                            busy: busy
                        )
                        let isPast = slot <= now
                        let disabled = isBusy || isPast
                        SlotRow(
                            slot: slot,
                            isSelected: selectedSlot == slot,
                            isBusy: isBusy,
                            isDisabled: disabled
                        ) {
                            selectedSlot = slot
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 360)
        }
        .frame(minWidth: 240)
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

    // MARK: - Slot helpers

    /// All 30-min slot start times for the given day, from 07:00 to 23:00.
    static func slots(for day: Date) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let dayStart = calendar.startOfDay(for: day)
        var results: [Date] = []
        var hour = slotHourStart
        var minute = 0
        while hour <= slotHourEnd {
            if let slot = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: dayStart
            ) {
                results.append(slot)
            }
            minute += slotStepMinutes
            if minute >= 60 {
                minute = 0
                hour += 1
            }
        }
        return results
    }

    /// Shift a reference date's time-of-day onto a new day.
    static func carryTimeOfDay(from source: Date, to day: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let hour = calendar.component(.hour, from: source)
        let minute = calendar.component(.minute, from: source)
        return calendar.date(
            bySettingHour: hour, minute: minute, second: 0,
            of: calendar.startOfDay(for: day)
        ) ?? day
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

/// Row shown for each 30-min slot in the time column.
private struct SlotRow: View {
    let slot: Date
    let isSelected: Bool
    let isBusy: Bool
    let isDisabled: Bool
    let onSelect: () -> Void

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(Self.formatter.string(from: slot))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                Spacer()
                if isBusy {
                    Text(String(localized: "async.schedule.preset.busyBadge",
                                defaultValue: "Busy"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
