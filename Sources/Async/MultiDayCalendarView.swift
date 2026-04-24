import EventKit
import SwiftUI

/// A 3-day (configurable) Google-Calendar-style time grid for picking a
/// Sync session slot. Hours on the Y axis, days on X. Busy events from
/// EventKit render as translucent blocks; empty 30-min slots are tap
/// targets. The selected slot is highlighted as a block of the chosen
/// `duration`, so the user sees exactly where the Sync will land.
///
/// Why hand-rolled: there is no maintained macOS-native calendar view
/// library (CalendarKit et al are iOS-only); the scope we need — read-only
/// busy rendering + slot picking — is small enough to keep in ~300 lines.
struct MultiDayCalendarView: View {
    /// Duration (seconds) the user intends to schedule. Drives the height
    /// of the selection highlight + the busy-overlap filter.
    let duration: TimeInterval
    /// Currently picked slot (absolute start time). `nil` when nothing is
    /// selected yet.
    @Binding var selectedSlot: Date?
    /// Left edge day (midnight). Navigation arrows move this in `daysShown`
    /// increments.
    @Binding var anchorDay: Date

    /// Number of day columns rendered. Keep small (3–5) for legibility.
    let daysShown: Int

    /// Bumped whenever Calendar access state changes or the store posts an
    /// `EKEventStoreChanged` notification. Touching it in `body` forces a
    /// re-render so busy-interval queries pick up newly-visible events.
    @State private var eventStoreRevision: Int = 0
    /// `true` once we've auto-scrolled to the current time on first render.
    /// Prevents re-centering on every view update.
    @State private var didInitialScroll = false

    /// Start hour of the visible grid (inclusive). `0` = midnight.
    private static let startHour = 0
    /// End hour of the visible grid (exclusive). 24 = midnight of next day.
    private static let endHour = 24
    /// Pixels per minute at standard zoom.
    private static let pxPerMinute: CGFloat = 0.9
    /// Slot granularity (minutes).
    private static let slotMinutes = 30
    /// Width reserved for the hour-label column on the left.
    private static let hourColumnWidth: CGFloat = 44
    /// Width reserved on the trailing edge of each row — matches the right
    /// chevron in the header so day columns have the same horizontal
    /// footprint in both the header and the grid below.
    private static let rightTrailingWidth: CGFloat = 36
    /// Height of the day-header row above each column.
    private static let headerHeight: CGFloat = 38

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    private var visibleDays: [Date] {
        (0..<daysShown).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: anchorDay)
        }
    }

    private var gridHeight: CGFloat {
        CGFloat(Self.endHour - Self.startHour) * 60 * Self.pxPerMinute
    }

    private var busyByDay: [Date: [DateInterval]] {
        let last = calendar.date(byAdding: .day, value: daysShown, to: anchorDay) ?? anchorDay
        let raw = CalendarBridge.shared.busyIntervals(from: anchorDay, to: last)
        var result: [Date: [DateInterval]] = [:]
        for day in visibleDays {
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            let clipped = raw.compactMap { interval -> DateInterval? in
                let s = max(interval.start, dayStart)
                let e = min(interval.end, dayEnd)
                guard e > s else { return nil }
                return DateInterval(start: s, end: e)
            }
            result[dayStart] = clipped
        }
        return result
    }

    var body: some View {
        // Touch the revision so SwiftUI knows this body depends on it; the
        // value itself is unused past that.
        let _ = eventStoreRevision

        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        hourColumn
                        ForEach(visibleDays, id: \.self) { day in
                            dayColumn(for: calendar.startOfDay(for: day))
                        }
                        // Matches the width of the right chevron so the
                        // day columns in the grid line up under the day
                        // headers above.
                        Spacer()
                            .frame(width: Self.rightTrailingWidth)
                    }
                }
                .frame(maxHeight: 420)
                .onAppear {
                    // Center on the current hour the first time the view
                    // appears. Defer one runloop so the ScrollView has had
                    // a chance to lay out its content.
                    guard !didInitialScroll else { return }
                    didInitialScroll = true
                    let hour = calendar.component(.hour, from: Date())
                    let targetHour = min(
                        max(hour, Self.startHour),
                        Self.endHour - 1
                    )
                    DispatchQueue.main.async {
                        withAnimation(nil) {
                            proxy.scrollTo("hour-\(targetHour)", anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .task {
            // Fire the TCC prompt on sheet open if we haven't asked yet.
            // After the user grants (or denies), bump the revision so busy
            // intervals requery with the new access state.
            _ = await CalendarBridge.shared.requestAccessIfNeeded()
            eventStoreRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            // External edits (Calendar.app, iOS, Google sync) → refresh.
            eventStoreRevision &+= 1
        }
    }

    // MARK: - Header (day labels + navigation)

    private var header: some View {
        HStack(spacing: 0) {
            // Left arrow occupies the same width as the hour-label column
            // below, so the three day-header cells line up exactly with the
            // three day columns. `.contentShape` widens the hit area to the
            // full arrow cell (image alone is tiny).
            Button {
                shift(by: -daysShown)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                    .frame(width: Self.hourColumnWidth, height: Self.headerHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(visibleDays, id: \.self) { day in
                dayHeader(for: day)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.headerHeight)
            }

            Button {
                shift(by: daysShown)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.medium))
                    .frame(width: Self.rightTrailingWidth, height: Self.headerHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func dayHeader(for day: Date) -> some View {
        let today = calendar.isDateInToday(day)
        return VStack(spacing: 2) {
            Text(Self.weekdayLabel(day))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.dayNumberLabel(day))
                .font(.title3.weight(today ? .bold : .regular))
                .foregroundStyle(today ? Color.accentColor : .primary)
        }
    }

    // MARK: - Hour column

    private var hourColumn: some View {
        VStack(spacing: 0) {
            ForEach(Self.startHour..<Self.endHour, id: \.self) { hour in
                HStack {
                    Spacer()
                    Text("\(hour):00")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, -7)  // align label to the top of the hour line
                        .padding(.trailing, 6)
                }
                .frame(width: Self.hourColumnWidth, height: 60 * Self.pxPerMinute, alignment: .topTrailing)
                .id("hour-\(hour)")
            }
        }
        .frame(width: Self.hourColumnWidth, height: gridHeight, alignment: .top)
    }

    // MARK: - Day column

    private func dayColumn(for dayStart: Date) -> some View {
        let slots = Self.slots(for: dayStart)
        let busy = busyByDay[dayStart] ?? []
        let now = Date()

        return ZStack(alignment: .topLeading) {
            // Background hour grid lines.
            VStack(spacing: 0) {
                ForEach(Self.startHour..<Self.endHour, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                        .frame(maxWidth: .infinity, alignment: .top)
                    Spacer()
                        .frame(height: 60 * Self.pxPerMinute - 0.5)
                }
            }

            // Half-hour grid lines (lighter).
            VStack(spacing: 0) {
                ForEach(Self.startHour..<Self.endHour, id: \.self) { _ in
                    Spacer().frame(height: 30 * Self.pxPerMinute)
                    Rectangle()
                        .fill(Color.primary.opacity(0.03))
                        .frame(height: 0.5)
                    Spacer().frame(height: 30 * Self.pxPerMinute - 0.5)
                }
            }

            // Busy event rectangles.
            ForEach(busy, id: \.start) { interval in
                busyRect(for: interval, dayStart: dayStart)
            }

            // Clickable slot layer — transparent, full grid height.
            // `.contentShape(Rectangle())` is required here: SwiftUI won't
            // hit-test a Button whose label is `Color.clear` or a Rectangle
            // with zero opacity, so without an explicit content shape the
            // slot buttons look present but don't receive clicks.
            VStack(spacing: 0) {
                ForEach(slots, id: \.self) { slot in
                    let isPast = slot <= now
                    let overlaps = Self.overlaps(slot: slot, duration: duration, busy: busy)
                    let disabled = isPast || overlaps
                    Button {
                        if !disabled {
                            selectedSlot = slot
                        }
                    } label: {
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .frame(height: CGFloat(Self.slotMinutes) * Self.pxPerMinute)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                }
            }

            // Current-time line.
            if calendar.isDate(dayStart, inSameDayAs: now) {
                nowLine(dayStart: dayStart)
            }

            // Selection highlight.
            if let slot = selectedSlot, calendar.isDate(dayStart, inSameDayAs: slot) {
                selectionRect(for: slot, dayStart: dayStart)
            }
        }
        .frame(height: gridHeight)
        .frame(maxWidth: .infinity)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)
                .frame(maxHeight: .infinity),
            alignment: .leading
        )
    }

    // MARK: - Geometry helpers

    private func busyRect(for interval: DateInterval, dayStart: Date) -> some View {
        let top = yForDate(interval.start, dayStart: dayStart)
        let height = yForDate(interval.end, dayStart: dayStart) - top
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.orange.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.orange.opacity(0.55), lineWidth: 0.5)
            )
            .overlay(
                Text(String(localized: "async.schedule.preset.busyBadge",
                            defaultValue: "Busy"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.leading, 4)
                    .padding(.top, 2),
                alignment: .topLeading
            )
            .frame(height: max(4, height))
            .offset(y: top)
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
    }

    private func selectionRect(for slot: Date, dayStart: Date) -> some View {
        let top = yForDate(slot, dayStart: dayStart)
        let end = slot.addingTimeInterval(duration)
        let bottom = yForDate(end, dayStart: dayStart)
        let height = max(12, bottom - top)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.28))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            )
            .frame(height: height)
            .offset(y: top)
            .padding(.horizontal, 3)
            .allowsHitTesting(false)
    }

    private func nowLine(dayStart: Date) -> some View {
        let top = yForDate(Date(), dayStart: dayStart)
        return Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .offset(x: -3, y: top - 3)
            .overlay(
                Rectangle()
                    .fill(Color.red)
                    .frame(height: 1)
                    .offset(y: top),
                alignment: .top
            )
            .allowsHitTesting(false)
    }

    /// Converts a date (within the day's span) to a Y pixel offset from the
    /// top of the grid. Clamps above/below the visible range.
    private func yForDate(_ date: Date, dayStart: Date) -> CGFloat {
        let minutesFromStart = date.timeIntervalSince(dayStart) / 60.0
        let gridStartMinutes = CGFloat(Self.startHour * 60)
        let offset = CGFloat(minutesFromStart) - gridStartMinutes
        return max(0, min(gridHeight, offset * Self.pxPerMinute))
    }

    // MARK: - Navigation

    private func shift(by days: Int) {
        let today = calendar.startOfDay(for: Date())
        guard let candidate = calendar.date(byAdding: .day, value: days, to: anchorDay) else { return }
        // Clamp: don't let the user navigate back past today.
        anchorDay = max(candidate, today)
    }

    // MARK: - Static slot/formatting helpers

    static func slots(for dayStart: Date) -> [Date] {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        var result: [Date] = []
        var minute = startHour * 60
        let end = endHour * 60
        while minute < end {
            let hour = minute / 60
            let m = minute % 60
            if let slot = c.date(bySettingHour: hour, minute: m, second: 0, of: dayStart) {
                result.append(slot)
            }
            minute += slotMinutes
        }
        return result
    }

    static func overlaps(slot: Date, duration: TimeInterval, busy: [DateInterval]) -> Bool {
        let end = slot.addingTimeInterval(duration)
        return busy.contains { interval in
            interval.start < end && slot < interval.end
        }
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEE"
        return f
    }()

    private static let dayNumberFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "M/d"
        return f
    }()

    static func weekdayLabel(_ date: Date) -> String {
        weekdayFormatter.string(from: date)
    }

    static func dayNumberLabel(_ date: Date) -> String {
        dayNumberFormatter.string(from: date)
    }
}
