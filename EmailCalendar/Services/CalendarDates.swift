import Foundation

enum CalendarDates {
    static func day(_ text: String, calendar: Calendar) -> Date? {
        let values = text.split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 3, values[0].count == 4, values[1].count == 2, values[2].count == 2,
              let year = Int(values[0]), (1...9999).contains(year),
              let month = Int(values[1]), let day = Int(values[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == year && actual.month == month && actual.day == day ? date : nil
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func moving(start: Date, end: Date, to date: Date, allDay: Bool, calendar: Calendar = .current) -> (start: Date, end: Date) {
        if allDay {
            let count = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                     to: calendar.startOfDay(for: end)).day ?? 1)
            let newStart = calendar.startOfDay(for: date)
            return (newStart, calendar.date(byAdding: .day, value: count, to: newStart)!)
        }
        return (date, date.addingTimeInterval(end.timeIntervalSince(start)))
    }
}

/// Shared by the main calendar and overlay. Date math happens once per event, not once per cell.
struct EventDayIndex {
    private(set) var all: [CalendarEvent]
    private var byDay: [Date: [CalendarEvent]] = [:]
    private let calendar: Calendar

    init(_ events: [CalendarEvent] = [], calendar: Calendar = .current) {
        self.calendar = calendar
        all = events
        for event in events where !event.isCancelled && event.end >= event.start {
            var day = calendar.startOfDay(for: event.start)
            // A zero-length event still belongs to the day it starts on.
            let end = max(event.end, event.start.addingTimeInterval(1))
            while day < end {
                byDay[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        for key in byDay.keys {
            byDay[key]!.sort { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
        }
    }

    func events(on day: Date) -> [CalendarEvent] { byDay[calendar.startOfDay(for: day)] ?? [] }
}

enum CalendarNavigation {
    static func monthWeeks(around date: Date, count: Int = 78, calendar: Calendar) -> [Date] {
        let week = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        let first = calendar.date(byAdding: .weekOfYear, value: -26, to: week)!
        return (0..<count).map { calendar.date(byAdding: .weekOfYear, value: $0, to: first)! }
    }

    static func timelineDays(around date: Date, count: Int = 182, precedingWeeks: Int = 8, calendar: Calendar) -> [Date] {
        let week = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        let first = calendar.date(byAdding: .weekOfYear, value: -precedingWeeks, to: week)!
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
}
