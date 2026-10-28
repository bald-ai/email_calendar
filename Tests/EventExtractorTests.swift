import XCTest
import Foundation
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

/// Live check against OpenAI with the screenshots in Fixtures/EventImages. Skipped unless EC_LIVE_AI=1.
///     EC_LIVE_AI=1 OPENAI_API_KEY=… [EC_AI_MODEL=gpt-6.1-sol] [EC_AI_REASONING=medium] [EC_AI_REPEATS=1] swift test --filter LiveEventExtraction
final class LiveEventExtractionTests: XCTestCase {
    struct Suite: Decodable {
        var now: String
        var timeZone: String
        var calendars: [String]?
        var cases: [Case]
    }
    struct Case: Decodable, Sendable {
        var tier: Int
        var id: String
        var image: String?
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
        enum CodingKeys: String, CodingKey { case tier, id, passed, detail, seconds, cost, servedModel }
    }

    func testFixturesWithLiveModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = environment["EC_AI_MODEL"] ?? "gpt-6.1-sol"
        guard environment["EC_LIVE_AI"] == "1",
              let key = environment[model.hasPrefix("claude-") ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Set EC_LIVE_AI=1 and OPENAI_API_KEY (or ANTHROPIC_API_KEY for claude-…) to run the live extraction check.")
        }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/EventImages")
        let casesFile = environment["EC_AI_CASES"].map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("cases.json")
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: casesFile))
        let calendars = suite.calendars ?? []
        let zone = try XCTUnwrap(TimeZone(identifier: suite.timeZone))
        let now = EventExtractorTests.date(suite.now, in: zone)
        let reasoning = environment["EC_AI_REASONING"] ?? "medium"
        let extractor = EventExtractor(apiKey: key, settings: EventExtractorSettings(model: model, reasoning: reasoning,
                                                                                     serviceTier: environment["EC_AI_TIER"] ?? "default"),
                                       anthropicWorkspaceID: environment["ANTHROPIC_WORKSPACE_ID"])
        let repeats = Int(environment["EC_AI_REPEATS"] ?? "1") ?? 1
        let only = environment["EC_AI_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let cases = suite.cases.filter { only?.contains($0.id) ?? true }

        var outcomes: [Outcome] = []
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var pending = (0..<repeats).flatMap { _ in cases }.makeIterator()
            func next() -> Bool {
                guard let test = pending.next() else { return false }
                group.addTask { await Self.run(test, extractor: extractor, folder: folder, now: now, zone: zone, calendars: calendars) }
                return true
            }
            for _ in 0..<(Int(environment["EC_AI_PARALLEL"] ?? "4") ?? 4) where next() {}
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                _ = next()
            }
        }
        outcomes.sort { ($0.tier, $0.id) < ($1.tier, $1.id) }
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
            try JSONEncoder().encode(outcomes).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(passed, outcomes.count, "Some extractions were wrong; see the report above.")
    }

    private static func run(_ test: Case, extractor: EventExtractor, folder: URL, now: Date, zone: TimeZone, calendars: [String]) async -> Outcome {
        let images = test.image.flatMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }.map { [EventExtractor.Image(data: $0)] } ?? []
        do {
            let result = try await extractor.extract(text: test.text ?? "", images: images, now: now, timeZone: zone, calendars: calendars)
            var problems: [String] = []
            var remaining = result.events
            for expected in test.expect {
                let starts = expected.start.map { EventExtractorTests.date($0, in: zone) }
                guard let index = remaining.firstIndex(where: { starts.contains($0.start) }) else {
                    problems.append("missing start \(expected.start.joined(separator: " or "))"); continue
                }
                let event = remaining.remove(at: index)
                if let end = expected.end, event.end != EventExtractorTests.date(end, in: zone) {
                    problems.append("\(event.title): end \(format(event.end, zone)) ≠ \(end)")
                }
                if let allDay = expected.allDay, event.isAllDay != allDay { problems.append("\(event.title): allDay \(event.isAllDay)") }
                if test.warn == true, event.warnings.isEmpty { problems.append("\(event.title): no warning for an ambiguous source") }
                let rule = event.recurrence.first ?? ""
                if let parts = expected.rrule, !parts.allSatisfy(rule.contains) { problems.append("\(event.title): repeat “\(rule)” lacks \(parts)") }
                if let any = expected.rruleAny, !any.contains(where: rule.contains) { problems.append("\(event.title): repeat “\(rule)” lacks one of \(any)") }
                if expected.once == true, !rule.isEmpty { problems.append("\(event.title): should not repeat (\(rule))") }
                if expected.rrule == nil, expected.rruleAny == nil, expected.once == nil, !rule.isEmpty { problems.append("\(event.title): unexpected repeat \(rule)") }
                if let name = expected.calendar, event.calendar != name { problems.append("\(event.title): calendar \(event.calendar ?? "none") ≠ \(name)") }
                if expected.calendar == nil, let name = event.calendar { problems.append("\(event.title): unasked calendar \(name)") }
                if let minutes = expected.alarm, event.alarmMinutesBefore != minutes { problems.append("\(event.title): alarm \(event.alarmMinutesBefore.map(String.init) ?? "none") ≠ \(minutes)") }
                if expected.alarm == nil, let minutes = event.alarmMinutesBefore { problems.append("\(event.title): unasked alarm \(minutes) min") }
            }
            problems += remaining.map { "extra \($0.title) @ \(format($0.start, zone))" }
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
                           servedModel: result.servedModel, detail: detail + fallback, seconds: result.seconds, usage: result.usage)
        } catch {
            return Outcome(tier: test.tier, id: test.id, passed: false, detail: "error: \(error.localizedDescription)", seconds: 0, usage: .init())
        }
    }

    private static func format(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }
}
