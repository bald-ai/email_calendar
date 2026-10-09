import Foundation

struct MockState: Codable {
    var messages: [String: MockMessage] = [:]
    var labels: [GoogleLabel] = []
    var drafts: [String: String] = [:] // Draft ID -> message ID.
    var filters: [GoogleFilter] = []
    var history: [MockHistory] = []
    var historyID = 1_000
    var oldestHistoryID = 1_000
    var labelCounter = 0
    var idCounter = 0
    var calendars: [GoogleCalendar] = []
    var events: [MockEvent] = []
    var calendarVersion = 0
    var simulatedCount = 0
    var firstArrivalsDelivered = false
    /// nil for data saved before the busy calendar existed; optional so older files still decode.
    var seedVersion: Int?

    func thread(_ id: String) -> [MockMessage] {
        messages.values.filter { $0.threadId == id }.sorted { $0.internalDate < $1.internalDate }
    }

    func threadIDs() -> Set<String> { Set(messages.values.map(\.threadId)) }
}

struct MockMessage: Codable {
    var id: String
    var threadId: String
    var labelIds: Set<String>
    var internalDate: Int64
    var headers: [GoogleMailHeader]
    var plain: String
    var html: String?
    var attachments: [MockAttachment]

    var snippet: String {
        String(plain.replacingOccurrences(of: "\n", with: " ").prefix(140))
    }

    func header(_ name: String) -> String {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }
}

struct MockAttachment: Codable {
    var id: String
    var filename: String
    var mimeType: String
    var data: Data
}

struct MockHistory: Codable {
    var id: Int
    var messageID: String
    var threadID: String
}

struct MockEvent: Codable {
    var calendarID: String
    var event: GoogleEvent
    var version: Int
    var deleted = false
    var exceptions: [String: GoogleEvent] = [:] // Instance ID -> edited or cancelled occurrence.
}

/// The subset of Gmail search syntax the app and a person typing in the search box use.
struct MockQuery {
    private var clauses: [(negated: Bool, key: String?, value: String)] = []
    private(set) var includesTrash = false

    init(_ query: String) {
        var tokens: [String] = [], current = "", depth = 0, quoted = false
        for character in query {
            if character == "\"" { quoted.toggle(); continue }
            if character == "(" { depth += 1; if current.hasSuffix(":") { continue } }
            if character == ")" { depth = max(0, depth - 1); continue }
            if character.isWhitespace && depth == 0 && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { tokens.append(current) }
        for var token in tokens {
            let negated = token.hasPrefix("-")
            if negated { token.removeFirst() }
            if let colon = token.firstIndex(of: ":"), token[..<colon].allSatisfy(\.isLetter) {
                let key = token[..<colon].lowercased(), value = String(token[token.index(after: colon)...]).lowercased()
                if key == "in" && (value == "trash" || value == "anywhere") { includesTrash = true }
                clauses.append((negated, key, value))
            } else {
                clauses.append((negated, nil, token.lowercased()))
            }
        }
    }

    func matches(_ message: MockMessage, labels: [GoogleLabel]) -> Bool {
        clauses.allSatisfy { clause in clause.negated != matches(clause.key, clause.value, message, labels) }
    }

    private func matches(_ key: String?, _ value: String, _ message: MockMessage, _ labels: [GoogleLabel]) -> Bool {
        let date = Date(timeIntervalSince1970: TimeInterval(message.internalDate) / 1_000)
        switch key {
        case "from": return message.header("From").lowercased().contains(value)
        case "to": return (message.header("To") + message.header("Cc")).lowercased().contains(value)
        case "subject": return message.header("Subject").lowercased().contains(value)
        case "newer_than": return date > Date.now.addingTimeInterval(-Self.age(value))
        case "older_than": return date < Date.now.addingTimeInterval(-Self.age(value))
        case "has": return value == "attachment" ? !message.attachments.isEmpty : false
        case "is":
            switch value {
            case "unread": return message.labelIds.contains("UNREAD")
            case "read": return !message.labelIds.contains("UNREAD")
            case "starred": return message.labelIds.contains("STARRED")
            default: return false
            }
        case "in":
            switch value {
            case "anywhere": return true
            case "inbox", "sent", "trash", "spam", "draft", "drafts":
                return message.labelIds.contains(value == "drafts" ? "DRAFT" : value.uppercased())
            default: return false
            }
        case "label":
            let normalized = value.replacingOccurrences(of: "-", with: " ")
            return labels.contains { label in
                let name = label.name.lowercased()
                return (name == value || name == normalized) && message.labelIds.contains(label.id)
            } || message.labelIds.contains(value.uppercased())
        case nil:
            let haystack = [message.header("From"), message.header("To"), message.header("Subject"), message.plain]
                .joined(separator: " ").lowercased()
            return haystack.contains(value)
        default:
            return false
        }
    }

    private static func age(_ value: String) -> TimeInterval {
        let amount = Double(value.dropLast()) ?? 0
        switch value.last {
        case "m": return amount * 30 * 86_400
        case "y": return amount * 365 * 86_400
        default: return amount * 86_400
        }
    }
}

/// Just enough MIME parsing to store what MIMEComposer produces for sends and drafts.
enum MockMIME {
    struct Parsed {
        var headers: [GoogleMailHeader] = []
        var plain = ""
        var html: String?
        var attachments: [(filename: String, mimeType: String, data: Data)] = []
    }

    static func parse(_ data: Data) -> Parsed {
        var parsed = Parsed()
        let text = String(decoding: data, as: UTF8.self)
        let (headers, body) = split(text)
        parsed.headers = headers.filter { !$0.name.lowercased().hasPrefix("content-") && $0.name.lowercased() != "mime-version" }
        collect(headers: headers, body: body, into: &parsed)
        return parsed
    }

    private static func collect(headers: [GoogleMailHeader], body: String, into parsed: inout Parsed) {
        let contentType = value("Content-Type", headers) ?? "text/plain"
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        if mime.hasPrefix("multipart/"), let boundary = parameter("boundary", contentType) {
            for segment in body.components(separatedBy: "--\(boundary)").dropFirst() {
                if segment.hasPrefix("--") { break }
                let part = segment.hasPrefix("\r\n") ? String(segment.dropFirst(2)) : segment
                let (partHeaders, partBody) = split(part)
                collect(headers: partHeaders, body: partBody, into: &parsed)
            }
            return
        }
        let encoding = value("Content-Transfer-Encoding", headers)?.lowercased() ?? ""
        let decoded: Data
        if encoding == "base64" {
            decoded = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
        } else {
            decoded = Data(body.trimmingCharacters(in: .newlines).utf8)
        }
        let disposition = value("Content-Disposition", headers) ?? ""
        if let filename = parameter("filename", disposition) ?? parameter("name", contentType) {
            parsed.attachments.append((filename, mime, decoded))
        } else if mime == "text/html" {
            parsed.html = String(decoding: decoded, as: UTF8.self)
        } else {
            let string = String(decoding: decoded, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            parsed.plain += parsed.plain.isEmpty ? string : "\n" + string
        }
    }

    private static func split(_ entity: String) -> ([GoogleMailHeader], String) {
        let separator = entity.range(of: "\r\n\r\n") ?? entity.range(of: "\n\n")
        let head = separator.map { String(entity[..<$0.lowerBound]) } ?? entity
        let body = separator.map { String(entity[$0.upperBound...]) } ?? ""
        var headers: [GoogleMailHeader] = []
        for line in head.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }) {
            if line.first == " " || line.first == "\t", !headers.isEmpty {
                headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append(GoogleMailHeader(name: String(line[..<colon]),
                                                value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        return (headers, body)
    }

    private static func value(_ name: String, _ headers: [GoogleMailHeader]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func parameter(_ name: String, _ header: String) -> String? {
        for piece in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if piece.lowercased().hasPrefix("\(name)*=") {
                let raw = piece.dropFirst(name.count + 2)
                let encoded = raw.components(separatedBy: "''").last ?? String(raw)
                return encoded.removingPercentEncoding ?? encoded
            }
        }
        for piece in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where piece.lowercased().hasPrefix("\(name)=") {
            return String(piece.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}

/// Expands RRULE masters into Google-style single-event instances.
enum MockRecurrence {
    static func instances(of stored: MockEvent, from windowStart: Date, to windowEnd: Date) -> [GoogleEvent] {
        let master = stored.event
        guard let start = CalendarService.date(master.start), let end = CalendarService.date(master.end) else { return [] }
        var result: [GoogleEvent] = []
        for occurrence in occurrences(of: master, start: start, until: windowEnd) {
            guard var instance = instance(of: stored, originalStart: occurrence, masterStart: start, masterEnd: end) else { continue }
            if instance.status == "cancelled" { continue }
            guard let instanceStart = CalendarService.date(instance.start), let instanceEnd = CalendarService.date(instance.end),
                  instanceStart < windowEnd, instanceEnd > windowStart else { continue }
            instance.recurrence = nil
            result.append(instance)
        }
        return result
    }

    static func instance(of stored: MockEvent, originalStart: Date) -> GoogleEvent? {
        guard let start = CalendarService.date(stored.event.start), let end = CalendarService.date(stored.event.end) else { return nil }
        return instance(of: stored, originalStart: originalStart, masterStart: start, masterEnd: end)
    }

    private static func instance(of stored: MockEvent, originalStart: Date, masterStart: Date, masterEnd: Date) -> GoogleEvent? {
        let master = stored.event
        let allDay = master.start?.date != nil
        let id = "\(master.id)_\(stamp(originalStart, allDay: allDay))"
        if let exception = stored.exceptions[id] { return exception }
        var instance = master
        instance.id = id
        instance.recurringEventId = master.id
        instance.recurrence = nil
        instance.originalStartTime = value(originalStart, allDay: allDay, zone: master.start?.timeZone)
        instance.start = value(originalStart, allDay: allDay, zone: master.start?.timeZone)
        let duration = masterEnd.timeIntervalSince(masterStart)
        let endDate = allDay
            ? Calendar.current.date(byAdding: .day, value: Int((duration / 86_400).rounded()), to: originalStart) ?? originalStart
            : originalStart.addingTimeInterval(duration)
        instance.end = value(endDate, allDay: allDay, zone: master.end?.timeZone)
        return instance
    }

    static func parseInstanceStamp(_ stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if stamp.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd"
        }
        return formatter.date(from: stamp)
    }

    private static func stamp(_ date: Date, allDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = allDay ? .current : TimeZone(identifier: "UTC")
        formatter.dateFormat = allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func value(_ date: Date, allDay: Bool, zone: String?) -> GoogleEventDateTime {
        if allDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return GoogleEventDateTime(date: formatter.string(from: date))
        }
        return GoogleEventDateTime(dateTime: ISO8601DateFormatter().string(from: date), timeZone: zone)
    }

    /// Supports FREQ=DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL and weekly BYDAY.
    private static func occurrences(of master: GoogleEvent, start: Date, until windowEnd: Date) -> [Date] {
        guard let line = master.recurrence?.first(where: { $0.uppercased().hasPrefix("RRULE:") }) else { return [start] }
        var rule: [String: String] = [:]
        for pair in line.dropFirst(6).split(separator: ";") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.count == 2 { rule[pieces[0].uppercased()] = pieces[1].uppercased() }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = master.start?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        calendar.firstWeekday = 2
        let interval = max(1, Int(rule["INTERVAL"] ?? "") ?? 1)
        let count = Int(rule["COUNT"] ?? "")
        let until = rule["UNTIL"].flatMap(parseInstanceStamp)
        let limit = min(windowEnd, until ?? .distantFuture)
        var result: [Date] = []
        func emit(_ date: Date) -> Bool {
            if let count, result.count >= count { return false }
            if date > limit { return false }
            result.append(date)
            return result.count < 5_000
        }
        switch rule["FREQ"] {
        case "WEEKLY":
            let codes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
            let days = Set((rule["BYDAY"]?.split(separator: ",") ?? []).compactMap { code in codes[String(code.suffix(2))] })
            let weekdays = days.isEmpty ? [calendar.component(.weekday, from: start)] : Array(days)
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: start)?.start else { return [start] }
            let time = calendar.dateComponents([.hour, .minute, .second], from: start)
            var week = 0
            outer: while true {
                guard let base = calendar.date(byAdding: .weekOfYear, value: week * interval, to: weekStart) else { break }
                if base > limit { break }
                for offset in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: base),
                          weekdays.contains(calendar.component(.weekday, from: day)),
                          let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day),
                          date >= start else { continue }
                    if !emit(date) { break outer }
                }
                week += 1
            }
        default:
            let component: Calendar.Component = switch rule["FREQ"] {
            case "MONTHLY": .month
            case "YEARLY": .year
            default: .day
            }
            var step = 0
            while let date = calendar.date(byAdding: component, value: step * interval, to: start), emit(date) { step += 1 }
        }
        return result
    }
}
