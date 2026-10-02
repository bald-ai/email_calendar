import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EmailCalendarCore

final class GoogleAPITests: XCTestCase, @unchecked Sendable {
    func testNormalEventEditDoesNotReplaceAttendeesAndCreationCanIncludeThem() async throws {
        let recorder = GoogleRequestRecorder()
        let json = #"{"id":"event-1","etag":"tag-1","summary":"Planning","start":{"dateTime":"2026-10-02T10:00:00Z"},"end":{"dateTime":"2026-10-02T11:00:00Z"},"attendees":[{"email":"guest@example.com","optional":true,"comment":"Arriving late","responseStatus":"accepted"}]}"#
        let harness = APIHarness { request in
            recorder.append(request)
            return MockGoogleResponse(body: json)
        }
        defer { harness.close() }
        var event = try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
        event.summary = "Renamed planning"
        _ = try await harness.api.updateEvent(calendarID: "primary", event: event)
        let patch = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        let edited = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(patch.httpBody)) as? [String: Any])
        XCTAssertEqual(edited["summary"] as? String, "Renamed planning")
        XCTAssertNil(edited["attendees"], "Omitting guests preserves optional status and response comments in Google.")

        _ = try await harness.api.insertEvent(calendarID: "primary", event: event)
        let insert = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(insert.httpMethod, "POST")
        let created = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(insert.httpBody)) as? [String: Any])
        let guests = try XCTUnwrap(created["attendees"] as? [[String: Any]])
        XCTAssertEqual(guests.first?["optional"] as? Bool, true)
        XCTAssertEqual(guests.first?["comment"] as? String, "Arriving late")
    }

    func testUnauthorizedRequestRefreshesOnceThenRetries() async throws {
        let harness = APIHarness { request in
            if request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("|stale") == true {
                return MockGoogleResponse(status: 401, body: #"{"error":{"message":"Expired"}}"#)
            }
            return MockGoogleResponse(body: #"{"emailAddress":"owner@example.com","historyId":"123"}"#)
        }
        defer { harness.close() }
        let profile = try await harness.api.profile()
        XCTAssertEqual(profile.emailAddress, "owner@example.com")
        let refreshCalls = await harness.auth.calls
        XCTAssertEqual(refreshCalls, [false, true])
    }

    func testCalendarIncrementalRequestOmitsDateBoundsAndHandlesEmptyItems() async throws {
        let recorder = GoogleRequestRecorder()
        let harness = APIHarness { request in
            recorder.append(request)
            return MockGoogleResponse(body: #"{"nextSyncToken":"new-token"}"#)
        }
        defer { harness.close() }
        let page = try await harness.api.events(calendarID: "owner@example.com", syncToken: "old-token",
                                                 timeMin: .now, timeMax: .now.addingTimeInterval(86_400))
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.nextSyncToken, "new-token")
        let request = try XCTUnwrap(recorder.requests.first)
        let url = try XCTUnwrap(request.url)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "syncToken" }?.value, "old-token")
        XCTAssertEqual(query.first { $0.name == "singleEvents" }?.value, "true")
        XCTAssertEqual(query.first { $0.name == "showDeleted" }?.value, "true")
        XCTAssertFalse(query.contains { $0.name == "timeMin" || $0.name == "timeMax" })
    }

    func testExpiredCalendarTokenPreservesHTTPStatusForFullResync() async throws {
        let harness = APIHarness { _ in MockGoogleResponse(status: 410, body: #"{"error":{"message":"Sync token expired"}}"#) }
        defer { harness.close() }
        do {
            _ = try await harness.api.events(calendarID: "primary", syncToken: "expired")
            XCTFail("An expired token must fail for the sync service to reset it.")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.statusCode, 410)
        }
    }

    func testInvitationResponseOnlyWritesTheCurrentAttendee() async throws {
        let recorder = GoogleRequestRecorder()
        let event = #"{"id":"event-1","etag":"tag-1","summary":"Planning","attendees":[{"email":"owner@example.com","self":true,"responseStatus":"needsAction"},{"email":"guest@example.com","responseStatus":"accepted"}]}"#
        let harness = APIHarness { request in
            recorder.append(request)
            return MockGoogleResponse(body: event)
        }
        defer { harness.close() }
        _ = try await harness.api.respondToInvitation(calendarID: "primary", eventID: "event-1",
                                                       email: "owner@example.com", responseStatus: "declined")
        let request = try XCTUnwrap(recorder.requests.first { $0.httpMethod == "PATCH" })
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["summary"])
        XCTAssertNil(json["start"])
        XCTAssertEqual(json["attendeesOmitted"] as? Bool, true)
        let attendees = try XCTUnwrap(json["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.count, 1)
        XCTAssertEqual(attendees.first?["responseStatus"] as? String, "declined")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "tag-1")
    }

    func testSendDoesNotRetryAmbiguousServerFailure() async throws {
        let recorder = GoogleRequestRecorder()
        let harness = APIHarness { request in
            recorder.append(request)
            return MockGoogleResponse(status: 503, body: #"{"error":{"message":"Try later"}}"#)
        }
        defer { harness.close() }
        do {
            _ = try await harness.api.sendMessage(raw: Data("From: owner@example.com\r\n\r\nHello".utf8))
            XCTFail("A server failure must reach the user.")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.statusCode, 503)
        }
        XCTAssertEqual(recorder.requests.count, 1)
    }
}

private actor MockGoogleAuth: GoogleTokenProvider {
    private let id: String
    private(set) var calls: [Bool] = []
    private var token = "stale"
    init(id: String) { self.id = id }
    func accessToken(forceRefresh: Bool) async throws -> String {
        calls.append(forceRefresh)
        if forceRefresh { token = "fresh" }
        return "\(id)|\(token)"
    }
}

private struct APIHarness: Sendable {
    let id = UUID().uuidString
    let auth: MockGoogleAuth
    let api: GoogleAPI
    let session: URLSession

    init(handler: @escaping @Sendable (URLRequest) -> MockGoogleResponse) {
        let auth = MockGoogleAuth(id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGoogleURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockGoogleURLProtocol.registry.register(id: id, handler: handler)
        self.auth = auth
        self.session = session
        self.api = GoogleAPI(auth: auth, session: session)
    }

    func close() {
        session.invalidateAndCancel()
        MockGoogleURLProtocol.registry.remove(id: id)
    }
}

private struct MockGoogleResponse: Sendable {
    var status: Int = 200
    var body: String
}

private final class GoogleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    func append(_ request: URLRequest) { lock.withLock { stored.append(request) } }
}

private final class GoogleMockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (URLRequest) -> MockGoogleResponse] = [:]
    func register(id: String, handler: @escaping @Sendable (URLRequest) -> MockGoogleResponse) {
        lock.withLock { handlers[id] = handler }
    }
    func remove(id: String) { lock.withLock { _ = handlers.removeValue(forKey: id) } }
    func handler(id: String) -> (@Sendable (URLRequest) -> MockGoogleResponse)? { lock.withLock { handlers[id] } }
}

private final class MockGoogleURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = GoogleMockRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer "),
              let id = authorization.dropFirst(7).split(separator: "|").first.map(String.init),
              let handler = Self.registry.handler(id: id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let result = handler(request)
        guard let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
