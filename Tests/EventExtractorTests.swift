import XCTest
import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmailCalendarCore

final class EventExtractorTests: XCTestCase {
    private let prague = TimeZone(identifier: "Europe/Prague")!
    private lazy var now = local("2026-10-12T14:00")

    func testRequestUsesSolNormalSpeedMediumReasoning() throws {
        let body = EventExtractor.body(text: "lunch", images: [.init(data: Data([1, 2, 3]))], now: now, timeZone: prague,
                                       settings: EventExtractorSettings())
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(body["service_tier"] as? String, "default")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "medium")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 8192)
        let content = ((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.last?["image_url"] as? String, "data:image/png;base64,AQID")
        XCTAssertTrue((body["instructions"] as? String ?? "").contains("Monday, 12 October 2026, 14:00"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testConvertsSourceZoneAndArrivalZone() throws {
        let webinar = try XCTUnwrap(EventExtractor.resolve(raw(date: "2026-10-20", start: "11:00", end: "12:00", zone: "America/New_York"),
                                                            now: now, timeZone: prague))
        XCTAssertEqual(webinar.start, local("2026-10-20T17:00"))
        XCTAssertEqual(webinar.end, local("2026-10-20T18:00"))
        XCTAssertEqual(webinar.zoneStatus, .converted)
        XCTAssertEqual(webinar.sourceTimeText, "11:00–12:00 New York time (EDT, UTC−4)")
        XCTAssertEqual(webinar.localZoneText, "Prague, UTC+2")
        XCTAssertEqual(webinar.warnings, [])

        var flight = raw(date: "2026-10-24", start: "07:05", end: "08:20", zone: "Europe/Prague")
        flight.end_time_zone = "Europe/London"
        let resolved = try XCTUnwrap(EventExtractor.resolve(flight, now: now, timeZone: prague))
        XCTAssertEqual(resolved.start, local("2026-10-24T07:05"))
        XCTAssertEqual(resolved.end, local("2026-10-24T09:20"))
        XCTAssertEqual(resolved.sourceTimeText, "Starts 07:05 Prague time (UTC+2), ends 08:20 London time (UTC+1)")
    }

    func testFlagsWrongWeekdayOvernightAndPast() throws {
        var planning = raw(date: "2026-11-03", start: "10:00", end: "12:00")
        planning.stated_weekday = "Monday"
        let checked = try XCTUnwrap(EventExtractor.resolve(planning, now: now, timeZone: prague))
        XCTAssertTrue(checked.warnings.contains { $0.contains("is a Tuesday") })

        let overnight = try XCTUnwrap(EventExtractor.resolve(raw(date: "2026-10-31", start: "23:00", end: "02:00"), now: now, timeZone: prague))
        XCTAssertEqual(overnight.end, local("2026-11-01T02:00"))

        let past = try XCTUnwrap(EventExtractor.resolve(raw(date: "2026-10-01", start: "09:00"), now: now, timeZone: prague))
        XCTAssertEqual(past.end, local("2026-10-01T10:00"))
        XCTAssertTrue(past.warnings.contains("This is in the past."))
    }

    func testFlagsUnclearZonesAndClockChanges() throws {
        var call = raw(date: "2026-10-15", start: "14:00")
        call.other_zone_likely = true
        call.time_zone_note = "sender signs from Boston"
        let unclear = try XCTUnwrap(EventExtractor.resolve(call, now: now, timeZone: prague))
        XCTAssertEqual(unclear.zoneStatus, .unclear)
        XCTAssertTrue(unclear.warnings.contains { $0.contains("probably not in your time zone (sender signs from Boston)") })

        // Europe's clocks go back at 03:00 on 25 Oct 2026, so 02:30 happens twice.
        let night = try XCTUnwrap(EventExtractor.resolve(raw(date: "2026-10-25", start: "02:30"), now: now, timeZone: prague))
        XCTAssertTrue(night.warnings.contains { $0.hasPrefix("Clocks change in Prague") })
        let calm = try XCTUnwrap(EventExtractor.resolve(raw(date: "2026-10-15", start: "02:30"), now: now, timeZone: prague))
        XCTAssertEqual(calm.zoneStatus, .local)
        XCTAssertEqual(calm.warnings, [])
    }

    func testEndDateHandlingAroundMidnightAndMissingEndTime() throws {
        // Models often repeat the start date as end_date for a party running past midnight.
        var party = raw(date: "2026-10-24", start: "22:00", end: "02:00", zone: nil)
        party.end_date = "2026-10-24"
        let late = try XCTUnwrap(EventExtractor.resolve(party, now: now, timeZone: prague))
        XCTAssertEqual(late.end, local("2026-10-25T02:00"))

        var workshop = raw(date: "2026-10-22", start: "09:00", end: nil, zone: nil)
        workshop.end_date = "2026-10-24"
        let resolved = try XCTUnwrap(EventExtractor.resolve(workshop, now: now, timeZone: prague))
        XCTAssertTrue(resolved.warnings.contains { $0.contains("no end time") })
    }

    func testAllDayRangeEndsTheDayAfter() throws {
        var festival = raw(date: "2026-10-21", start: nil)
        festival.end_date = "2026-10-25"
        let event = try XCTUnwrap(EventExtractor.resolve(festival, now: now, timeZone: prague))
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.start, local("2026-10-21T00:00"))
        XCTAssertEqual(event.end, local("2026-10-26T00:00"))
    }

    func testParsesResponsesOutputAndErrors() throws {
        let output = #"{"events":[{"title":"Dentist","date":"2026-10-15","start_time":"09:40","end_date":null,"end_time":null,"time_zone":null,"end_time_zone":null,"stated_weekday":"Thursday","location":"Korunní 48","notes":null,"recurrence":"freq=weekly;byday=th;count=3","calendar":"work","alarm_minutes_before":30,"confidence":"high","warnings":[]}],"message":null}"#
        let response: [String: Any] = [
            "status": "completed",
            "usage": ["input_tokens": 1000, "input_tokens_details": ["cached_tokens": 0], "output_tokens": 300,
                      "output_tokens_details": ["reasoning_tokens": 200]],
            "output": [["type": "reasoning"], ["type": "message", "content": [["type": "output_text", "text": output]]]]
        ]
        let result = try EventExtractor.parse(response: JSONSerialization.data(withJSONObject: response), now: now, timeZone: prague)
        let withCalendars = try EventExtractor.parse(response: JSONSerialization.data(withJSONObject: response), now: now, timeZone: prague,
                                                     calendars: ["Personal", "Work"])
        XCTAssertEqual(withCalendars.events.first?.calendar, "Work")
        XCTAssertEqual(withCalendars.events.first?.recurrence, ["RRULE:FREQ=WEEKLY;BYDAY=TH;COUNT=3"])
        XCTAssertEqual(withCalendars.events.first?.alarmMinutesBefore, 30)
        XCTAssertEqual(result.events.map(\.title), ["Dentist"])
        XCTAssertEqual(result.events.first?.start, local("2026-10-15T09:40"))
        XCTAssertEqual(result.events.first?.warnings, [])
        XCTAssertNil(result.events.first?.calendar)   // Calendars are only matched when given.
        XCTAssertEqual(result.usage.reasoningTokens, 200)
        XCTAssertEqual(result.usage.estimatedCost, 0.005, accuracy: 1e-9)

        let incomplete = try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"]])
        XCTAssertThrowsError(try EventExtractor.parse(response: incomplete, now: now, timeZone: prague))
    }

    private func raw(date: String, start: String?, end: String? = nil, zone: String? = nil) -> EventExtractor.RawEvent {
        .init(title: "Event", date: date, start_time: start, end_date: nil, end_time: end, time_zone: zone, end_time_zone: nil,
              time_zone_basis: zone == nil ? "not_given" : "stated", other_zone_likely: false, time_zone_note: nil,
              stated_weekday: nil, location: nil, notes: nil, recurrence: nil, calendar: nil, alarm_minutes_before: nil, confidence: "high", warnings: [])
    }

    private func local(_ value: String) -> Date { Self.date(value, in: prague) }

    /// Parsed the way the app resolves times, so an hour that happens twice (clocks going back) means the same instant.
    static func date(_ value: String, in zone: TimeZone) -> Date {
        let numbers = value.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4]))!
    }
}

/// Live end-to-end extraction benchmark using the production prompt/parser. Skipped unless EC_LIVE_AI=1.
///     EC_LIVE_AI=1 OPENAI_API_KEY=… [EC_AI_MODEL=gpt-6.1-sol] [EC_AI_REASONING=medium] [EC_AI_REPEATS=1] swift test --filter LiveEventExtraction
final class LiveEventExtractionTests: XCTestCase {
    struct Suite: Decodable {
        var version: String
        var now: String
        var timeZone: String
        var calendars: [String]?
        var cases: [Case]
    }
    struct Case: Decodable, Sendable {
        var tier: Int
        var id: String
        var image: String?
        var images: [String]?
        var now: String?
        var timeZone: String?
        var calendars: [String]?
        var imageNames: [String] { (image.map { [$0] } ?? []) + (images ?? []) }
        var text: String?
        var note: String?
        var warn: Bool?
        var expect: [Expected]
    }
    struct Expected: Decodable, Sendable {
        var start: [String]
        var end: String?
        var allDay: Bool?
        /// Every one of these must be in the repeat rule…
        var rrule: [String]?
        /// …and at least one of these (e.g. COUNT=8 or UNTIL=…).
        var rruleAny: [String]?
        /// Must not repeat (separate dates are separate events).
        var once: Bool?
        var calendar: String?
        var alarm: Int?
        var durationMinutes: Int?
        var titleAny: [String]?
        var locationContains: [String]?
        var notesContains: [String]?
        var warningAny: [String]?
        var sourceZone: String?
    }
    struct Outcome: Sendable, Encodable {
        var tier: Int
        var id: String
        var passed: Bool
        var cost = 0.0
        var servedModel: String?
        var detail: String
        var seconds: Double
        var usage: EventExtraction.Usage
        var errorKind: String?
        var attempt = 1
        var actual: [Snapshot] = []
        var inputTokens: Int { usage.inputTokens }
        var cachedTokens: Int { usage.cachedTokens }
        var outputTokens: Int { usage.outputTokens }
        var reasoningTokens: Int { usage.reasoningTokens }
        enum CodingKeys: String, CodingKey { case tier, id, passed, detail, seconds, cost, servedModel, attempt, actual, usage, errorKind }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tier, forKey: .tier); try c.encode(id, forKey: .id)
            try c.encode(passed, forKey: .passed); try c.encode(detail, forKey: .detail)
            try c.encode(seconds, forKey: .seconds); try c.encode(cost, forKey: .cost)
            try c.encodeIfPresent(servedModel, forKey: .servedModel)
            try c.encodeIfPresent(errorKind, forKey: .errorKind)
            try c.encode(attempt, forKey: .attempt); try c.encode(actual, forKey: .actual)
            try c.encode(["input": inputTokens, "cached": cachedTokens, "output": outputTokens,
                          "reasoning": reasoningTokens], forKey: .usage)
        }
    }
    struct Snapshot: Sendable, Encodable {
        var title, start, end, location, notes: String
        var allDay: Bool
        var warnings, recurrence: [String]
        var calendar, sourceZone: String?
        var alarm: Int?
        init(_ e: ExtractedEvent) {
            title = e.title; start = e.start.ISO8601Format(); end = e.end.ISO8601Format()
            location = e.location; notes = e.notes; allDay = e.isAllDay
            warnings = e.warnings; recurrence = e.recurrence; calendar = e.calendar
            sourceZone = e.sourceTimeZone?.identifier; alarm = e.alarmMinutesBefore
        }
    }
    struct Report: Encodable {
        var schemaVersion = 2
        var suiteVersion, fingerprint, model, reasoning, serviceTier, createdAt: String
        var repeats, parallelism: Int
        var caseIDs: [String]
        var outcomes: [Outcome]
    }
    enum ConfigurationError: Error { case invalid(String) }

    static func validate(_ suite: Suite, folder: URL) throws {
        guard !suite.cases.isEmpty, Set(suite.cases.map(\.id)).count == suite.cases.count,
              TimeZone(identifier: suite.timeZone) != nil else {
            throw ConfigurationError.invalid("Empty suite, duplicate IDs or invalid time zone")
        }
        for test in suite.cases {
            guard !(test.text ?? "").isEmpty || !test.imageNames.isEmpty,
                  test.timeZone == nil || TimeZone(identifier: test.timeZone!) != nil else {
                throw ConfigurationError.invalid("Invalid input/context: \(test.id)")
            }
            for name in test.imageNames {
                guard !name.contains("/"), !(try Data(contentsOf: folder.appendingPathComponent(name))).isEmpty else {
                    throw ConfigurationError.invalid("Missing image: \(name)")
                }
            }
            for expected in test.expect {
                guard !expected.start.isEmpty, expected.allDay != nil,
                      expected.end != nil || expected.durationMinutes != nil else {
                    throw ConfigurationError.invalid("Incomplete expected event: \(test.id)")
                }
            }
        }
    }

    func testFixturesWithLiveModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EC_LIVE_AI"] == "1" else { throw XCTSkip("Live model benchmark is opt-in.") }
        guard let model = environment["EC_AI_MODEL"], !model.isEmpty,
              let key = environment[model.hasPrefix("claude-") ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"], !key.isEmpty else {
            throw ConfigurationError.invalid("Choose EC_AI_MODEL and provide its API key")
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/EventImages")
        let casesFile = environment["EC_AI_CASES"].map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("cases.json")
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: casesFile))
        try Self.validate(suite, folder: folder)
        let calendars = suite.calendars ?? []
        let zone = try XCTUnwrap(TimeZone(identifier: suite.timeZone))
        let now = EventExtractorTests.date(suite.now, in: zone)
        let reasoning = environment["EC_AI_REASONING"] ?? "medium"
        let extractor = EventExtractor(apiKey: key, settings: EventExtractorSettings(model: model, reasoning: reasoning,
                                                                                     serviceTier: environment["EC_AI_TIER"] ?? "default"),
                                       anthropicWorkspaceID: environment["ANTHROPIC_WORKSPACE_ID"])
        guard let repeats = Int(environment["EC_AI_REPEATS"] ?? "3"), repeats > 0,
              let parallelism = Int(environment["EC_AI_PARALLEL"] ?? "1"), parallelism > 0 else {
            throw ConfigurationError.invalid("Repeats and parallelism must be positive integers")
        }
        let only = environment["EC_AI_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let cases = suite.cases.filter { only?.contains($0.id) ?? true }
        guard !cases.isEmpty, only == nil || only!.isSubset(of: Set(suite.cases.map(\.id))) else {
            throw ConfigurationError.invalid("EC_AI_ONLY contains unknown IDs or selects no cases")
        }
        // Bind comparisons to exact fixtures AND production/scoring source, not just a date label.
        var digest = SHA256()
        for file in [casesFile] + Set(cases.flatMap(\.imageNames)).sorted().map({ folder.appendingPathComponent($0) })
            + [URL(fileURLWithPath: #filePath), folder.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("EmailCalendar/Services/EventExtractor.swift")] {
            digest.update(data: try Data(contentsOf: file))
        }
        let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()

        var outcomes: [Outcome] = []
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var pending = (1...repeats).flatMap { attempt in cases.map { (attempt, $0) } }.makeIterator()
            func next() -> Bool {
                guard let (attempt, test) = pending.next() else { return false }
                group.addTask {
                    let contextZone = test.timeZone.flatMap(TimeZone.init(identifier:)) ?? zone
                    let contextNow = test.now.map { EventExtractorTests.date($0, in: contextZone) } ?? now
                    var outcome = await Self.run(test, extractor: extractor, folder: folder, now: contextNow,
                                                 zone: contextZone, calendars: test.calendars ?? calendars)
                    outcome.attempt = attempt
                    return outcome
                }
                return true
            }
            for _ in 0..<parallelism where next() {}
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                if let path = environment["EC_AI_PROGRESS"] {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    var line = try encoder.encode(outcome); line.append(0x0a)
                    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                    try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close()
                }
                _ = next()
            }
        }
        outcomes.sort { ($0.tier, $0.id, $0.attempt) < ($1.tier, $1.id, $1.attempt) }
        let passed = outcomes.filter(\.passed).count
        let cost = outcomes.reduce(0) { $0 + $1.usage.estimatedCost }
        let seconds = outcomes.map(\.seconds).sorted()
        var report = "## \(model) · \(reasoning)\(model.hasPrefix("claude-") ? "" : " · " + extractor.settings.serviceTier)\n\n"
        report += "\(passed)/\(outcomes.count) passed · median \(String(format: "%.1f", seconds[seconds.count / 2]))s"
        report += " · max \(String(format: "%.1f", seconds.last ?? 0))s · ~$\(String(format: "%.3f", cost)) total\n\n"
        for tier in Set(outcomes.map(\.tier)).sorted() {
            let inTier = outcomes.filter { $0.tier == tier }
            report += "Tier \(tier): \(inTier.filter(\.passed).count)/\(inTier.count)\n"
        }
        report += "\n| Case | Result | Time | Reasoning tokens | Detail |\n| --- | --- | --- | --- | --- |\n"
        for outcome in outcomes {
            report += "| \(outcome.id) | \(outcome.passed ? "✅" : "❌") | \(String(format: "%.1f", outcome.seconds))s | \(outcome.usage.reasoningTokens) | \(outcome.detail.replacingOccurrences(of: "|", with: "/")) |\n"
        }
        print(report)
        if let path = environment["EC_AI_REPORT"] { try report.write(toFile: path, atomically: true, encoding: .utf8) }
        if let path = environment["EC_AI_JSON"] {
            let record = Report(suiteVersion: suite.version, fingerprint: fingerprint, model: model,
                                reasoning: reasoning, serviceTier: extractor.settings.serviceTier,
                                createdAt: Date.now.ISO8601Format(), repeats: repeats, parallelism: parallelism,
                                caseIDs: cases.map(\.id).sorted(), outcomes: outcomes)
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url)
        }
        XCTAssertEqual(passed, outcomes.count, "Some extractions were wrong; see the report above.")
    }

    private static func run(_ test: Case, extractor: EventExtractor, folder: URL, now: Date, zone: TimeZone, calendars: [String]) async -> Outcome {
        let started = Date.now
        do {
            let images = try test.imageNames.map { EventExtractor.Image(data: try Data(contentsOf: folder.appendingPathComponent($0))) }
            let result = try await extractor.extract(text: test.text ?? "", images: images, now: now, timeZone: zone, calendars: calendars)
            let problems = grade(test, events: result.events, message: result.message, zone: zone)
            let summary = result.events.map { event in
                let extras = [event.sourceTimeText.map { " 🌐 \($0)" }, event.zoneNote.map { " (\($0))" },
                              event.recurrence.first.map { " ↻ \($0.dropFirst(6))" }, event.calendar.map { " 📅 \($0)" },
                              event.alarmMinutesBefore.map { " ⏰ \($0)m" }].compactMap { $0 }.joined()
                let warnings = extras + (event.warnings.isEmpty ? "" : " ⚠︎ " + event.warnings.joined(separator: "; "))
                    + (event.info.isEmpty ? "" : " ℹ︎ " + event.info.joined(separator: "; "))
                return "\(event.title) \(format(event.start, zone))–\(format(event.end, zone))\(warnings)"
            }.joined(separator: " · ")
            let detail = problems.isEmpty ? (summary.isEmpty ? (result.message ?? "no events") : summary)
                : problems.joined(separator: "; ") + " ⟵ got: " + (summary.isEmpty ? "nothing (\(result.message ?? "no message"))" : summary)
            let fallback = result.servedModel.flatMap { $0 == extractor.settings.model ? nil : " [answered by \($0)]" } ?? ""
            return Outcome(tier: test.tier, id: test.id, passed: problems.isEmpty, cost: result.usage.estimatedCost,
                           servedModel: result.servedModel, detail: detail + fallback, seconds: result.seconds, usage: result.usage, actual: result.events.map(Snapshot.init))
        } catch {
            let kind: String
            switch error {
            case EventExtractorError.http: kind = "api"
            case EventExtractorError.incomplete: kind = "truncated"
            case EventExtractorError.refused: kind = "refused"
            case EventExtractorError.invalidOutput: kind = "invalid_output"
            default: kind = "transport_or_configuration"
            }
            let detail = error.localizedDescription.replacingOccurrences(of: extractor.apiKey, with: "[redacted]")
            return Outcome(tier: test.tier, id: test.id, passed: false, detail: "error: \(detail)",
                           seconds: Date.now.timeIntervalSince(started), usage: .init(), errorKind: kind)
        }
    }

    static func contains(_ text: String, _ fragment: String) -> Bool {
        text.range(of: fragment, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    static func ruleHas(_ rule: String, _ expected: String) -> Bool {
        let wanted = expected.uppercased().split(separator: "=", maxSplits: 1).map(String.init)
        guard wanted.count == 2 else { return false }
        let parts = rule.uppercased().replacingOccurrences(of: "RRULE:", with: "").split(separator: ";")
        return parts.contains { part in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 && pair[0] == wanted[0]
                && Set(pair[1].split(separator: ",")) == Set(wanted[1].split(separator: ","))
        }
    }
    static func fieldProblems(_ expected: Expected, event: ExtractedEvent, zone: TimeZone) -> [String] {
        var problems: [String] = []
        if event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || event.title == "Untitled event" {
            problems.append("empty/generic title")
        }
        if let minutes = expected.durationMinutes, abs(event.end.timeIntervalSince(event.start) - Double(minutes * 60)) > 0.5 {
            problems.append("\(event.title): wrong duration")
        }
        for (label, text, fragments) in [("location", event.location, expected.locationContains), ("notes", event.notes, expected.notesContains)] {
            if let fragments, !fragments.allSatisfy({ contains(text, $0) }) { problems.append("\(event.title): missing \(label) details \(fragments)") }
        }
        if let alternatives = expected.titleAny, !alternatives.contains(where: { contains(event.title, $0) }) { problems.append("wrong title: \(event.title)") }
        if let alternatives = expected.warningAny, !alternatives.contains(where: { contains(event.warnings.joined(separator: " "), $0) }) {
            problems.append("\(event.title): missing relevant warning")
        }
        if let zone = expected.sourceZone, event.sourceTimeZone?.identifier != zone { problems.append("\(event.title): wrong source zone") }
        if let end = expected.end, event.end != EventExtractorTests.date(end, in: zone) {
            problems.append("\(event.title): end \(format(event.end, zone)) ≠ \(end)")
        }
        if let allDay = expected.allDay, event.isAllDay != allDay { problems.append("\(event.title): allDay \(event.isAllDay)") }
        let rule = event.recurrence.first ?? ""
        if let parts = expected.rrule, !parts.allSatisfy({ ruleHas(rule, $0) }) { problems.append("\(event.title): repeat “\(rule)” lacks \(parts)") }
        if let any = expected.rruleAny, !any.contains(where: { ruleHas(rule, $0) }) { problems.append("\(event.title): repeat “\(rule)” lacks one of \(any)") }
        if expected.once == true, !rule.isEmpty { problems.append("\(event.title): should not repeat (\(rule))") }
        if expected.rrule == nil, expected.rruleAny == nil, expected.once == nil, !rule.isEmpty { problems.append("\(event.title): unexpected repeat \(rule)") }
        if let name = expected.calendar, event.calendar != name { problems.append("\(event.title): calendar \(event.calendar ?? "none") ≠ \(name)") }
        if expected.calendar == nil, let name = event.calendar { problems.append("\(event.title): unasked calendar \(name)") }
        if let minutes = expected.alarm, event.alarmMinutesBefore != minutes { problems.append("\(event.title): alarm \(event.alarmMinutesBefore.map(String.init) ?? "none") ≠ \(minutes)") }
        if expected.alarm == nil, let minutes = event.alarmMinutesBefore { problems.append("\(event.title): unasked alarm \(minutes) min") }
        return problems
    }
    static func grade(_ test: Case, events: [ExtractedEvent], message: String?, zone: TimeZone) -> [String] {
        var problems: [String] = []
        var remaining = events
        for expected in test.expect {
            let starts = expected.start.map { EventExtractorTests.date($0, in: zone) }
            let candidates = remaining.indices.filter { starts.contains(remaining[$0].start) }
            guard let index = candidates.min(by: {
                fieldProblems(expected, event: remaining[$0], zone: zone).count < fieldProblems(expected, event: remaining[$1], zone: zone).count
            }) else {
                problems.append("missing start \(expected.start.joined(separator: " or "))"); continue
            }
            let event = remaining.remove(at: index)
            problems += fieldProblems(expected, event: event, zone: zone)
            if test.warn == true, event.warnings.isEmpty { problems.append("\(event.title): no warning for an ambiguous source") }

        }
        problems += remaining.map { "extra \($0.title) @ \(format($0.start, zone))" }

        if test.expect.isEmpty && (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("No explanation for no-event input")
        }
        return problems
    }

    private static func format(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }
}

/// The scorer must fail bad outputs without making any model calls.
final class EventBenchmarkValidationTests: XCTestCase {
    typealias Benchmark = LiveEventExtractionTests
    let zone = TimeZone(identifier: "Europe/Prague")!
    var folder: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/EventImages") }
    func suite() throws -> Benchmark.Suite {
        try JSONDecoder().decode(Benchmark.Suite.self, from: Data(contentsOf: folder.appendingPathComponent("cases.json")))
    }
    func fixture(_ id: String) throws -> Benchmark.Case { try XCTUnwrap(try suite().cases.first { $0.id == id }) }
    func event(_ expected: Benchmark.Expected, title: String = "Appointment") -> ExtractedEvent {
        let start = EventExtractorTests.date(expected.start[0], in: zone)
        return ExtractedEvent(title: title, start: start,
                              end: expected.end.map { EventExtractorTests.date($0, in: zone) }
                                ?? start.addingTimeInterval(Double((expected.durationMinutes ?? 60) * 60)),
                              isAllDay: expected.allDay ?? false, location: "", notes: "", sourceTimeZone: nil,
                              confidence: "high", warnings: [])
    }
    func testAllFixturesHaveInputsAndCompleteExpectations() throws {
        let suite = try suite()
        try Benchmark.validate(suite, folder: folder)
        for test in suite.cases {
            let contextZone = test.timeZone.flatMap(TimeZone.init(identifier:)) ?? zone
            for e in test.expect {
                for start in e.start {
                    let date = EventExtractorTests.date(start, in: contextZone)
                    let formatter = DateFormatter(); formatter.timeZone = contextZone; formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
                    XCTAssertEqual(formatter.string(from: date), start, test.id)
                    if let end = e.end { XCTAssertGreaterThan(EventExtractorTests.date(end, in: contextZone), date, test.id) }
                }
            }
        }
    }
    func testRecurrenceTokensCannotPassByPrefixOrDaySubstring() {
        XCTAssertFalse(Benchmark.ruleHas("RRULE:FREQ=WEEKLY;COUNT=80", "COUNT=8"))
        XCTAssertFalse(Benchmark.ruleHas("RRULE:FREQ=WEEKLY;UNTIL=20261209", "UNTIL=20261208"))
        XCTAssertFalse(Benchmark.ruleHas("RRULE:FREQ=WEEKLY;BYDAY=TU,TH", "BYDAY=TU"))
        XCTAssertTrue(Benchmark.ruleHas("RRULE:FREQ=WEEKLY;BYDAY=FR,MO,TU,WE,TH", "BYDAY=MO,TU,WE,TH,FR"))
    }
    func testRejectsWrongDurationAllDayAndUnrequestedControls() throws {
        let test = try fixture("text_iso")
        var output = event(test.expect[0], title: "Board meeting")
        XCTAssertTrue(Benchmark.grade(test, events: [output], message: nil, zone: zone).isEmpty)
        output.end = output.start.addingTimeInterval(60)
        output.isAllDay = true; output.calendar = "Work"; output.alarmMinutesBefore = 0
        XCTAssertEqual(Benchmark.grade(test, events: [output], message: nil, zone: zone).count, 4)
    }
    func testUnrelatedWarningDoesNotSatisfyAmbiguity() throws {
        let test = try fixture("text_cst_ambiguous")
        var output = event(test.expect[0]); output.warnings = ["This is in the past."]
        XCTAssertFalse(Benchmark.grade(test, events: [output], message: nil, zone: zone).isEmpty)
        output.warnings = ["CST can mean China or US Central; check the zone."]
        XCTAssertTrue(Benchmark.grade(test, events: [output], message: nil, zone: zone).isEmpty)
    }
    func testSimultaneousEventsMatchIndependentOfOutputOrder() throws {
        let test = try fixture("same_start_distinct_events")
        var yoga = event(test.expect[0], title: "Yoga"); yoga.location = "Studio A"
        var piano = event(test.expect[1], title: "Piano"); piano.location = "Room B"
        XCTAssertTrue(Benchmark.grade(test, events: [piano, yoga], message: nil, zone: zone).isEmpty)
        XCTAssertFalse(Benchmark.grade(test, events: [piano, piano], message: nil, zone: zone).isEmpty)
    }
    func testNoEventRequiresExplanationAndRejectsHallucinatedEvent() throws {
        let test = try fixture("cancelled_without_replacement")
        XCTAssertFalse(Benchmark.grade(test, events: [], message: nil, zone: zone).isEmpty)
        XCTAssertTrue(Benchmark.grade(test, events: [], message: "The meeting was cancelled.", zone: zone).isEmpty)
        let other = try fixture("text_iso")
        XCTAssertFalse(Benchmark.grade(test, events: [event(other.expect[0])], message: "Cancelled", zone: zone).isEmpty)
    }
    func testMissingImageFailsPreflightInsteadOfBecomingTextOnly() throws {
        var suite = try suite(); suite.cases[0].image = "missing-fixture.png"
        XCTAssertThrowsError(try Benchmark.validate(suite, folder: folder))
    }
    func testPreservesServedOpenAIModelAndTerraPricing() throws {
        let response: [String: Any] = ["status": "completed", "model": "gpt-6.1-terra",
            "output": [["type": "message", "content": [["type": "output_text", "text": "{\"events\":[],\"message\":\"No event\"}"]]]]]
        let result = try EventExtractor.parse(response: JSONSerialization.data(withJSONObject: response), now: .now, timeZone: zone)
        XCTAssertEqual(result.servedModel, "gpt-6.1-terra")
        XCTAssertEqual(EventExtractorSettings(model: "gpt-6.1-terra").rates.input, 1)
        XCTAssertEqual(EventExtractorSettings(model: "gpt-6.1-terra").rates.output, 5)
    }
}
