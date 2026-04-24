import SwiftUI

/// Result of `ScheduleNextSyncSheet`. Wrapped in a struct (rather than a bare
/// `Date`) so Phase 2 can extend with `calendarEventId` without breaking call
/// sites. See docs-rmux/spec.md §9 and plan.md §6.7.
struct ScheduledSync: Equatable {
    /// Absolute time the next Sync session is due. Always in the future
    /// (enforced by the picker UI).
    let at: Date
    /// Google Calendar event identifier, set in Phase 2 when the integration
    /// is active. Always `nil` in Phase 1.
    let calendarEventId: String?

    init(at: Date, calendarEventId: String? = nil) {
        self.at = at
        self.calendarEventId = calendarEventId
    }
}

/// Modal for picking the next Sync session time. Shown from
/// `SelfRunningOverlay` ("スケジュール変更") and `OverdueOverlay` ("リスケ")
/// — see plan.md §6.7. Copy is not localised yet (Phase 1 Step 14).
///
/// Behaviour:
/// - Shows quick-pick presets (1h / 3h / 6h from now, and round "tidy"
///   times within the next ~7 days).
/// - Shows a manual `DatePicker` with minutes snapped to 30-min intervals.
/// - Times in the past are filtered out from both sources.
/// - Collision checking across multiple Async workspaces is intentionally
///   out of scope for Phase 1 (Phase 5, §11).
struct ScheduleNextSyncSheet: View {
    let initialDate: Date?
    let onConfirm: (ScheduledSync) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate: Date
    @State private var selectedQuickPick: Date?

    init(
        initialDate: Date? = nil,
        onConfirm: @escaping (ScheduledSync) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialDate = initialDate
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        let fallback = Self.roundUpTo30Minutes(Date()).addingTimeInterval(3600)
        let candidate = initialDate ?? fallback
        _selectedDate = State(initialValue: max(candidate, fallback))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(String(localized: "async.schedule.sheet.title", defaultValue: "Next Sync time"))
                .font(.title2.weight(.semibold))

            quickPickSection

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "async.schedule.sheet.manualSection", defaultValue: "Manual"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                DatePicker(
                    "",
                    selection: Binding(
                        get: { selectedDate },
                        set: { newValue in
                            selectedDate = Self.roundUpTo30Minutes(newValue)
                            selectedQuickPick = nil
                        }
                    ),
                    in: Self.earliestAllowed()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
            }

            HStack {
                Spacer()
                Button(String(localized: "async.common.cancel", defaultValue: "Cancel")) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "async.schedule.sheet.confirm", defaultValue: "Confirm")) {
                    onConfirm(ScheduledSync(at: selectedDate))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedDate <= Date())
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    // MARK: - Quick picks

    @ViewBuilder
    private var quickPickSection: some View {
        let now = Date()
        let presets = Self.quickPickPresets(from: now)
        // Pull busy intervals for the 7-day window we show quick picks for.
        // EventKit access is opportunistic — if denied, this returns [] and
        // all presets stay enabled (calendar-agnostic fallback).
        let busy = CalendarBridge.shared.busyIntervals(
            from: now,
            to: now.addingTimeInterval(8 * 24 * 3600)
        )
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "async.schedule.sheet.quickPickSection", defaultValue: "Quick picks"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(presets, id: \.date) { preset in
                        let isBusy = Self.intersectsBusy(preset.date, busy: busy)
                        Button {
                            selectedDate = preset.date
                            selectedQuickPick = preset.date
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label)
                                    .font(.body)
                                HStack(spacing: 4) {
                                    Text(Self.formatAbsolute(preset.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if isBusy {
                                        Text(String(localized: "async.schedule.preset.busyBadge",
                                                    defaultValue: "Busy"))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedQuickPick == preset.date ? .accentColor : .primary)
                        .disabled(isBusy)
                    }
                }
            }
        }
    }

    /// A 30-minute window starting at `candidate` is considered busy if it
    /// overlaps **any** merged busy interval. Candidates right at the
    /// boundary of a meeting (end == candidate) are allowed.
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

    // MARK: - Preset generation

    struct QuickPickPreset: Hashable {
        let label: String
        let date: Date
    }

    static func quickPickPresets(from reference: Date) -> [QuickPickPreset] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        let now = reference
        let earliest = earliestAllowed(reference: reference)

        var presets: [QuickPickPreset] = []
        let relativeOffsets: [(String, TimeInterval)] = [
            (String(localized: "async.schedule.preset.inHours1", defaultValue: "In 1 hour"), 3600),
            (String(localized: "async.schedule.preset.inHours3", defaultValue: "In 3 hours"), 3 * 3600),
            (String(localized: "async.schedule.preset.inHours6", defaultValue: "In 6 hours"), 6 * 3600),
        ]
        for (label, offset) in relativeOffsets {
            let candidate = roundUpTo30Minutes(now.addingTimeInterval(offset))
            if candidate >= earliest {
                presets.append(QuickPickPreset(label: label, date: candidate))
            }
        }

        // Tidy day-of-week slots within the next 7 days.
        for dayOffset in 1...7 {
            guard let dayStart = calendar.date(
                byAdding: .day, value: dayOffset,
                to: calendar.startOfDay(for: now)
            ) else { continue }
            for hour in [9, 18] {
                guard let slot = calendar.date(
                    bySettingHour: hour, minute: 0, second: 0, of: dayStart
                ) else { continue }
                guard slot > now, slot >= earliest else { continue }
                let label = formatDayOfWeek(slot, calendar: calendar) + " " + String(format: "%02d:00", hour)
                presets.append(QuickPickPreset(label: label, date: slot))
            }
        }

        // Dedup & cap.
        var seen: Set<Date> = []
        return presets.filter { seen.insert($0.date).inserted }.prefix(12).map { $0 }
    }

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

    /// Earliest time a Sync may be scheduled. Keeps the picker from offering
    /// "now" as a quick pick.
    static func earliestAllowed(reference: Date = Date()) -> Date {
        // At least 5 minutes in the future, rounded up to the next 30-minute
        // boundary — gives the user a visible margin to confirm.
        roundUpTo30Minutes(reference.addingTimeInterval(5 * 60))
    }

    private static func formatAbsolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d (EEE) HH:mm"
        return formatter.string(from: date)
    }

    private static func formatDayOfWeek(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale
        formatter.dateFormat = "M/d (EEE)"
        return formatter.string(from: date)
    }
}
