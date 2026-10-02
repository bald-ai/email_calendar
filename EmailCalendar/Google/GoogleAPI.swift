import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol GoogleTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

public enum GoogleAPIError: Error, LocalizedError, Sendable {
    case http(status: Int, message: String)
    case invalidResponse
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case let .http(status, message): "Google returned \(status): \(message)"
        case .invalidResponse: "Google returned an invalid response."
        case .invalidURL: "The Google request URL is invalid."
        }
    }

    public var statusCode: Int? {
        if case let .http(status, _) = self { status } else { nil }
    }
}

/// One API client can be shared by mail sync, calendar sync, and foreground writes.
public actor GoogleAPI {
    private let auth: any GoogleTokenProvider
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(auth: any GoogleTokenProvider, session: URLSession = .shared) {
        self.auth = auth
        self.session = session
    }

    public func profile() async throws -> GoogleMailProfile {
        try await get(GoogleMailProfile.self, base: .gmail, path: ["profile"])
    }

    public func listThreads(query: String? = nil, labelIDs: [String] = [], pageToken: String? = nil,
                            maxResults: Int = 100) async throws -> GooglePage<GoogleMailThread> {
        let response = try await get(ThreadList.self, base: .gmail, path: ["threads"], query:
            searchQuery(query, labels: labelIDs, pageToken: pageToken, maxResults: maxResults))
        return GooglePage(items: response.threads ?? [], nextPageToken: response.nextPageToken)
    }

    public func thread(id: String, format: String = "full") async throws -> GoogleMailThread {
        try await get(GoogleMailThread.self, base: .gmail, path: ["threads", id], query: [URLQueryItem(name: "format", value: format)])
    }

    public func listMessages(query: String? = nil, labelIDs: [String] = [], pageToken: String? = nil,
                             maxResults: Int = 100) async throws -> GooglePage<GoogleMailMessage> {
        let response = try await get(MessageList.self, base: .gmail, path: ["messages"], query:
            searchQuery(query, labels: labelIDs, pageToken: pageToken, maxResults: maxResults))
        return GooglePage(items: response.messages ?? [], nextPageToken: response.nextPageToken)
    }

    public func message(id: String, format: String = "full") async throws -> GoogleMailMessage {
        try await get(GoogleMailMessage.self, base: .gmail, path: ["messages", id], query: [URLQueryItem(name: "format", value: format)])
    }

    @discardableResult
    public func modifyThread(id: String, addLabelIDs: [String] = [], removeLabelIDs: [String] = []) async throws -> GoogleMailThread {
        try await mutate(GoogleMailThread.self, base: .gmail, path: ["threads", id, "modify"], method: "POST",
                         body: LabelMutation(addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs))
    }

    @discardableResult
    public func modifyMessage(id: String, addLabelIDs: [String] = [], removeLabelIDs: [String] = []) async throws -> GoogleMailMessage {
        try await mutate(GoogleMailMessage.self, base: .gmail, path: ["messages", id, "modify"], method: "POST",
                         body: LabelMutation(addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs))
    }

    /// Gmail Trash is reversible. No permanent deletion endpoint is exposed.
    @discardableResult
    public func trashThread(id: String) async throws -> GoogleMailThread {
        try await mutate(GoogleMailThread.self, base: .gmail, path: ["threads", id, "trash"], method: "POST", body: EmptyBody())
    }

    @discardableResult
    public func untrashThread(id: String) async throws -> GoogleMailThread {
        try await mutate(GoogleMailThread.self, base: .gmail, path: ["threads", id, "untrash"], method: "POST", body: EmptyBody())
    }

    public func labels() async throws -> [GoogleLabel] {
        try await get(LabelList.self, base: .gmail, path: ["labels"]).labels ?? []
    }

    public func createLabel(name: String) async throws -> GoogleLabel {
        try await mutate(GoogleLabel.self, base: .gmail, path: ["labels"], method: "POST", body: LabelCreate(name: name))
    }

    public func history(startHistoryID: String, pageToken: String? = nil) async throws -> GoogleHistoryPage {
        try await get(GoogleHistoryPage.self, base: .gmail, path: ["history"], query: [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "pageToken", value: pageToken), URLQueryItem(name: "maxResults", value: "500")
        ].filter { $0.value != nil })
    }

    public func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let body = try await get(GoogleMailBody.self, base: .gmail, path: ["messages", messageID, "attachments", attachmentID])
        guard let encoded = body.data, let data = Data(base64URL: encoded) else { throw GoogleAPIError.invalidResponse }
        return data
    }

    public func drafts(pageToken: String? = nil) async throws -> GooglePage<GoogleDraft> {
        let response = try await get(DraftList.self, base: .gmail, path: ["drafts"], query:
            [URLQueryItem(name: "pageToken", value: pageToken)].filter { $0.value != nil })
        return GooglePage(items: response.drafts ?? [], nextPageToken: response.nextPageToken)
    }

    public func draft(id: String) async throws -> GoogleDraft {
        try await get(GoogleDraft.self, base: .gmail, path: ["drafts", id], query: [URLQueryItem(name: "format", value: "full")])
    }

    public func createDraft(raw: Data, threadID: String? = nil) async throws -> GoogleDraft {
        try await mutate(GoogleDraft.self, base: .gmail, path: ["drafts"], method: "POST",
                         body: DraftMutation(message: RawMessage(raw: raw.base64URL, threadId: threadID)))
    }

    public func updateDraft(id: String, raw: Data, threadID: String? = nil) async throws -> GoogleDraft {
        try await mutate(GoogleDraft.self, base: .gmail, path: ["drafts", id], method: "PUT",
                         body: DraftMutation(message: RawMessage(raw: raw.base64URL, threadId: threadID)))
    }

    public func sendDraft(id: String) async throws -> GoogleMailMessage {
        try await mutate(GoogleMailMessage.self, base: .gmail, path: ["drafts", "send"], method: "POST", body: IDBody(id: id))
    }

    public func sendMessage(raw: Data, threadID: String? = nil) async throws -> GoogleMailMessage {
        try await mutate(GoogleMailMessage.self, base: .gmail, path: ["messages", "send"], method: "POST",
                         body: RawMessage(raw: raw.base64URL, threadId: threadID))
    }

    public func filters() async throws -> [GoogleFilter] {
        try await get(FilterList.self, base: .gmail, path: ["settings", "filters"]).filter ?? []
    }

    public func createFilter(_ filter: GoogleFilter) async throws -> GoogleFilter {
        try await mutate(GoogleFilter.self, base: .gmail, path: ["settings", "filters"], method: "POST", body: filter)
    }

    public func deleteFilter(id: String) async throws {
        try await delete(base: .gmail, path: ["settings", "filters", id])
    }

    public func calendarList(pageToken: String? = nil) async throws -> GooglePage<GoogleCalendar> {
        try await get(GooglePage<GoogleCalendar>.self, base: .calendar, path: ["users", "me", "calendarList"], query:
            [URLQueryItem(name: "maxResults", value: "250"), URLQueryItem(name: "pageToken", value: pageToken)].filter { $0.value != nil })
    }

    /// Incremental sync preserves the same singleEvents/showDeleted parameters as its initial request.
    /// Google rejects timeMin/timeMax with syncToken, so bounds are sent only for a full sync.
    public func events(calendarID: String, syncToken: String? = nil, pageToken: String? = nil,
                       timeMin: Date? = nil, timeMax: Date? = nil, singleEvents: Bool = true,
                       showDeleted: Bool = true) async throws -> GooglePage<GoogleEvent> {
        var query = [URLQueryItem(name: "maxResults", value: "2500"),
                     URLQueryItem(name: "singleEvents", value: singleEvents ? "true" : "false"),
                     URLQueryItem(name: "showDeleted", value: showDeleted ? "true" : "false"),
                     URLQueryItem(name: "pageToken", value: pageToken), URLQueryItem(name: "syncToken", value: syncToken)]
        if syncToken == nil {
            query.append(URLQueryItem(name: "timeMin", value: timeMin.map(Self.timestamp)))
            query.append(URLQueryItem(name: "timeMax", value: timeMax.map(Self.timestamp)))
        }
        return try await get(GooglePage<GoogleEvent>.self, base: .calendar, path: ["calendars", calendarID, "events"],
                             query: query.filter { $0.value != nil })
    }

    public func event(calendarID: String, id: String) async throws -> GoogleEvent {
        try await get(GoogleEvent.self, base: .calendar, path: ["calendars", calendarID, "events", id])
    }

    public func insertEvent(calendarID: String, event: GoogleEvent, sendUpdates: String = "all") async throws -> GoogleEvent {
        try await mutate(GoogleEvent.self, base: .calendar, path: ["calendars", calendarID, "events"], method: "POST",
                         query: [URLQueryItem(name: "sendUpdates", value: sendUpdates)], body: EventMutation(event, includeAttendees: true))
    }

    public func updateEvent(calendarID: String, event: GoogleEvent, sendUpdates: String = "all") async throws -> GoogleEvent {
        try await patchEvent(calendarID: calendarID, eventID: event.id, event: event, sendUpdates: sendUpdates)
    }

    public func patchEvent(calendarID: String, eventID: String, event: GoogleEvent, sendUpdates: String = "all") async throws -> GoogleEvent {
        try await mutate(GoogleEvent.self, base: .calendar, path: ["calendars", calendarID, "events", eventID], method: "PATCH",
                         query: [URLQueryItem(name: "sendUpdates", value: sendUpdates)], body: EventMutation(event), etag: event.etag)
    }

    public func deleteEvent(calendarID: String, eventID: String, sendUpdates: String = "all") async throws {
        try await delete(base: .calendar, path: ["calendars", calendarID, "events", eventID],
                         query: [URLQueryItem(name: "sendUpdates", value: sendUpdates)])
    }

    public func moveEvent(calendarID: String, eventID: String, destinationCalendarID: String,
                          sendUpdates: String = "all") async throws -> GoogleEvent {
        try await mutate(GoogleEvent.self, base: .calendar, path: ["calendars", calendarID, "events", eventID, "move"],
                         method: "POST", query: [URLQueryItem(name: "destination", value: destinationCalendarID),
                         URLQueryItem(name: "sendUpdates", value: sendUpdates)], body: EmptyBody())
    }

    public func respondToInvitation(calendarID: String, eventID: String, email: String,
                                    responseStatus: String) async throws -> GoogleEvent {
        let current = try await event(calendarID: calendarID, id: eventID)
        guard let attendees = current.attendees,
              let index = attendees.firstIndex(where: { $0.isSelf == true || $0.email?.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw GoogleAPIError.http(status: 400, message: "Your account is not an attendee of this event.")
        }
        var attendee = attendees[index]
        attendee.responseStatus = responseStatus
        return try await mutate(GoogleEvent.self, base: .calendar, path: ["calendars", calendarID, "events", eventID],
                                method: "PATCH", query: [URLQueryItem(name: "sendUpdates", value: "all")],
                                body: AttendeeMutation(attendees: [attendee]), etag: current.etag)
    }

    private enum Base: String {
        case gmail = "https://gmail.googleapis.com/gmail/v1/users/me"
        case calendar = "https://www.googleapis.com/calendar/v3"
    }

    private func endpoint(base: Base, path: [String], query: [URLQueryItem] = []) throws -> URL {
        guard var url = URL(string: base.rawValue) else { throw GoogleAPIError.invalidURL }
        for component in path { url.appendPathComponent(component) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw GoogleAPIError.invalidURL }
        if !query.isEmpty { components.queryItems = query }
        guard let result = components.url else { throw GoogleAPIError.invalidURL }
        return result
    }

    private func get<T: Decodable & Sendable>(_ type: T.Type, base: Base, path: [String], query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(url: endpoint(base: base, path: path, query: query), method: "GET")
        return try decoder.decode(type, from: data)
    }

    private func mutate<T: Decodable & Sendable, B: Encodable & Sendable>(_ type: T.Type, base: Base, path: [String],
        method: String, query: [URLQueryItem] = [], body: B, etag: String? = nil) async throws -> T {
        let data = try await request(url: endpoint(base: base, path: path, query: query), method: method,
                                     body: encoder.encode(body), etag: etag)
        return try decoder.decode(type, from: data)
    }

    private func delete(base: Base, path: [String], query: [URLQueryItem] = []) async throws {
        _ = try await request(url: endpoint(base: base, path: path, query: query), method: "DELETE")
    }

    private func request(url: URL, method: String, body: Data? = nil, etag: String? = nil) async throws -> Data {
        var transientAttempts = 0
        var refreshNextAttempt = false
        var hasRefreshedToken = false
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.httpBody = body
            request.setValue("Bearer \(try await auth.accessToken(forceRefresh: refreshNextAttempt))", forHTTPHeaderField: "Authorization")
            // Subsequent transient retries can reuse the freshly stored token.
            refreshNextAttempt = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw GoogleAPIError.invalidResponse }
            if (200..<300).contains(response.statusCode) { return data }
            if response.statusCode == 401, !hasRefreshedToken {
                refreshNextAttempt = true
                hasRefreshedToken = true
                continue
            }
            // Repeating a send or insert after a server failure could create duplicates.
            if method == "GET", [429, 500, 502, 503, 504].contains(response.statusCode), transientAttempts < 3 {
                let retry = min(30, max(0.5, response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(transientAttempts))))
                transientAttempts += 1
                try await Task.sleep(for: .seconds(retry))
                continue
            }
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw GoogleAPIError.http(status: response.statusCode, message: message)
        }
    }

    private func searchQuery(_ query: String?, labels: [String], pageToken: String?, maxResults: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "q", value: query), URLQueryItem(name: "pageToken", value: pageToken),
         URLQueryItem(name: "maxResults", value: String(min(500, max(1, maxResults)))),
         URLQueryItem(name: "includeSpamTrash", value: "false")].filter { $0.value != nil }
        + labels.map { URLQueryItem(name: "labelIds", value: $0) }
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private struct ThreadList: Decodable, Sendable { var threads: [GoogleMailThread]?; var nextPageToken: String? }
    private struct MessageList: Decodable, Sendable { var messages: [GoogleMailMessage]?; var nextPageToken: String? }
    private struct LabelList: Decodable, Sendable { var labels: [GoogleLabel]? }
    private struct DraftList: Decodable, Sendable { var drafts: [GoogleDraft]?; var nextPageToken: String? }
    private struct FilterList: Decodable, Sendable { var filter: [GoogleFilter]? }
    private struct ErrorEnvelope: Decodable { var error: Detail; struct Detail: Decodable { var message: String } }
    private struct LabelMutation: Encodable, Sendable { var addLabelIds: [String]; var removeLabelIds: [String] }
    private struct LabelCreate: Encodable, Sendable {
        var name: String
        let messageListVisibility = "show"
        let labelListVisibility = "labelShow"
    }
    private struct RawMessage: Encodable, Sendable { var raw: String; var threadId: String? }
    private struct DraftMutation: Encodable, Sendable { var message: RawMessage }
    private struct IDBody: Encodable, Sendable { var id: String }
    private struct EmptyBody: Encodable, Sendable {}
    private struct AttendeeMutation: Encodable, Sendable {
        var attendees: [GoogleAttendee]
        let attendeesOmitted = true
    }
    private struct EventMutation: Encodable, Sendable {
        var summary: String?
        var description: String?
        var location: String?
        var start: GoogleEventDateTime?
        var end: GoogleEventDateTime?
        var recurrence: [String]?
        var attendees: [GoogleAttendee]?
        var status: String?
        var transparency: String?

        init(_ event: GoogleEvent, includeAttendees: Bool = false) {
            summary = event.summary
            description = event.description
            location = event.location
            start = event.start
            end = event.end
            recurrence = event.recurrence
            // PATCH replaces arrays. The editor does not edit guests, so preserve
            // their full Google metadata by leaving attendees out of normal edits.
            // New event creation and the separate RSVP mutation may include guests.
            attendees = includeAttendees ? event.attendees : nil
            status = event.status
            transparency = event.transparency
        }
    }
}
