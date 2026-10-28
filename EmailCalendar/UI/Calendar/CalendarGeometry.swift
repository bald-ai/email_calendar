#if os(macOS)
import SwiftUI
import os

enum CalendarGeometry {
    /// Built once, and again when the Mac changes time zone: the grids call date math thousands of times while scrolling.
    static var calendar: Calendar { stored.withLock { $0 } }
    private static let stored = OSAllocatedUnfairLock(initialState: makeCalendar())

    private static func makeCalendar() -> Calendar {
        var result = Calendar.current
        result.timeZone = .current
        result.firstWeekday = 2
        result.minimumDaysInFirstWeek = 4
        return result
    }

    /// Called after the system time zone changed (e.g. landing in another country).
    static func timeZoneDidChange() {
        stored.withLock { $0 = makeCalendar() }
    }

    /// Events grouped by the days they touch, so a grid cell looks up its day instead of
    /// scanning every event.
    typealias DayIndex = EventDayIndex

    static func days(inWeekContaining date: Date) -> [Date] {
        let calendar = calendar
        let first = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    static func monthDays(containing date: Date) -> [Date] {
        let calendar = calendar
        let month = calendar.dateInterval(of: .month, for: date)!
        let first = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
        let last = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1))!.end
        var result: [Date] = []
        var cursor = first
        while cursor < last {
            result.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return result
    }

    static func overlaps(_ event: CalendarEvent, day: Date) -> Bool {
        CalendarDates.overlaps(event, day: day, calendar: calendar)
    }

    static func minutes(_ date: Date, on day: Date) -> Double {
        let calendar = calendar
        if date <= calendar.startOfDay(for: day) { return 0 }
        if date >= calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))! { return 1440 }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    static func date(at minute: Double, on day: Date) -> Date {
        let rounded = min(1425, max(0, Int((minute / 15).rounded()) * 15))
        return calendar.date(bySettingHour: rounded / 60, minute: rounded % 60, second: 0, of: day)!
    }

    static func color(_ hex: String) -> Color {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x5482A2
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    static func textColor(_ hex: String) -> Color {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x5482A2
        func linear(_ channel: UInt64) -> Double {
            let component = Double(channel) / 255
            return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((value >> 16) & 255) + 0.7152 * linear((value >> 8) & 255) + 0.0722 * linear(value & 255)
        return luminance > 0.179 ? .black : .white
    }

    struct Placement: Identifiable {
        var id: String { event.cacheID }
        let event: CalendarEvent
        let start: Double
        let end: Double
        let lane: Int
        let lanes: Int
    }

    /// Allocate columns within each connected overlap group, keeping separate
    /// appointments full-width and simultaneous appointments individually clickable.
    static func placements(_ events: [CalendarEvent], day: Date) -> [Placement] {
        let ordered = events.filter { !$0.isAllDay && overlaps($0, day: day) }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var groups: [[CalendarEvent]] = []
        var groupEnd = Date.distantPast
        for event in ordered {
            if event.start >= groupEnd {
                groups.append([event])
                groupEnd = event.end
            } else {
                groups[groups.count - 1].append(event)
                groupEnd = max(groupEnd, event.end)
            }
        }
        return groups.flatMap { group in
            var laneEnds: [Date] = []
            var allocated: [(CalendarEvent, Int)] = []
            for event in group {
                let lane: Int
                if let available = laneEnds.firstIndex(where: { $0 <= event.start }) {
                    lane = available
                    laneEnds[available] = event.end
                } else {
                    lane = laneEnds.count
                    laneEnds.append(event.end)
                }
                allocated.append((event, lane))
            }
            return allocated.map { event, lane in
                Placement(event: event, start: minutes(event.start, on: day), end: minutes(event.end, on: day), lane: lane, lanes: laneEnds.count)
            }
        }
    }
}

#endif
