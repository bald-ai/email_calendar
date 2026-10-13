import Foundation

/// Google Calendar repeat rules (RFC 5545 RRULE lines), as the AI writes them and the app stores them.
public enum RepeatRule {
    /// UNTIL is inclusive and must have the same value type as DTSTART (RFC 5545).
    static func forEvent(_ rule: String, isAllDay: Bool, timeZone: TimeZone) -> String? {
        guard rule.uppercased().hasPrefix("RRULE:") else { return rule }
        var parts = rule.uppercased().split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let indexes = parts.indices.filter { parts[$0].hasPrefix("UNTIL=") }
        guard indexes.count <= 1 else { return nil }
        guard let index = indexes.first else { return rule }
        guard !parts.contains(where: { $0.hasPrefix("COUNT=") }) else { return nil }
        let value = String(parts[index].dropFirst(6))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if value.count == 8 {
            let text = "\(value.prefix(4))-\(value.dropFirst(4).prefix(2))-\(value.suffix(2))"
            guard let day = CalendarDates.day(text, calendar: calendar) else { return nil }
            if !isAllDay {
                let cutoff = calendar.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(-1)
                parts[index] = "UNTIL=" + cutoff.formatted(.iso8601).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            }
        } else {
            guard value.count == 16, value.hasSuffix("Z"), value[value.index(value.startIndex, offsetBy: 8)] == "T" else { return nil }
            let text = "\(value.prefix(4))-\(value.dropFirst(4).prefix(2))-\(value.dropFirst(6).prefix(2))T\(value.dropFirst(9).prefix(2)):\(value.dropFirst(11).prefix(2)):\(value.dropFirst(13).prefix(2))Z"
            guard let date = try? Date.ISO8601FormatStyle().parse(text),
                  date.formatted(.iso8601).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") == value else { return nil }
            if isAllDay { parts[index] = "UNTIL=" + CalendarDates.dayString(date, calendar: calendar).replacingOccurrences(of: "-", with: "") }
        }
        return parts.joined(separator: ";")
    }

    /// "RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=8" from "freq=weekly;byday=tu;count=8" or with the prefix; nil if it isn't a rule.
    public static func normalize(_ rule: String) -> String? {
        var body = rule.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if body.hasPrefix("RRULE:") { body.removeFirst(6) }
        let parts = body.split(separator: ";").map(String.init)
        guard let freq = parts.first, ["FREQ=DAILY", "FREQ=WEEKLY", "FREQ=MONTHLY", "FREQ=YEARLY"].contains(freq) else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,+-")
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, ["INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "WKST"].contains(pair[0]),
                  !pair[1].isEmpty, pair[1].allSatisfy(allowed.contains) else { return nil }
        }
        return "RRULE:" + parts.joined(separator: ";")
    }

    /// "Every week on Tue, 8 times", "Every weekday", "Every month until 30 Nov 2026".
    public static func describe(_ rule: String) -> String {
        guard let normalized = normalize(rule) else { return "Repeats" }
        var fields: [String: String] = [:]
        for part in normalized.dropFirst(6).split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        let interval = Int(fields["INTERVAL"] ?? "1") ?? 1
        let names = ["MO": "Mon", "TU": "Tue", "WE": "Wed", "TH": "Thu", "FR": "Fri", "SA": "Sat", "SU": "Sun"]
        let days = fields["BYDAY"]?.split(separator: ",").map(String.init) ?? []
        var text: String
        switch fields["FREQ"] {
        case "DAILY": text = interval == 1 ? "Every day" : "Every \(interval) days"
        case "WEEKLY":
            if Set(days) == ["MO", "TU", "WE", "TH", "FR"] && interval == 1 { text = "Every weekday" }
            else {
                text = interval == 1 ? "Every week" : "Every \(interval) weeks"
                if !days.isEmpty { text += " on " + days.map { names[$0] ?? $0 }.joined(separator: ", ") }
            }
        case "MONTHLY":
            text = interval == 1 ? "Every month" : "Every \(interval) months"
            if let day = fields["BYMONTHDAY"] { text += " on day \(day)" }
        default: text = interval == 1 ? "Every year" : "Every \(interval) years"
        }
        if let count = fields["COUNT"] { text += ", \(count) times" }
        if let until = fields["UNTIL"], until.count >= 8 {
            var components = DateComponents()
            components.year = Int(until.prefix(4)); components.month = Int(until.dropFirst(4).prefix(2)); components.day = Int(until.dropFirst(6).prefix(2))
            if let date = Calendar(identifier: .gregorian).date(from: components) {
                text += " until " + date.formatted(.dateTime.day().month(.abbreviated).year())
            }
        }
        return text
    }
}
