import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EmailCalendarCore

private final class RegressionRegistry: @unchecked Sendable {
    let lock = NSLock()
    private var handlers: [String: RegressionTransport] = [:]
    func set(_ value: RegressionTransport?, token: String) { lock.withLock { handlers[token] = value } }
    func get(_ token: String) -> RegressionTransport? { lock.withLock { handlers[token] } }
}

private final class RegressionTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    let response: @Sendable (URLRequest) -> (Int, Data)
    init(_ response: @escaping @Sendable (URLRequest) -> (Int, Data)) { self.response = response }
    func handle(_ request: URLRequest) -> (Int, Data) {
        lock.withLock { requests.append(request) }
        return response(request)
    }
    func recorded() -> [URLRequest] { lock.withLock { requests } }
}

private final class RegressionProtocol: URLProtocol, @unchecked Sendable {
    static let registry = RegressionRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request.withMaterializedBody()
        let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        guard let fixture = Self.registry.get(token), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let (status, data) = fixture.handle(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RegressionToken: GoogleTokenProvider {
    let value: String
    private var count = 0
    private var pauseAt: Int?
    private var delay: Duration
    var started = false
    init(_ value: String, pauseAt: Int? = nil, delay: Duration = .milliseconds(200)) {
        self.value = value; self.pauseAt = pauseAt; self.delay = delay
    }
    func pauseNext(delay: Duration) { pauseAt = count + 1; self.delay = delay; started = false }
    func accessToken(forceRefresh: Bool) async throws -> String {
        count += 1
        if count == pauseAt { started = true; try await Task.sleep(for: delay) }
        return value
    }
}

private struct RegressionContext {
    let store: LocalStore
    let api: GoogleAPI
    let token: RegressionToken
    let transport: RegressionTransport
    let directory: URL
    let session: URLSession
    let key: String
    init(pauseAt: Int? = nil, response: @escaping @Sendable (URLRequest) -> (Int, Data)) throws {
        key = UUID().uuidString
        token = RegressionToken(key, pauseAt: pauseAt)
        transport = RegressionTransport(response)
        RegressionProtocol.registry.set(transport, token: key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegressionProtocol.self]
        session = URLSession(configuration: configuration)
        api = GoogleAPI(auth: token, session: session)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ECRegression-" + key)
        store = try LocalStore(url: directory.appendingPathComponent("cache.sqlite"))
    }
    func cleanup() {
        session.invalidateAndCancel()
        RegressionProtocol.registry.set(nil, token: key)
        try? FileManager.default.removeItem(at: directory)
    }
    func prepareMail(_ account: Account) async throws {
        try await store.setMetadata(["INBOX": "INBOX", "UNREAD": "UNREAD", "aside": "HEY/Set Aside", "screen": "HEY/Screener"], key: "mailLabels", accountID: account.id)
        try await store.setMetadata([String: String](), key: "draftIDs", accountID: account.id)
    }
}

private func json(_ text: String) -> (Int, Data) { (200, Data(text.utf8)) }

@Suite("Calendar and extraction regressions")
struct CalendarRegressions {
    private let prague = TimeZone(identifier: "Europe/Prague")!
    private func raw(_ date: String, start: String? = "09:00", zone: String? = nil) -> EventExtractor.RawEvent {
        .init(title: "Meeting", date: date, start_time: start, end_date: nil, end_time: nil,
              time_zone: zone, end_time_zone: nil, time_zone_basis: zone == nil ? "not_given" : "stated",
              other_zone_likely: false, time_zone_note: nil, stated_weekday: nil, location: nil, notes: nil,
              recurrence: nil, calendar: nil, alarm_minutes_before: nil, confidence: "high", warnings: [])
    }

    @Test func rejectsImpossibleDatesAndTimes() throws {
        for date in ["2026-02-30", "2026-04-31", "2026-13-01", "0000-01-01"] {
            #expect(EventExtractor.resolve(raw(date), now: .now, timeZone: prague) == nil)
        }
        var event = raw("2026-10-12")
        event.end_date = "2026-02-30"
        #expect(EventExtractor.resolve(event, now: .now, timeZone: prague) == nil)
        event = raw("2026-10-12", start: "24:15")
        #expect(EventExtractor.resolve(event, now: .now, timeZone: prague) == nil)
        event = raw("2026-10-12", start: nil); event.end_date = "2026-10-11"
        #expect(EventExtractor.resolve(event, now: .now, timeZone: prague) == nil)
        #expect(EventExtractor.resolve(raw("2028-02-29"), now: .now, timeZone: prague) != nil)
        let output = #"{"events":[{"title":"Bad date","date":"2026-02-30","start_time":"09:00","confidence":"high","warnings":[]}],"message":null}"#
        let envelope: [String: Any] = ["output": [["type": "message", "content": [["type": "output_text", "text": output]]]]]
        #expect(throws: EventExtractorError.self) {
            _ = try EventExtractor.parse(response: JSONSerialization.data(withJSONObject: envelope), now: .now, timeZone: prague)
        }
    }

    @Test func retainsRecurrenceZoneIncludingMatchingOffsets() throws {
        var source = raw("2026-10-13", zone: "America/New_York")
        source.recurrence = "FREQ=WEEKLY;BYDAY=TU;COUNT=5"
        let found = try #require(EventExtractor.resolve(source, now: .now, timeZone: prague))
        let payload = try CalendarService.googleEvent(from: found.calendarEvent(in: CalendarRecord(id: "main", accountID: "owner", title: "Main")))
        #expect(payload.start?.timeZone == "America/New_York")
        #expect(CalendarService.date(payload.start) == found.start)
        let stored = MockEvent(calendarID: "main", event: payload, version: 1)
        let instances = MockRecurrence.instances(of: stored,
            from: CalendarService.date(GoogleEventDateTime(dateTime: "2026-10-26T00:00:00Z"))!,
            to: CalendarService.date(GoogleEventDateTime(dateTime: "2026-10-28T00:00:00Z"))!)
        #expect(CalendarService.date(instances.first?.start) == CalendarService.date(GoogleEventDateTime(dateTime: "2026-10-27T13:00:00Z")))
        let sameOffset = try #require(EventExtractor.resolve(raw("2026-10-13", zone: "Africa/Johannesburg"), now: .now, timeZone: prague))
        #expect(sameOffset.sourceTimeZone?.identifier == "Africa/Johannesburg")
    }

    @Test func allDayMovesPreserveDaysAcrossBothClockChanges() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = prague
        for (from, to) in [("2027-03-28", "2027-03-30"), ("2026-10-25", "2026-10-27"), ("2027-03-30", "2027-03-28")] {
            for count in [1, 3] {
                var found = try #require(EventExtractor.resolve(raw(from, start: nil), now: .now, timeZone: prague))
                found.end = calendar.date(byAdding: .day, value: count, to: found.start)!
                found.moveStart(to: CalendarDates.day(to, calendar: calendar)!, calendar: calendar)
                #expect(calendar.dateComponents([.day], from: found.start, to: found.end).day == count)
                #expect(calendar.component(.hour, from: found.end) == 0)
            }
        }
    }

    @Test func reminderChoiceIsSharedWithBulkAddition() throws {
        var found = try #require(EventExtractor.resolve(raw("2026-10-13"), now: .now, timeZone: prague))
        found.alarmMinutesBefore = 30
        #expect(found.shouldSetAlarm)
        found.wantsAlarm = false
        #expect(!found.shouldSetAlarm)
        found.wantsAlarm = true
        #expect([found].filter(\.shouldSetAlarm).count == 1)
    }

    @Test func untilDatesUseInclusiveCutoffsInTheRecurrenceZone() throws {
        #expect(RepeatRule.forEvent("RRULE:FREQ=WEEKLY;UNTIL=20261027", isAllDay: false, timeZone: prague)
                == "RRULE:FREQ=WEEKLY;UNTIL=20261027T225959Z")
        #expect(RepeatRule.forEvent("RRULE:FREQ=WEEKLY;UNTIL=20261027", isAllDay: false, timeZone: TimeZone(identifier: "America/New_York")!)
                == "RRULE:FREQ=WEEKLY;UNTIL=20261028T035959Z")
        #expect(RepeatRule.forEvent("RRULE:FREQ=WEEKLY;UNTIL=20261027", isAllDay: true, timeZone: prague)
                == "RRULE:FREQ=WEEKLY;UNTIL=20261027")
        #expect(RepeatRule.forEvent("RRULE:FREQ=DAILY;UNTIL=20260230", isAllDay: false, timeZone: prague) == nil)
        #expect(RepeatRule.forEvent("RRULE:FREQ=DAILY;COUNT=3;UNTIL=20261027", isAllDay: false, timeZone: prague) == nil)
        for cutoff in ["20260230T100000Z", "20261027T250000Z", "20261301T100000Z"] {
            #expect(RepeatRule.forEvent("RRULE:FREQ=DAILY;UNTIL=" + cutoff, isAllDay: false, timeZone: prague) == nil)
            #expect(RepeatRule.forEvent("RRULE:FREQ=DAILY;UNTIL=" + cutoff, isAllDay: true, timeZone: prague) == nil)
        }
    }

    @Test func distantWeekNavigationIncludesTheRequestedDate() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = prague; calendar.firstWeekday = 2
        for months in [-8, 6, 18] {
            let target = calendar.date(byAdding: .month, value: months, to: .now)!
            let days = CalendarNavigation.timelineDays(around: target, calendar: calendar)
            let week = calendar.dateInterval(of: .weekOfYear, for: target)!.start
            #expect(CalendarNavigation.monthWeeks(around: target, calendar: calendar).contains(week))
            #expect(days.count == 182)
            #expect(days.contains(week))
            #expect(days.contains { calendar.isDate($0, inSameDayAs: target) })
        }
    }

    @Test func dayIndexMatchesOverlapsAndExclusiveEnds() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = prague
        let start = CalendarDates.day("2027-03-27", calendar: calendar)!
        let end = calendar.date(byAdding: .day, value: 3, to: start)!
        let events = [CalendarEvent(id: "trip", calendarID: "main", accountID: "owner", start: start, end: end, isAllDay: true),
                      CalendarEvent(id: "night", calendarID: "main", accountID: "owner", start: start.addingTimeInterval(23 * 3600), end: start.addingTimeInterval(26 * 3600))]
        let index = EventDayIndex(events, calendar: calendar)
        for offset in 0...4 {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let expected = events.filter { $0.start < next && $0.end > day }.map(\.id)
            #expect(Set(index.events(on: day).map(\.id)) == Set(expected))
        }
        #expect(index.events(on: end).isEmpty)
    }

    @Test func dayIndexIncludesFractionalSecondOverlapsAfterMidnight() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = prague
        let midnight = CalendarDates.day("2026-10-13", calendar: calendar)!
        let crossing = CalendarEvent(id: "crossing", calendarID: "main", accountID: "owner",
                                     start: midnight.addingTimeInterval(-60), end: midnight.addingTimeInterval(0.5))
        var exclusive = crossing; exclusive.id = "exclusive"; exclusive.end = midnight
        var invalid = crossing; invalid.id = "invalid"; invalid.end = invalid.start
        let index = EventDayIndex([crossing, exclusive, invalid], calendar: calendar)
        #expect(index.events(on: midnight).map(\.id) == [crossing.id])
        #expect(Set(index.events(on: midnight.addingTimeInterval(-60)).map(\.id)) == [crossing.id, exclusive.id])
    }
}

private actor DraftSaveRecorder {
    var values: [OutgoingMessage] = []
    var started = false
    func save(_ value: OutgoingMessage) async throws -> OutgoingMessage {
        values.append(value); started = true
        if values.count == 1 { try await Task.sleep(for: .milliseconds(30)) }
        var result = value; result.draftID = "one-draft"
        return result
    }
}

@Suite("Draft and action lifecycle regressions")
struct LifecycleRegressions {
    @Test @MainActor func pastedRecipientsWithQuotedNamesCanBeSent() throws {
        let session = DraftSession(message: OutgoingMessage())
        session.to = #""Doe, Jane" <jane@example.com>; "Operations; Europe" <ops@example.com>, plain@example.com"#
        #expect(session.outgoing.to.count == 3)
        let raw = try MIMEComposer.compose(session.outgoing, from: "owner@example.com")
        let source = String(decoding: raw, as: UTF8.self)
        #expect(source.contains(#""Doe, Jane" <jane@example.com>"#))
        #expect(source.contains(#""Operations; Europe" <ops@example.com>"#))
        #expect(MailMapping.addresses(session.outgoing.to.joined(separator: ",")).map(\.email)
                == ["jane@example.com", "ops@example.com", "plain@example.com"])
    }

    @Test @MainActor func sendClaimsTheSessionBeforeWaitingForAnAutosave() async throws {
        let recorder = DraftSaveRecorder()
        let session = DraftSession(message: OutgoingMessage(to: ["person@example.com"], body: "First"), delay: .seconds(10))
        var sent: [OutgoingMessage] = []
        session.configure(save: { try await recorder.save($0) }, send: { sent.append($0) })
        let flush = Task { try await session.flush() }
        while !(await recorder.started) { await Task.yield() }
        session.message.body = "Final version"
        let send = Task { try await session.send() }
        await Task.yield()
        #expect(session.isSending)
        let duplicate = Task { try await session.send() }
        try await send.value
        try await duplicate.value
        try await flush.value
        try await session.flush()
        #expect(sent.count == 1)
        #expect(sent.first?.body == "Final version")
        #expect(sent.first?.draftID == "one-draft")
        #expect(await recorder.values.count == 1)
        session.message.body = "Late change from a dismissed editor"
        try await session.flush()
        try await session.send()
        #expect(await recorder.values.count == 1)
        #expect(sent.count == 1)
        session.cancel()
    }

    @Test @MainActor func clearingAnExistingDraftPersistsTheEmptyBuffer() async throws {
        let recorder = DraftSaveRecorder()
        let session = DraftSession(message: OutgoingMessage(to: ["person@example.com"], body: "Old", draftID: "one-draft"), delay: .seconds(10))
        session.configure(save: { try await recorder.save($0) }, send: { _ in })
        session.to = ""; session.message.body = ""
        try await session.flush()
        #expect(await recorder.values.last?.body == "")
        #expect(await recorder.values.last?.to.isEmpty == true)
        #expect(await recorder.values.last?.draftID == "one-draft")
        session.cancel()
    }

    @Test @MainActor func cancelledDraftCannotRestartWork() async throws {
        let session = DraftSession(message: OutgoingMessage(to: ["person@example.com"], body: "Old"), delay: .seconds(10))
        var saves = 0, sends = 0
        session.configure(save: { value in saves += 1; return value }, send: { _ in sends += 1 })
        session.cancel()
        session.message.body = "Late attachment callback"
        await #expect(throws: CancellationError.self) { try await session.flush() }
        await #expect(throws: CancellationError.self) { try await session.send() }
        #expect(saves == 0 && sends == 0)
    }

    @Test @MainActor func autosaveSurvivesLossOfTheViewOwner() async throws {
        let recorder = DraftSaveRecorder()
        let session = DraftSession(message: OutgoingMessage(), delay: .milliseconds(5))
        session.configure(save: { try await recorder.save($0) }, send: { _ in })
        session.to = "person@example.com"
        session.message.subject = "Keep this"
        session.message.body = "Typed immediately before navigating away"
        // No view owns or schedules this save; the retained session completes it.
        try await Task.sleep(for: .milliseconds(50))
        try await session.flush()
        let values = await recorder.values
        #expect(values.last?.body == session.outgoing.body)
        #expect(values.last?.to == ["person@example.com"])
        #expect(session.message.draftID == "one-draft")
    }

    @Test @MainActor func editsDuringSaveAreFlushedToTheSameDraft() async throws {
        let recorder = DraftSaveRecorder()
        let session = DraftSession(message: OutgoingMessage(to: ["person@example.com"], body: "First"), delay: .seconds(10))
        session.configure(save: { try await recorder.save($0) }, send: { _ in })
        let firstFlush = Task { try await session.flush() }
        while !(await recorder.started) { await Task.yield() }
        session.message.body = "Second version"
        session.cc = "other@example.com"
        try await firstFlush.value
        let values = await recorder.values
        #expect(values.count == 2)
        #expect(values.first?.draftID == nil)
        #expect(values.last?.draftID == "one-draft")
        #expect(values.last?.body == "Second version")
        #expect(values.last?.cc == ["other@example.com"])
        session.cancel()
    }

    @Test @MainActor func pendingProposalRejectsSecondClickAndAllowsRetry() {
        let state = ProposalAddState(), id = UUID()
        #expect(state.begin(id))
        #expect(!state.begin(id))
        #expect(state.pending == [id])
        state.finish(id)
        #expect(state.begin(id))
    }

    @Test @MainActor func restartWaitsForLaunchAndDoesNotQuitAfterFailure() async throws {
        var order: [String] = []
        let task = Task {
            try await ApplicationRestart.perform(launch: {
                order.append("starting")
                try await Task.sleep(for: .milliseconds(20))
                order.append("launched")
            }, terminate: { order.append("terminated") })
        }
        while order.isEmpty { await Task.yield() }
        #expect(order == ["starting"])
        try await task.value
        #expect(order == ["starting", "launched", "terminated"])
        var terminated = false
        await #expect(throws: URLError.self) {
            try await ApplicationRestart.perform(launch: { throw URLError(.cannotLoadFromNetwork) }, terminate: { terminated = true })
        }
        #expect(!terminated)
    }
}

@Suite("Calendar write and cache regressions")
struct CalendarStorageRegressions {
    @Test func removingRecurrenceSendsAnExplicitEmptyArray() async throws {
        let original = GoogleEvent(id: "series", summary: "Repeating", start: GoogleEventDateTime(dateTime: "2026-10-13T09:00:00Z"),
                                   end: GoogleEventDateTime(dateTime: "2026-10-13T10:00:00Z"), recurrence: ["RRULE:FREQ=DAILY"])
        var response = original; response.recurrence = []
        let data = try JSONEncoder().encode(response)
        let context = try RegressionContext { _ in (200, data) }
        defer { context.cleanup() }
        try await context.store.save(CalendarRecord(id: "main", accountID: "owner", title: "Main"), id: "main", collection: "calendar.sources", accountID: "owner")
        try await context.store.save(original, id: original.id, collection: "calendar.events.main", accountID: "owner")
        var edit = try CalendarService.event(from: original, calendarID: "main", accountID: "owner")
        edit.recurrence = []
        _ = try await CalendarService(api: context.api, store: context.store).update(edit)
        let request = try #require(context.transport.recorded().first)
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(payload["recurrence"] as? [String] == [])
    }

    @Test func invalidRecurrenceCannotMoveAnEventBeforeValidation() async throws {
        let context = try RegressionContext { _ in json("{}") }
        defer { context.cleanup() }
        for id in ["source", "destination"] {
            try await context.store.save(CalendarRecord(id: id, accountID: "owner", title: id), id: id,
                                         collection: "calendar.sources", accountID: "owner")
        }
        let event = CalendarEvent(id: "existing", calendarID: "destination", accountID: "owner", title: "Edited",
                                  start: .now, end: .now.addingTimeInterval(3600), recurrence: ["RRULE:FREQ=DAILY;UNTIL=20260230"])
        await #expect(throws: CalendarService.CalendarError.self) {
            _ = try await CalendarService(api: context.api, store: context.store).update(event, originalCalendarID: "source")
        }
        #expect(context.transport.recorded().isEmpty)
    }

    @Test func navigationSkipsCalendarsWithOnlyFreeBusyAccess() async throws {
        let context = try RegressionContext { _ in json(#"{"items":[]}"#) }
        defer { context.cleanup() }
        for (id, role) in [("details", "reader"), ("busy", "freeBusyReader")] {
            try await context.store.save(CalendarRecord(id: id, accountID: "owner", title: id, accessRole: role), id: id,
                                         collection: "calendar.sources", accountID: "owner")
        }
        try await CalendarService(api: context.api, store: context.store).ensureEvents(accountID: "owner",
            interval: DateInterval(start: .now, duration: 7 * 86400))
        #expect(context.transport.recorded().count == 1)
        #expect(context.transport.recorded().first?.url?.path.contains("/details/") == true)
    }

    @Test func collectionSnapshotReturnsTheRevisionOfItsValuesAndSkipsUnchangedReads() async throws {
        let context = try RegressionContext { _ in json("{}") }
        defer { context.cleanup() }
        let revision = try await context.store.save([LocalStore.Record(id: "one", value: "First")], collection: "snapshot", accountID: "owner")
        let snapshot = try #require(try await context.store.snapshot(String.self, collection: "snapshot", accountID: "owner"))
        #expect(snapshot.revision == revision && snapshot.values == ["First"])
        #expect(try await context.store.snapshot(String.self, collection: "snapshot", accountID: "owner", ifChangedSince: revision) == nil)
        try await context.store.save("Second", id: "one", collection: "snapshot", accountID: "owner")
        let changed = try #require(try await context.store.snapshot(String.self, collection: "snapshot", accountID: "owner", ifChangedSince: revision))
        #expect(changed.revision > revision && changed.values == ["Second"])
    }
    @Test func repeatingCreateRequestIsIdempotent() async throws {
        let backend = MockGoogleBackend(fileURL: nil)
        let context = try RegressionContext { request in
            let response = backend.handle(request); return (response.status, response.body)
        }
        defer { context.cleanup() }
        let accountID = MockGoogleBackend.accountEmail
        let calendar = CalendarRecord(id: accountID, accountID: accountID, title: "Personal")
        try await context.store.save(calendar, id: calendar.id, collection: "calendar.sources", accountID: accountID)
        let service = CalendarService(api: context.api, store: context.store), id = UUID()
        let event = CalendarEvent(id: "", calendarID: calendar.id, accountID: accountID, title: "One proposal", start: .now, end: .now.addingTimeInterval(3600))
        async let first = service.create(event, requestID: id)
        async let second = service.create(event, requestID: id)
        let values = try await (first, second)
        #expect(values.0.id == values.1.id)
        #expect(try await service.cachedEvents(accountID: accountID).filter { $0.title == event.title }.count == 1)
        let inserts = context.transport.recorded().filter { $0.httpMethod == "POST" }
        #expect(inserts.count == 2)
        let bodies = try inserts.map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any] }
        #expect(bodies[0]["id"] as? String == bodies[1]["id"] as? String)
    }

    @Test func staleSeriesEditCannotChangeTheMaster() async throws {
        let old = #"{"id":"instance","summary":"Planning","start":{"dateTime":"2026-10-13T09:00:00Z"},"end":{"dateTime":"2026-10-13T10:00:00Z"},"recurringEventId":"series","etag":"old"}"#
        let changed = old.replacingOccurrences(of: "09:00:00Z", with: "10:00:00Z").replacingOccurrences(of: "\"etag\":\"old\"", with: "\"etag\":\"new\"")
        let context = try RegressionContext { _ in json(changed) }
        defer { context.cleanup() }
        let calendar = CalendarRecord(id: "main", accountID: "owner", title: "Main")
        try await context.store.save(calendar, id: calendar.id, collection: "calendar.sources", accountID: "owner")
        let source = try JSONDecoder().decode(GoogleEvent.self, from: Data(old.utf8))
        let original = try CalendarService.event(from: source, calendarID: "main", accountID: "owner")
        try await context.store.save(try JSONDecoder().decode(GoogleEvent.self, from: Data(changed.utf8)), id: source.id, collection: "calendar.events.main", accountID: "owner")
        var edit = original; edit.title = "Only a title change"
        let service = CalendarService(api: context.api, store: context.store)
        await #expect(throws: GoogleAPIError.self) { _ = try await service.update(edit, scope: .allEvents, originalEvent: original) }
        #expect(context.transport.recorded().map(\.httpMethod) == ["GET"])
    }

    @Test func originalEditorValuesAreTheBaselineWhenETagsAreUnavailable() async throws {
        let instance = #"{"id":"instance","summary":"Planning","start":{"dateTime":"2026-10-13T09:00:00Z"},"end":{"dateTime":"2026-10-13T10:00:00Z"},"recurringEventId":"series"}"#
        let master = #"{"id":"series","summary":"Planning","start":{"dateTime":"2026-01-13T09:00:00Z","timeZone":"UTC"},"end":{"dateTime":"2026-01-13T10:00:00Z"},"recurrence":["RRULE:FREQ=WEEKLY"]}"#
        let context = try RegressionContext { request in
            request.url!.path.hasSuffix("/events") ? json("{\"items\":[],\"nextSyncToken\":\"next\"}") : json(master)
        }
        defer { context.cleanup() }
        try await context.store.save(CalendarRecord(id: "main", accountID: "owner", title: "Main"), id: "main", collection: "calendar.sources", accountID: "owner")
        let raw = try JSONDecoder().decode(GoogleEvent.self, from: Data(instance.utf8))
        let original = try CalendarService.event(from: raw, calendarID: "main", accountID: "owner")
        var newer = raw; newer.start = GoogleEventDateTime(dateTime: "2026-10-13T10:00:00Z")
        try await context.store.save(newer, id: raw.id, collection: "calendar.events.main", accountID: "owner")
        var edit = original; edit.title = "Title only"
        _ = try await CalendarService(api: context.api, store: context.store).update(edit, scope: .allEvents, originalEvent: original)
        let patch = try #require(context.transport.recorded().first { $0.httpMethod == "PATCH" })
        let body = try JSONSerialization.jsonObject(with: patch.httpBody!) as! [String: Any]
        #expect((body["start"] as? [String: String])?["dateTime"] == "2026-01-13T09:00:00Z")
    }

    @Test func emptyIncrementalSyncDoesNotRewriteTheCollection() async throws {
        let rows = (0..<1000).map { GoogleEvent(id: "e\($0)", summary: "Event", start: GoogleEventDateTime(dateTime: "2026-10-13T09:00:00Z"), end: GoogleEventDateTime(dateTime: "2026-10-13T10:00:00Z")) }
        let initial = try JSONEncoder().encode(GooglePage(items: rows, nextSyncToken: "initial"))
        let context = try RegressionContext { request in
            if request.url!.path.hasSuffix("calendarList") {
                return json(#"{"items":[{"id":"main","summary":"Main","accessRole":"owner","selected":true}]}"#)
            }
            if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(where: { $0.name == "syncToken" }) {
                return json(#"{"items":[],"nextSyncToken":"next"}"#)
            }
            return (200, initial)
        }
        defer { context.cleanup() }
        let service = CalendarService(api: context.api, store: context.store)
        try await service.sync(accountID: "owner")
        let before = try await service.cachedEvents(accountID: "owner")
        let revision = await context.store.revision(collection: "calendar.events.main", accountID: "owner")
        try await service.sync(accountID: "owner")
        #expect(await context.store.revision(collection: "calendar.events.main", accountID: "owner") == revision)
        #expect(try await service.cachedEvents(accountID: "owner") == before)
        var changed = rows[0]; changed.summary = "Updated directly"
        try await context.store.save(changed, id: changed.id, collection: "calendar.events.main", accountID: "owner")
        #expect(try await service.cachedEvents(accountID: "owner").first { $0.id == changed.id }?.title == changed.summary)
    }
}

@Suite("Mail queue, search, and body regressions")
struct MailRegressions {
    @Test func staleMailSnapshotsCannotOverwriteNewerForegroundChanges() async throws {
        let context = try RegressionContext { _ in json("{}") }
        defer { context.cleanup() }
        let service = MailService(api: context.api, store: context.store)
        var thread = MailThread(id: "read-this", accountID: "owner", messages: [], labels: ["INBOX", "UNREAD"])
        try await context.store.save(thread, id: thread.id, collection: "threads", accountID: "owner")
        let unread = try await service.cached(accountID: "owner")
        thread.labels = ["INBOX"]
        try await context.store.save(thread, id: thread.id, collection: "threads", accountID: "owner")
        let read = try await service.cached(accountID: "owner")
        thread.labels = []
        try await context.store.save(thread, id: thread.id, collection: "threads", accountID: "owner")
        let archived = try await service.cached(accountID: "owner")
        let page = try await context.store.mailSearchPage(threadIDs: [thread.id, "removed"], nextPageToken: "next", accountID: "owner")
        #expect(page.revision == archived.revision && page.threads.count == 1 && page.threads.first?.labels.isEmpty == true)
        #expect(page.nextPageToken == "next")
        #expect(unread.revision < read.revision && read.revision < archived.revision)
        var order = MailSnapshotOrder(), displayed: MailSnapshot?
        for snapshot in [unread, archived, read, unread] where order.accept(revision: snapshot.revision, accountID: "owner") {
            displayed = snapshot
        }
        #expect(displayed?.threads.first?.labels.isEmpty == true)
        let otherAccountAccepted = order.accept(revision: 0, accountID: "another-account")
        let staleAccountAccepted = order.accept(revision: read.revision, accountID: "owner")
        #expect(otherAccountAccepted)
        #expect(!staleAccountAccepted)
    }

    @Test func sentSeedRestartsAnExpiredCheckpointAndPreservesDecisionsAcrossBatches() async throws {
        let backend = MockGoogleBackend(fileURL: nil)
        let context = try RegressionContext { request in
            if request.url!.path.hasSuffix("/messages") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                if query.contains(where: { $0.name == "pageToken" && $0.value == "expired" }) {
                    return (400, Data(#"{"error":{"message":"Invalid pageToken"}}"#.utf8))
                }
                let ids = (0..<25).map { "{\"id\":\"seed\($0)\",\"threadId\":\"sent\"}" }.joined(separator: ",")
                return json("{\"messages\":[\(ids)]}")
            }
            if request.url!.lastPathComponent.hasPrefix("seed") {
                let id = request.url!.lastPathComponent
                return json("{\"id\":\"\(id)\",\"threadId\":\"sent\",\"payload\":{\"headers\":[{\"name\":\"To\",\"value\":\"blocked@example.com, domain@blocked.org, \(id)@new.org\"}]}}")
            }
            let response = backend.handle(request); return (response.status, response.body)
        }
        defer { context.cleanup() }
        let account = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail)
        var rules = (0..<5000).map { SenderRule(accountID: account.id, key: "known\($0)@example.com", decision: .approved) }
        rules += [SenderRule(accountID: account.id, key: "blocked@example.com", decision: .blocked),
                  SenderRule(accountID: account.id, key: "@blocked.org", decision: .blocked)]
        try await context.store.save(rules.map { .init(id: $0.key, value: $0) }, collection: "senderRules", accountID: account.id)
        try await context.store.setMetadata("expired", key: "sentRecipientsPage", accountID: account.id)
        let service = MailService(api: context.api, store: context.store)
        let snapshot = try await service.sync(account: account)
        let index = SenderRuleIndex(snapshot.rules)
        #expect(index.rule(for: "blocked@example.com")?.decision == .blocked)
        #expect(index.rule(for: "domain@blocked.org")?.decision == .blocked)
        #expect(snapshot.rules.filter { $0.key.hasSuffix("@new.org") }.count == 25)
        #expect(try await context.store.metadata(Bool.self, key: "sentRecipientsSeeded", accountID: account.id) == true)
        #expect(try await context.store.metadata(String.self, key: "sentRecipientsPage", accountID: account.id) == nil)
        #expect(context.transport.recorded().filter { $0.url!.path.hasSuffix("/messages") }.count == 2)
        // The cached index must notice a later foreground decision, even when sending to that address.
        let block = SenderRule(accountID: account.id, key: "seed0@new.org", decision: .blocked)
        try await context.store.save(block, id: block.key, collection: "senderRules", accountID: account.id)
        _ = try await service.send(OutgoingMessage(to: [block.key], body: "Reply"), account: account)
        #expect(try await service.cached(accountID: account.id).rules.first { $0.key == block.key }?.decision == .blocked)
    }

    @Test func indexedSenderRulesKeepExactOverridesAndAccountIsolation() {
        let index = SenderRuleIndex([SenderRule(accountID: "owner", key: "@example.com", decision: .blocked),
                                     SenderRule(accountID: "owner", key: "friend@example.com", decision: .approved)])
        #expect(index.rule(for: "FRIEND@EXAMPLE.COM")?.decision == .approved)
        #expect(index.rule(for: "other@example.com")?.decision == .blocked)
        #expect(index.rule(for: "person@elsewhere.com") == nil)
        #expect(SenderRuleIndex().rule(for: "friend@example.com") == nil)
    }
    @Test func externalTextBodiesAreHydratedAndSurviveLaterMetadataRefreshes() async throws {
        let plain = "The complete plain body", html = "<p>The complete HTML body</p>"
        let source = #"{"id":"body-thread","messages":[{"id":"body-message","threadId":"body-thread","labelIds":["DRAFT"],"internalDate":"1791800000000","payload":{"mimeType":"multipart/alternative","headers":[{"name":"From","value":"owner@example.com"},{"name":"Message-ID","value":"<body@example.com>"}],"parts":[{"mimeType":"text/plain","filename":"","body":{"attachmentId":"plain","size":10000}},{"mimeType":"text/html","filename":"","body":{"attachmentId":"html","size":10000}}]}}]}"#
        let context = try RegressionContext { request in
            if request.url!.path.hasSuffix("/attachments/plain") { return json("{\"data\":\"\(Data(plain.utf8).base64URL)\"}") }
            if request.url!.path.hasSuffix("/attachments/html") { return json("{\"data\":\"\(Data(html.utf8).base64URL)\"}") }
            return json(source)
        }
        defer { context.cleanup() }
        let account = Account(id: "owner", email: "owner@example.com")
        try await context.prepareMail(account)
        let raw = try JSONDecoder().decode(GoogleMailThread.self, from: Data(source.utf8))
        let unhydrated = MailMapping.thread(raw, accountID: account.id, labels: [:])
        #expect(unhydrated.messages.first?.needsBodyHydration == true)
        var legacy = unhydrated
        legacy.messages[0].bodyIsExternal = nil
        legacy.messages[0].snippet = "The beginning of a long body"
        #expect(legacy.messages[0].needsBodyHydration)
        #expect(MailMapping.thread(raw, accountID: account.id, labels: [:], previous: legacy).messages[0].needsBodyHydration)
        let service = MailService(api: context.api, store: context.store)
        let thread = try await service.fetchThread(id: raw.id, account: account)
        #expect(thread.messages.first?.plainText == plain)
        #expect(thread.messages.first?.html == html)
        #expect(thread.messages.first?.needsBodyHydration == false)
        #expect(thread.messages.first?.attachments.isEmpty == true)
        _ = try await service.markUnread(threadID: thread.id, unread: true, account: account)
        let cache = try await service.cached(accountID: account.id)
        #expect(cache.threads.first?.messages.first?.plainText == plain)
        #expect(cache.threads.first?.messages.first?.html == html)
        #expect(context.transport.recorded().filter { $0.url!.path.contains("/attachments/") }.count == 2)
    }

    @Test func searchFetchesOnlyOnePageUntilMoreResultsAreRequested() async throws {
        let context = try RegressionContext { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if request.url!.path.hasSuffix("/threads") {
                let offset = Int(query.first { $0.name == "pageToken" }?.value ?? "0")!
                let limit = Int(query.first { $0.name == "maxResults" }?.value ?? "0")!
                let ids = (offset..<(offset + limit)).map { "{\"id\":\"t\($0)\"}" }.joined(separator: ",")
                return json("{\"threads\":[\(ids)],\"nextPageToken\":\"\(offset + limit)\"}")
            }
            let id = request.url!.lastPathComponent
            return json("{\"id\":\"\(id)\",\"messages\":[{\"id\":\"m\(id)\",\"threadId\":\"\(id)\",\"internalDate\":\"1791800000000\"}]}")
        }
        defer { context.cleanup() }
        let account = Account(id: "owner", email: "owner@example.com")
        try await context.prepareMail(account)
        let service = MailService(api: context.api, store: context.store)
        let first = try await service.searchPage(query: "invoice", account: account)
        #expect(first.threads.count == 50 && first.nextPageToken == "50")
        #expect(context.transport.recorded().filter { !$0.url!.path.hasSuffix("/threads") }.count == 50)
        let second = try await service.searchPage(query: "invoice", pageToken: first.nextPageToken, account: account)
        #expect(second.threads.count == 50 && second.nextPageToken == "100")
        #expect(Set(first.threads.map(\.id)).isDisjoint(with: second.threads.map(\.id)))
        #expect(context.transport.recorded().filter { $0.url!.path.hasSuffix("/threads") }.count == 2)
    }

    @Test func foregroundSendDoesNotWaitForASlowSearchEnumeration() async throws {
        let backend = MockGoogleBackend(fileURL: nil)
        let context = try RegressionContext(pauseAt: 1) { request in
            let response = backend.handle(request); return (response.status, response.body)
        }
        defer { context.cleanup() }
        let account = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail)
        try await context.prepareMail(account)
        let service = MailService(api: context.api, store: context.store)
        let search = Task { try await service.searchPage(query: "", account: account) }
        while !(await context.token.started) { await Task.yield() }
        _ = try await service.send(OutgoingMessage(to: ["person@example.com"], subject: "Foreground", body: "Send now"), account: account)
        _ = try await search.value
        let requests = context.transport.recorded()
        let sent = try #require(requests.firstIndex { $0.url!.path.hasSuffix("/messages/send") })
        let list = try #require(requests.firstIndex { $0.url!.path.hasSuffix("/threads") })
        #expect(sent < list)
    }

    @Test func foregroundSendRunsBetweenSearchDownloadBatches() async throws {
        let context = try RegressionContext(pauseAt: 2) { request in
            if request.url!.path.hasSuffix("/threads") {
                let ids = (0..<50).map { "{\"id\":\"t\($0)\"}" }.joined(separator: ",")
                return json("{\"threads\":[\(ids)]}")
            }
            if request.url!.path.hasSuffix("/messages/send") {
                return json("{\"id\":\"sent\",\"threadId\":\"sent-thread\"}")
            }
            if request.url!.path.hasSuffix("/drafts") { return json("{\"drafts\":[]}") }
            let id = request.url!.lastPathComponent
            return json("{\"id\":\"\(id)\",\"messages\":[{\"id\":\"m\(id)\",\"threadId\":\"\(id)\",\"internalDate\":\"1791800000000\"}]}")
        }
        defer { context.cleanup() }
        let account = Account(id: "owner", email: "owner@example.com")
        try await context.prepareMail(account)
        let service = MailService(api: context.api, store: context.store)
        let search = Task { try await service.searchPage(query: "invoice", account: account) }
        while !(await context.token.started) { await Task.yield() }
        _ = try await service.send(OutgoingMessage(to: ["person@example.com"], body: "Send between batches"), account: account)
        _ = try await search.value
        let requests = context.transport.recorded()
        let sent = try #require(requests.firstIndex { $0.url!.path.hasSuffix("/messages/send") })
        let nextBatch = try #require(requests.firstIndex { $0.url!.path.hasSuffix("/threads/t8") })
        #expect(sent < nextBatch)
    }

    @Test func resultMembershipIsCheckedWithoutDownloadingTheWholeSearch() async throws {
        let context = try RegressionContext { _ in json("{\"threads\":[]}") }
        defer { context.cleanup() }
        let account = Account(id: "owner", email: "owner@example.com")
        let thread = MailThread(id: "changed", accountID: account.id, messages: [
            MailMessage(id: "message", threadID: "changed", accountID: account.id, from: MailAddress(email: "person@example.com"), rfcMessageID: "<message@example.com>")
        ])
        let matches = try await MailService(api: context.api, store: context.store).matchesSearch(thread, query: "is:unread invoice", account: account)
        #expect(!matches)
        let requests = context.transport.recorded()
        #expect(requests.count == 1)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "maxResults" }?.value == "1")
        #expect(query.first { $0.name == "q" }?.value == "(is:unread invoice) {rfc822msgid:message@example.com}")
    }

    @Test func syncYieldsToForegroundWorkAndPublishesMailBeforeSentSeeding() async throws {
        let backend = MockGoogleBackend(fileURL: nil)
        let context = try RegressionContext(pauseAt: 3) { request in
            let response = backend.handle(request); return (response.status, response.body)
        }
        defer { context.cleanup() }
        let account = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail)
        let service = MailService(api: context.api, store: context.store)
        let sync = Task { try await service.sync(account: account, progress: { snapshot in
            #expect(!snapshot.threads.isEmpty)
            #expect(!context.transport.recorded().contains { $0.url!.path.hasSuffix("/messages") })
        }) }
        while !(await context.token.started) { await Task.yield() }
        _ = try await service.send(OutgoingMessage(to: ["person@example.com"], subject: "Foreground", body: "Send now"), account: account)
        _ = try await sync.value
        let requests = context.transport.recorded()
        let sent = try #require(requests.firstIndex { $0.url!.path.hasSuffix("/messages/send") })
        let profile = try #require(requests.firstIndex { $0.url!.path.hasSuffix("/profile") })
        #expect(sent < profile)
    }

    @Test func timelyUndoRemainsValidAfterWaitingBeyondItsDeadline() async throws {
        let backend = MockGoogleBackend(fileURL: nil)
        let context = try RegressionContext { request in
            let response = backend.handle(request); return (response.status, response.body)
        }
        defer { context.cleanup() }
        let account = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail)
        let service = MailService(api: context.api, store: context.store, undoDuration: 0.25)
        let initial = try await service.sync(account: account)
        let inbox = try #require(initial.threads.first { $0.labels.contains("INBOX") })
        let undo = try await service.archive(threadID: inbox.id, account: account)
        await context.token.pauseNext(delay: .milliseconds(500))
        let read = Task { try await service.markUnread(threadID: inbox.id, unread: false, account: account) }
        while !(await context.token.started) { await Task.yield() }
        let timelyClick = Task { try await service.undo(tokenID: undo.id, account: account) }
        _ = try await read.value
        try await timelyClick.value
        #expect(Date.now > undo.expiresAt)
        let restored = try await service.cached(accountID: account.id).threads.first { $0.id == inbox.id }
        #expect(restored?.labels == inbox.labels)
    }

    @Test func aLateUndoIsStillRejected() async throws {
        let backend = MockGoogleBackend(fileURL: nil)
        let context = try RegressionContext { request in
            let response = backend.handle(request); return (response.status, response.body)
        }
        defer { context.cleanup() }
        let account = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail)
        let service = MailService(api: context.api, store: context.store, undoDuration: 0)
        let initial = try await service.sync(account: account)
        let inbox = try #require(initial.threads.first { $0.labels.contains("INBOX") })
        let undo = try await service.archive(threadID: inbox.id, account: account)
        await #expect(throws: MailService.MailError.self) { try await service.undo(tokenID: undo.id, account: account) }
    }
}
