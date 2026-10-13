import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EmailCalendarCore

private struct CalendarTestToken: GoogleTokenProvider {
    let value: String
    func accessToken(forceRefresh: Bool) async throws -> String { value }
}

private actor CalendarSlowToken: GoogleTokenProvider {
    let value: String
    var started = false
    var wasCancelled = false
    private var shouldWait = true
    init(value: String) { self.value = value }
    func accessToken(forceRefresh: Bool) async throws -> String {
        if shouldWait {
            shouldWait = false
            started = true
            do { try await Task.sleep(for: .seconds(2)) }
            catch { wasCancelled = true; throw error }
        }
        return value
    }
}

private final class CalendarHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let response: @Sendable (URLRequest, Int) -> (Int, String)

    init(response: @escaping @Sendable (URLRequest, Int) -> (Int, String)) { self.response = response }
    func handle(_ request: URLRequest) -> (Int, Data) {
        lock.lock()
        recorded.append(request)
        let index = recorded.count
        lock.unlock()
        let result = response(request, index)
        return (result.0, Data(result.1.utf8))
    }
    func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Authorization namespaces keep independent async tests from sharing a mock server.
private final class CalendarFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: CalendarHTTPFixture] = [:]
    func register(_ fixture: CalendarHTTPFixture, token: String) {
        lock.lock()
        defer { lock.unlock() }
        fixtures[token] = fixture
    }
    func remove(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        fixtures.removeValue(forKey: token)
    }
    func fixture(for request: URLRequest) -> CalendarHTTPFixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixtures[request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""]
    }
}

private final class CalendarURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = CalendarFixtureRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request.withMaterializedBody()
        guard let fixture = Self.registry.fixture(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = fixture.handle(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Calendar cache and Google synchronization")
struct CalendarServiceTests {
    private static let calendarsJSON = ##"{"items":[{"id":"primary@example.com","summary":"Personal","primary":true,"selected":true,"accessRole":"owner","backgroundColor":"#123456"}]}"##
    private static let instanceJSON = #"{"id":"weekly_20261002T120000Z","summary":"Planning","start":{"dateTime":"2026-10-02T12:00:00Z"},"end":{"dateTime":"2026-10-02T12:30:00Z"},"recurringEventId":"weekly","originalStartTime":{"dateTime":"2026-10-02T12:00:00Z"},"etag":"version-1"}"#

    private func context(_ fixture: CalendarHTTPFixture) throws -> (CalendarService, LocalStore, String, URL) {
        let token = UUID().uuidString
        CalendarURLProtocol.registry.register(fixture, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarURLProtocol.self]
        let api = GoogleAPI(auth: CalendarTestToken(value: token), session: URLSession(configuration: configuration))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarTests-\(UUID().uuidString)")
        let store = try LocalStore(url: directory.appendingPathComponent("cache.sqlite"))
        return (CalendarService(api: api, store: store), store, token, directory)
    }

    private func cleanup(token: String, directory: URL) {
        CalendarURLProtocol.registry.remove(token)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("Paged initial sync, incremental cancellation, and expired-token replacement")
    func incrementalAndExpiredToken() async throws {
        let fixture = CalendarHTTPFixture { request, number in
            if request.url!.path.hasSuffix("calendarList") { return (200, Self.calendarsJSON) }
            switch number {
            case 2: return (200, "{\"items\":[\(Self.instanceJSON)],\"nextPageToken\":\"page-two\"}")
            case 3: return (200, #"{"items":[{"id":"stale","summary":"Removed later","start":{"dateTime":"2026-10-02T15:00:00Z"},"end":{"dateTime":"2026-10-02T16:00:00Z"}}],"nextSyncToken":"token-one"}"#)
            case 5: return (200, "{\"items\":[\(Self.instanceJSON.replacingOccurrences(of: "Planning", with: "Updated planning")),{\"id\":\"stale\",\"status\":\"cancelled\"}],\"nextSyncToken\":\"token-two\"}")
            case 7: return (410, #"{"error":{"message":"Sync token expired"}}"#)
            case 8: return (200, #"{"items":[{"id":"fresh","summary":"Replacement","start":{"dateTime":"2026-10-03T12:00:00Z"},"end":{"dateTime":"2026-10-03T13:00:00Z"}}],"nextSyncToken":"token-three"}"#)
            default: return (400, #"{"error":{"message":"Unexpected request"}}"#)
            }
        }
        let (service, store, token, directory) = try context(fixture)
        defer { cleanup(token: token, directory: directory) }
        let accountID = "owner@example.com"
        try await service.sync(accountID: accountID)
        var events = try await service.cachedEvents(accountID: accountID)
        #expect(events.count == 2)
        #expect(events.first?.recurringEventID == "weekly")
        #expect(events.first?.originalStart == events.first?.start)
        try await service.setVisibility(calendarID: "primary@example.com", accountID: accountID, isVisible: false)
        #expect(try await service.cachedEvents(accountID: accountID).isEmpty)

        try await service.sync(accountID: accountID)
        events = try await service.cachedEvents(accountID: accountID, visibleOnly: false)
        #expect(events.count == 1)
        #expect(events.first?.title == "Updated planning")
        #expect(try await service.cachedCalendars(accountID: accountID).first?.isVisible == false)

        try await service.sync(accountID: accountID)
        events = try await service.cachedEvents(accountID: accountID, visibleOnly: false)
        #expect(events.map(\.id) == ["fresh"])
        let restarted = CalendarService(api: GoogleAPI(auth: CalendarTestToken(value: token)), store: store)
        #expect(try await restarted.cachedCalendars(accountID: accountID).first?.isVisible == false)
        #expect(try await restarted.cachedEvents(accountID: accountID, visibleOnly: false).map(\.id) == ["fresh"])
        #expect(try await restarted.cachedEvents(accountID: "another-account", visibleOnly: false).isEmpty)

        let requests = fixture.requests()
        #expect(requests.count == 8)
        let first = query(requests[1])
        let pageTwo = query(requests[2])
        #expect(first["singleEvents"] == "true")
        #expect(first["showDeleted"] == "true")
        #expect(first["timeMin"] != nil && first["timeMax"] != nil)
        #expect(pageTwo["pageToken"] == "page-two")
        #expect(first["timeMin"] == pageTwo["timeMin"])
        #expect(query(requests[4])["syncToken"] == "token-one")
        #expect(query(requests[4])["timeMin"] == nil && query(requests[4])["timeMax"] == nil)
        #expect(query(requests[6])["syncToken"] == "token-two")
        #expect(query(requests[7])["syncToken"] == nil)
    }

    @Test("Failed reset leaves the last good calendar usable offline")
    func failedResetPreservesCache() async throws {
        let fixture = CalendarHTTPFixture { request, number in
            if request.url!.path.hasSuffix("calendarList") { return (200, Self.calendarsJSON) }
            if number == 2 { return (200, "{\"items\":[\(Self.instanceJSON)],\"nextSyncToken\":\"old-token\"}") }
            if number == 4 { return (410, #"{"error":{"message":"Expired"}}"#) }
            return (400, #"{"error":{"message":"Offline reset failed"}}"#)
        }
        let (service, _, token, directory) = try context(fixture)
        defer { cleanup(token: token, directory: directory) }
        try await service.sync(accountID: "owner")
        await #expect(throws: GoogleAPIError.self) { try await service.sync(accountID: "owner") }
        #expect(try await service.cachedEvents(accountID: "owner").map(\.id) == ["weekly_20261002T120000Z"])
    }

    @Test("All-day dates are local midnight and their end is exclusive")
    func allDayAndTimedDateMapping() throws {
        let raw = try JSONDecoder().decode(GoogleEvent.self, from: Data(#"{"id":"trip","summary":"Trip","start":{"date":"2026-10-02"},"end":{"date":"2026-10-04"},"attendees":[{"email":"owner@example.com","self":true,"responseStatus":"needsAction"}],"description":"Join https://company.zoom.us/j/12345"}"#.utf8))
        let event = try CalendarService.event(from: raw, calendarID: "personal", accountID: "owner")
        let calendar = Calendar.current
        #expect(event.isAllDay)
        #expect(calendar.component(.day, from: event.start) == 2)
        #expect(calendar.component(.hour, from: event.start) == 0)
        #expect(calendar.component(.day, from: event.end) == 4)
        #expect(calendar.dateComponents([.day], from: event.start, to: event.end).day == 2)
        #expect(event.attendees.first?.isSelf == true)
        #expect(event.videoURL?.host == "company.zoom.us")
        let withOffset = CalendarService.date(GoogleEventDateTime(dateTime: "2026-10-02T14:30:00+02:00"))
        let utc = CalendarService.date(GoogleEventDateTime(dateTime: "2026-10-02T12:30:00.000Z"))
        #expect(withOffset != nil && withOffset == utc)
        #expect(CalendarService.date(GoogleEventDateTime(date: "2026-02-30")) == nil)
    }

    @Test("Create, edit, invitation response, and Calendar deletion")
    func writesAndInvitationResponse() async throws {
        let raw = #"{"id":"created","summary":"Lunch","start":{"dateTime":"2026-10-02T12:00:00Z"},"end":{"dateTime":"2026-10-02T13:00:00Z"},"etag":"etag-1","attendees":[{"email":"owner@example.com","self":true,"responseStatus":"needsAction"}]}"#
        let fixture = CalendarHTTPFixture { request, number in
            if request.httpMethod == "DELETE" { return (204, "") }
            if number == 4 { return (200, raw.replacingOccurrences(of: "needsAction", with: "accepted")) }
            return (200, raw)
        }
        let (service, store, token, directory) = try context(fixture)
        defer { cleanup(token: token, directory: directory) }
        let calendar = CalendarRecord(id: "personal", accountID: "owner", title: "Personal")
        try await store.save(calendar, id: calendar.id, collection: "calendar.sources", accountID: "owner")
        let start = try #require(CalendarService.date(GoogleEventDateTime(dateTime: "2026-10-02T12:00:00Z")))
        let created = try await service.create(CalendarEvent(calendarID: "personal", accountID: "owner", title: "Lunch",
                                                              start: start, end: start.addingTimeInterval(3_600)))
        #expect(created.id == "created")
        _ = try await service.update(created)
        let accepted = try await service.respond(to: created, status: .accepted)
        #expect(accepted.attendees.first?.response == .accepted)
        try await service.delete(accepted)
        #expect(try await service.cachedEvents(accountID: "owner").isEmpty)
        let requests = fixture.requests()
        #expect(requests.map(\.httpMethod) == ["POST", "PATCH", "GET", "PATCH", "DELETE"])
        let createBody = try body(requests[0])
        #expect(createBody["id"] == nil)
        let responseBody = try body(requests[3])
        #expect(responseBody["summary"] == nil && responseBody["start"] == nil)
        #expect(responseBody["attendeesOmitted"] as? Bool == true)
        #expect(requests[3].value(forHTTPHeaderField: "If-Match") == "etag-1")
    }

    @Test("Editing all recurring events shifts the master and refreshes expanded occurrences")
    func recurringEditScopes() async throws {
        let master = #"{"id":"weekly","summary":"Planning","start":{"dateTime":"2025-01-03T12:00:00Z","timeZone":"UTC"},"end":{"dateTime":"2025-01-03T12:30:00Z","timeZone":"UTC"},"recurrence":["RRULE:FREQ=WEEKLY;BYDAY=FR"],"etag":"master-etag"}"#
        let updatedInstance = Self.instanceJSON.replacingOccurrences(of: "12:00:00Z", with: "13:00:00Z")
            .replacingOccurrences(of: "12:30:00Z", with: "14:00:00Z")
        let fixture = CalendarHTTPFixture { request, number in
            if request.httpMethod == "DELETE" { return (204, "") }
            if request.url!.path.hasSuffix("calendarList") { return (200, Self.calendarsJSON) }
            switch number {
            case 2: return (200, "{\"items\":[\(Self.instanceJSON)],\"nextSyncToken\":\"first\"}")
            case 3: return (200, Self.instanceJSON)
            case 4, 5: return (200, master)
            case 6: return (200, "{\"items\":[\(updatedInstance)],\"nextSyncToken\":\"range-token\"}")
            case 7: return (200, updatedInstance)
            default: return (400, #"{"error":{"message":"Unexpected recurrence request"}}"#)
            }
        }
        let (service, _, token, directory) = try context(fixture)
        defer { cleanup(token: token, directory: directory) }
        try await service.sync(accountID: "owner")
        var instance = try #require(try await service.cachedEvents(accountID: "owner").first)
        instance.start = instance.start.addingTimeInterval(3_600)
        instance.end = instance.start.addingTimeInterval(3_600)
        let changed = try await service.update(instance, scope: .allEvents)
        #expect(changed.id == instance.id)
        #expect(try await service.cachedEvents(accountID: "owner").map(\.id) == [instance.id])
        #expect(changed.start == instance.start && changed.end == instance.end)
        _ = try await service.update(changed, scope: .thisEvent)
        try await service.delete(changed, scope: .allEvents)
        #expect(try await service.cachedEvents(accountID: "owner").isEmpty)
        let requests = fixture.requests()
        #expect(requests[4].url!.path.hasSuffix("/weekly"))
        let payload = try body(requests[4])
        #expect(payload["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY;BYDAY=FR"])
        #expect((payload["start"] as? [String: String])?["dateTime"] == "2025-01-03T13:00:00Z")
        #expect((payload["end"] as? [String: String])?["dateTime"] == "2025-01-03T14:00:00Z")
        #expect(requests[4].value(forHTTPHeaderField: "If-Match") == "master-etag")
        #expect(requests[6].url!.path.hasSuffix("/\(instance.id)"))
        #expect(try body(requests[6])["recurrence"] == nil)
        #expect(requests[7].url!.path.hasSuffix("/weekly"))
    }

    @Test("Sign-out drains the actual network task before another account can use the service")
    func cancelAndDrainSync() async throws {
        let fixture = CalendarHTTPFixture { request, _ in
            if request.url!.path.hasSuffix("calendarList") { return (200, Self.calendarsJSON) }
            return (200, #"{"nextSyncToken":"empty-calendar"}"#)
        }
        let token = UUID().uuidString
        CalendarURLProtocol.registry.register(fixture, token: token)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarCancelTests-\(UUID().uuidString)")
        defer { cleanup(token: token, directory: directory) }
        let provider = CalendarSlowToken(value: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarURLProtocol.self]
        let api = GoogleAPI(auth: provider, session: URLSession(configuration: configuration))
        let store = try LocalStore(url: directory.appendingPathComponent("cache.sqlite"))
        let service = CalendarService(api: api, store: store)
        let sync = Task { try await service.sync(accountID: "old-account") }
        while !(await provider.started) { await Task.yield() }
        await service.cancelAllOperations()
        await #expect(throws: CancellationError.self) { try await sync.value }
        #expect(await provider.wasCancelled)
        #expect(fixture.requests().isEmpty)
        // The service remains usable after draining rather than retaining a cancelled coalesced task.
        try await service.sync(accountID: "new-account")
        #expect(fixture.requests().count == 2)
        #expect(try await service.cachedCalendars(accountID: "old-account").isEmpty)
        #expect(try await service.cachedCalendars(accountID: "new-account").count == 1)
    }

    @Test("A confirmed recurring insert remains committed when expansion refresh fails")
    func createdRecurrenceRefreshFailure() async throws {
        let fixture = CalendarHTTPFixture { request, _ in
            if request.httpMethod == "POST" {
                return (200, #"{"id":"new-series","summary":"Weekly","start":{"dateTime":"2026-10-02T12:00:00Z"},"end":{"dateTime":"2026-10-02T13:00:00Z"},"recurrence":["RRULE:FREQ=WEEKLY"]}"#)
            }
            return (403, #"{"error":{"message":"Temporary access failure while refreshing"}}"#)
        }
        let (service, store, token, directory) = try context(fixture)
        defer { cleanup(token: token, directory: directory) }
        let source = CalendarRecord(id: "personal", accountID: "owner", title: "Personal")
        try await store.save(source, id: source.id, collection: "calendar.sources", accountID: "owner")
        let start = try #require(CalendarService.date(GoogleEventDateTime(dateTime: "2026-10-02T12:00:00Z")))
        let event = CalendarEvent(calendarID: "personal", accountID: "owner", title: "Weekly", start: start,
                                  end: start.addingTimeInterval(3_600), recurrence: ["RRULE:FREQ=WEEKLY"])
        await #expect(throws: CalendarWriteCommittedError.self) { _ = try await service.create(event) }
        #expect(fixture.requests().map(\.httpMethod) == ["POST", "GET"])
        #expect(fixture.requests().filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test("An editor keeps its original ETag when a background sync has newer cached data")
    func editorETagSurvivesCacheRefresh() async throws {
        let fixture = CalendarHTTPFixture { _, _ in (412, #"{"error":{"message":"Event changed"}}"#) }
        let (service, store, token, directory) = try context(fixture)
        defer { cleanup(token: token, directory: directory) }
        let source = CalendarRecord(id: "personal", accountID: "owner", title: "Personal")
        try await store.save(source, id: source.id, collection: "calendar.sources", accountID: "owner")
        let raw = try JSONDecoder().decode(GoogleEvent.self, from: Data(Self.instanceJSON.utf8))
        try await store.save(raw, id: raw.id, collection: "calendar.events.personal", accountID: "owner")
        var event = try CalendarService.event(from: raw, calendarID: source.id, accountID: source.accountID)
        event.etag = "editor-version"
        await #expect(throws: GoogleAPIError.self) { _ = try await service.update(event) }
        #expect(fixture.requests().first?.value(forHTTPHeaderField: "If-Match") == "editor-version")
        #expect(try await service.cachedEvents(accountID: "owner").first?.etag == "version-1")
    }

    @Test("A successful calendar move stays cached when the following content edit fails")
    func movePartialSuccess() async throws {
        let rawJSON = #"{"id":"moving","summary":"Original title","start":{"dateTime":"2026-10-02T12:00:00Z"},"end":{"dateTime":"2026-10-02T13:00:00Z"},"etag":"moved-etag"}"#
        let fixture = CalendarHTTPFixture { request, number in
            if request.url!.path.hasSuffix("/move") { return (200, rawJSON) }
            if number == 3 { return (200, rawJSON.replacingOccurrences(of: "Original title", with: "Edited title")) }
            return (400, #"{"error":{"message":"Remaining edits failed"}}"#)
        }
        let (service, store, token, directory) = try context(fixture)
        defer { cleanup(token: token, directory: directory) }
        for id in ["source", "destination"] {
            try await store.save(CalendarRecord(id: id, accountID: "owner", title: id), id: id,
                                 collection: "calendar.sources", accountID: "owner")
        }
        let raw = try JSONDecoder().decode(GoogleEvent.self, from: Data(rawJSON.utf8))
        try await store.save(raw, id: raw.id, collection: "calendar.events.source", accountID: "owner")
        var event = try CalendarService.event(from: raw, calendarID: "source", accountID: "owner")
        event.calendarID = "destination"
        event.title = "Edited title"
        var pending: CalendarEvent?
        do {
            _ = try await service.update(event, originalCalendarID: "source")
            Issue.record("A failed edit after moving must preserve an explicit retry state")
        } catch let error as CalendarMoveIncompleteError {
            pending = error.pendingEvent
        }
        let events = try await service.cachedEvents(accountID: "owner")
        #expect(events.count == 1)
        #expect(events.first?.calendarID == "destination")
        #expect(events.first?.title == "Original title")
        #expect(fixture.requests().map(\.httpMethod) == ["POST", "PATCH"])
        #expect(fixture.requests()[1].value(forHTTPHeaderField: "If-Match") == "moved-etag")
        let retry = try #require(pending)
        #expect(retry.title == "Edited title" && retry.calendarID == "destination" && retry.etag == "moved-etag")
        _ = try await service.update(retry, originalCalendarID: retry.calendarID)
        #expect(fixture.requests().map(\.httpMethod) == ["POST", "PATCH", "PATCH"])
        #expect(try await service.cachedEvents(accountID: "owner").first?.title == "Edited title")
    }

    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, latest in latest })
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any] ?? [:]
    }
}
