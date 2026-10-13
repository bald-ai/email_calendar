import Foundation

/// Reads what you type into the quick alarm field: "10" or "10m" (minutes from now), "1h30", "90s",
/// "in 20 min", or a clock time like "14:30", "7.05", "7pm", "7:30 am" (the next time it comes around).
public enum AlarmTime {
    public static func parse(_ input: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        var text = input.lowercased().trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("in ") { text.removeFirst(3) }
        text = text.replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }

        if let seconds = duration(text) { return seconds > 0 ? now.addingTimeInterval(seconds) : nil }
        guard let (hour, minute) = clock(text) else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first)
    }

    /// "10", "10m", "10min", "1h", "1h30", "1h30m", "1.5h", "90s".
    private static func duration(_ text: String) -> TimeInterval? {
        let units: [(String, TimeInterval)] = [("hours", 3600), ("hour", 3600), ("hrs", 3600), ("hr", 3600), ("h", 3600),
                                               ("minutes", 60), ("minute", 60), ("mins", 60), ("min", 60), ("m", 60),
                                               ("seconds", 1), ("sec", 1), ("s", 1)]
        if text.count <= 3, let minutes = Int(text) { return TimeInterval(minutes * 60) }
        var rest = Substring(text)
        var total: TimeInterval = 0
        var lastUnit: TimeInterval?
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." || $0 == "," }
            guard let value = Double(number.replacingOccurrences(of: ",", with: ".")) else { return nil }
            rest = rest.dropFirst(number.count)
            if let (name, size) = units.first(where: { rest.hasPrefix($0.0) }) {
                rest = rest.dropFirst(name.count)
                total += value * size; lastUnit = size
            } else if rest.isEmpty, lastUnit == 3600 {
                total += value * 60   // "1h30": the trailing number is minutes.
            } else {
                return nil
            }
        }
        return lastUnit == nil ? nil : total
    }

    /// "14:30", "14.30", "1430", "7pm", "7:05pm", "7:05 am".
    private static func clock(_ text: String) -> (Int, Int)? {
        var text = text
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where text.hasSuffix(suffix) {
            meridiem = String(suffix.prefix(1)); text.removeLast(suffix.count); break
        }
        let pieces = text.split(whereSeparator: { $0 == ":" || $0 == "." })
        var hour: Int, minute = 0
        if pieces.count == 2, let h = Int(pieces[0]), let m = Int(pieces[1]), pieces[1].count == 2 {
            hour = h; minute = m
        } else if pieces.count == 1, let value = Int(pieces[0]) {
            if meridiem != nil, pieces[0].count <= 2 { hour = value }
            else if pieces[0].count == 4 { hour = value / 100; minute = value % 100 }
            else { return nil }
        } else {
            return nil
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "p" ? 12 : 0)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }
}
