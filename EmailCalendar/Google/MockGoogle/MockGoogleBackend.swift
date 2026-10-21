import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An in-process stand-in for the Gmail and Calendar REST APIs.
///
/// It speaks the same JSON as Google, so MailService and CalendarService run their real
/// sync, label, filter, draft and recurrence code against it. State is persisted to a JSON
/// file, so changes survive relaunches. Connecting real Google later only swaps the transport.
public final class MockGoogleBackend: @unchecked Sendable {
    public static let accountEmail = "you@example.com"
    public static let accountName = "Alex Rivera"

    private let lock = NSLock()
    private let fileURL: URL?
    private var state: MockState
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL?, now: Date = .now) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(MockState.self, from: data) {
            state = saved
        } else {
            state = MockSeed.make(now: now)
        }
        if (state.seedVersion ?? 1) < 4 {
            // Existing demo data is upgraded in place, without a reset: the generated filler is
            // replaced (version 4 has about half as many events); seeded and your own events stay.
            MockSeed.addBusyCalendar(into: &state, now: now)
            state.seedVersion = 4
        }
        persist()
    }

    /// The default on-disk location, kept apart from any future real-account data.
    public static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent("EmailCalendar/Mock", isDirectory: true).appendingPathComponent("google.json")
    }

    // MARK: Simulation hooks

    /// Delivers a new incoming email, applying Gmail filters like the real server would.
    @discardableResult
    public func simulateIncomingMail(now: Date = .now) -> String {
        locked {
            let template = MockSeed.nextArrival(index: state.simulatedCount, knownThreads: state.threadIDs(), state: state)
            state.simulatedCount += 1
            return deliver(template, now: now)
        }
    }

    // MARK: Request handling

    func handle(_ request: URLRequest) -> (status: Int, body: Data) {
        locked {
            guard let url = request.url else { return error(400, "Missing URL") }
            let method = request.httpMethod ?? "GET"
            let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
            let multi = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            let body = request.httpBody ?? Data()
            let path = url.path
            do {
                if let range = path.range(of: "/gmail/v1/users/me/") {
                    let parts = path[range.upperBound...].split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
                    return try gmail(method: method, parts: parts, query: query, labelIDs: multi.filter { $0.name == "labelIds" }.compactMap(\.value), body: body)
                }
                if let range = path.range(of: "/calendar/v3/") {
                    let parts = path[range.upperBound...].split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
                    return try calendar(method: method, parts: parts, query: query, body: body)
                }
                return error(404, "Unknown endpoint \(path)")
            } catch let failure as MockFailure {
                return error(failure.status, failure.message)
            } catch {
                return self.error(400, error.localizedDescription)
            }
        }
    }

    // MARK: Gmail

    private func gmail(method: String, parts: [String], query: [String: String], labelIDs: [String], body: Data) throws -> (Int, Data) {
        switch (method, parts.first, parts.count) {
        case ("GET", "profile", 1):
            return ok(GoogleMailProfile(emailAddress: Self.accountEmail, messagesTotal: state.messages.count,
                                        threadsTotal: state.threadIDs().count, historyId: String(state.historyID)))
        case ("GET", "labels", 1):
            return ok(["labels": state.labels])
        case ("POST", "labels", 1):
            let name = try decode(NameBody.self, body).name
            guard !state.labels.contains(where: { $0.name == name }) else { throw MockFailure(409, "Label name exists or conflicts") }
            state.labelCounter += 1
            let label = GoogleLabel(id: "Label_\(state.labelCounter)", name: name, type: "user",
                                    messageListVisibility: "show", labelListVisibility: "labelShow")
            state.labels.append(label)
            return saved(label)
        case ("GET", "threads", 1):
            let ids = matchingThreads(query: query["q"], labelIDs: labelIDs)
            let page = paginate(ids, query: query)
            return ok(ThreadListBody(threads: page.items.map { id in
                GoogleMailThread(id: id, historyId: String(state.historyID), snippet: state.thread(id).last?.snippet, messages: nil)
            }, nextPageToken: page.next))
        case ("GET", "threads", 2):
            let messages = state.thread(parts[1])
            guard !messages.isEmpty else { throw MockFailure(404, "Requested entity was not found.") }
            return ok(threadJSON(parts[1]))
        case ("POST", "threads", 3):
            let id = parts[1]
            guard !state.thread(id).isEmpty else { throw MockFailure(404, "Requested entity was not found.") }
            switch parts[2] {
            case "modify":
                let change = try decode(LabelChangeBody.self, body)
                for message in state.thread(id) { try relabel(message.id, add: change.addLabelIds ?? [], remove: change.removeLabelIds ?? []) }
            case "trash":
                for message in state.thread(id) { try relabel(message.id, add: ["TRASH"], remove: ["INBOX"]) }
            case "untrash":
                for message in state.thread(id) { try relabel(message.id, add: [], remove: ["TRASH"]) }
            default: throw MockFailure(404, "Unknown thread action")
            }
            return saved(threadJSON(id))
        case ("GET", "messages", 1):
            let ids = matchingThreads(query: query["q"], labelIDs: labelIDs, messages: true)
            let page = paginate(ids, query: query)
            return ok(MessageListBody(messages: page.items.compactMap { id in
                state.messages[id].map { GoogleMailMessage(id: $0.id, threadId: $0.threadId) }
            }, nextPageToken: page.next))
        case ("POST", "messages", 2) where parts[1] == "send":
            let raw = try decode(RawBody.self, body)
            let message = try storeRaw(raw.raw, threadID: raw.threadId, labels: ["SENT"])
            return saved(messageJSON(message))
        case ("GET", "messages", 2):
            guard let message = state.messages[parts[1]] else { throw MockFailure(404, "Requested entity was not found.") }
            return ok(messageJSON(message))
        case ("POST", "messages", 3) where parts[2] == "modify":
            let change = try decode(LabelChangeBody.self, body)
            try relabel(parts[1], add: change.addLabelIds ?? [], remove: change.removeLabelIds ?? [])
            return saved(messageJSON(state.messages[parts[1]]!))
        case ("GET", "messages", 4) where parts[2] == "attachments":
            guard let attachment = state.messages[parts[1]]?.attachments.first(where: { $0.id == parts[3] }) else {
                throw MockFailure(404, "Requested entity was not found.")
            }
            return ok(GoogleMailBody(attachmentId: attachment.id, size: attachment.data.count, data: attachment.data.base64URL))
        case ("GET", "history", 1):
            let start = Int(query["startHistoryId"] ?? "") ?? 0
            if !state.firstArrivalsDelivered {
                // The first incremental sync brings mail from unknown senders, so the Screener has work.
                state.firstArrivalsDelivered = true
                for index in [0, 2, 3] { _ = deliver(MockSeed.nextArrival(index: index, knownThreads: state.threadIDs(), state: state), now: .now) }
                state.simulatedCount = 4
            }
            guard start >= state.oldestHistoryID else { throw MockFailure(404, "Requested entity was not found.") }
            let records = state.history.filter { $0.id > start }.map { record in
                GoogleHistoryRecord(id: String(record.id), messages: [GoogleMailMessage(id: record.messageID, threadId: record.threadID)])
            }
            return ok(GoogleHistoryPage(history: records, nextPageToken: nil, historyId: String(state.historyID)))
        case ("GET", "drafts", 1):
            return ok(DraftListBody(drafts: state.drafts.map { draft in
                GoogleDraft(id: draft.key, message: state.messages[draft.value].map { GoogleMailMessage(id: $0.id, threadId: $0.threadId) })
            }))
        case ("GET", "drafts", 2):
            guard let messageID = state.drafts[parts[1]], let message = state.messages[messageID] else { throw MockFailure(404, "Requested entity was not found.") }
            return ok(GoogleDraft(id: parts[1], message: messageJSON(message)))
        case ("POST", "drafts", 1):
            let raw = try decode(DraftBody.self, body).message
            let message = try storeRaw(raw.raw, threadID: raw.threadId, labels: ["DRAFT"])
            state.idCounter += 1
            let id = "r\(state.idCounter)"
            state.drafts[id] = message.id
            return saved(GoogleDraft(id: id, message: messageJSON(message)))
        case ("PUT", "drafts", 2):
            guard let oldID = state.drafts[parts[1]] else { throw MockFailure(404, "Requested entity was not found.") }
            let raw = try decode(DraftBody.self, body).message
            let threadID = state.messages[oldID]?.threadId ?? raw.threadId
            removeMessage(oldID)
            let message = try storeRaw(raw.raw, threadID: threadID, labels: ["DRAFT"])
            state.drafts[parts[1]] = message.id
            return saved(GoogleDraft(id: parts[1], message: messageJSON(message)))
        case ("POST", "drafts", 2) where parts[1] == "send":
            let id = try decode(IDBody.self, body).id
            guard let messageID = state.drafts.removeValue(forKey: id), var message = state.messages[messageID] else {
                throw MockFailure(404, "Requested entity was not found.")
            }
            message.labelIds = message.labelIds.subtracting(["DRAFT"]).union(["SENT"])
            message.internalDate = Int64(Date.now.timeIntervalSince1970 * 1_000)
            state.messages[messageID] = message
            recordHistory(message)
            return saved(messageJSON(message))
        case ("GET", "settings", 2) where parts[1] == "sendAs":
            return ok(["sendAs": [GoogleSendAs(sendAsEmail: Self.accountEmail, isPrimary: true)]])
        case ("GET", "settings", 2) where parts[1] == "filters":
            return ok(["filter": state.filters])
        case ("POST", "settings", 2) where parts[1] == "filters":
            var filter = try decode(GoogleFilter.self, body)
            state.idCounter += 1
            filter.id = "ANe1Bm\(state.idCounter)"
            state.filters.append(filter)
            return saved(filter)
        case ("DELETE", "settings", 3) where parts[1] == "filters":
            guard let index = state.filters.firstIndex(where: { $0.id == parts[2] }) else { throw MockFailure(404, "Filter not found") }
            state.filters.remove(at: index)
            persist()
            return (204, Data())
        default:
            throw MockFailure(404, "Unknown Gmail endpoint \(method) \(parts.joined(separator: "/"))")
        }
    }

    private func relabel(_ messageID: String, add: [String], remove: [String]) throws {
        guard var message = state.messages[messageID] else { throw MockFailure(404, "Requested entity was not found.") }
        for label in add + remove where !Self.systemLabels.contains(label) && !state.labels.contains(where: { $0.id == label }) {
            throw MockFailure(400, "Invalid label: \(label)")
        }
        let updated = message.labelIds.union(add).subtracting(remove)
        guard updated != message.labelIds else { return }
        message.labelIds = updated
        state.messages[messageID] = message
        recordHistory(message)
    }

    private func recordHistory(_ message: MockMessage) {
        state.historyID += 1
        state.history.append(MockHistory(id: state.historyID, messageID: message.id, threadID: message.threadId))
        if state.history.count > 2_000 {
            state.history.removeFirst(state.history.count - 2_000)
            state.oldestHistoryID = state.history.first.map { $0.id - 1 } ?? state.historyID
        }
    }

    private func removeMessage(_ id: String) {
        guard let message = state.messages.removeValue(forKey: id) else { return }
        recordHistory(message)
    }

    private func storeRaw(_ raw: String, threadID: String?, labels: Set<String>) throws -> MockMessage {
        guard let data = Data(base64URL: raw) else { throw MockFailure(400, "Invalid raw message") }
        let parsed = MockMIME.parse(data)
        state.idCounter += 1
        let id = String(format: "18f%013x", state.idCounter)
        let thread = threadID.flatMap { state.thread($0).isEmpty ? nil : $0 } ?? id
        let message = MockMessage(id: id, threadId: thread, labelIds: labels,
                                  internalDate: Int64(Date.now.timeIntervalSince1970 * 1_000),
                                  headers: parsed.headers, plain: parsed.plain, html: parsed.html,
                                  attachments: parsed.attachments.map { attachment in
                                      state.idCounter += 1
                                      return MockAttachment(id: "att\(state.idCounter)", filename: attachment.filename,
                                                            mimeType: attachment.mimeType, data: attachment.data)
                                  })
        state.messages[id] = message
        recordHistory(message)
        return message
    }

    private func deliver(_ template: MockSeed.Arrival, now: Date) -> String {
        state.idCounter += 1
        let id = String(format: "18f%013x", state.idCounter)
        var labels: Set<String> = ["INBOX", "UNREAD"]
        let sender = MailMapping.addresses(template.from).first?.email ?? ""
        for filter in state.filters where Self.filter(filter, matches: sender) {
            labels.formUnion(filter.action.addLabelIds ?? [])
            labels.subtract(filter.action.removeLabelIds ?? [])
        }
        var headers = [GoogleMailHeader(name: "From", value: template.from),
                       GoogleMailHeader(name: "To", value: "\(Self.accountName) <\(Self.accountEmail)>"),
                       GoogleMailHeader(name: "Subject", value: template.subject),
                       GoogleMailHeader(name: "Message-ID", value: "<\(id)@mock.example>")]
        if let threadID = template.threadID, let parent = state.thread(threadID).last,
           let parentID = parent.headers.first(where: { $0.name == "Message-ID" })?.value {
            headers.append(GoogleMailHeader(name: "In-Reply-To", value: parentID))
        }
        let message = MockMessage(id: id, threadId: template.threadID ?? id, labelIds: labels,
                                  internalDate: Int64(now.timeIntervalSince1970 * 1_000), headers: headers,
                                  plain: template.body, html: template.html, attachments: [])
        state.messages[id] = message
        recordHistory(message)
        persist()
        return id
    }

    private static func filter(_ filter: GoogleFilter, matches sender: String) -> Bool {
        guard let from = filter.criteria.from?.lowercased() else { return false }
        let matches = from.hasPrefix("@") ? sender.hasSuffix(from) : sender == from
        guard matches else { return false }
        let exceptions = (filter.criteria.negatedQuery ?? "").lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "{} ")).filter { $0.hasPrefix("from:") }.map { String($0.dropFirst(5)) }
        return !exceptions.contains(sender)
    }

    private func matchingThreads(query: String?, labelIDs: [String], messages: Bool = false) -> [String] {
        let terms = MockQuery(query ?? "")
        let candidates = state.messages.values.filter { message in
            labelIDs.allSatisfy(message.labelIds.contains)
                && (terms.includesTrash || labelIDs.contains("TRASH") || !message.labelIds.contains("TRASH"))
                && !message.labelIds.contains("SPAM")
                && terms.matches(message, labels: state.labels)
        }
        let sorted = candidates.sorted { $0.internalDate > $1.internalDate }
        if messages { return sorted.map(\.id) }
        var seen = Set<String>(), result: [String] = []
        for message in sorted where seen.insert(message.threadId).inserted { result.append(message.threadId) }
        return result
    }

    private func threadJSON(_ id: String) -> GoogleMailThread {
        let messages = state.thread(id)
        return GoogleMailThread(id: id, historyId: String(state.historyID), snippet: messages.last?.snippet,
                                messages: messages.map(messageJSON))
    }

    private func messageJSON(_ message: MockMessage) -> GoogleMailMessage {
        let plainPart = GoogleMailPart(partId: "0.0", mimeType: "text/plain", filename: "", headers: [],
                                       body: GoogleMailBody(size: message.plain.utf8.count, data: Data(message.plain.utf8).base64URL))
        var bodyParts = [plainPart]
        if let html = message.html {
            bodyParts.append(GoogleMailPart(partId: "0.1", mimeType: "text/html", filename: "", headers: [],
                                            body: GoogleMailBody(size: html.utf8.count, data: Data(html.utf8).base64URL)))
        }
        let content = GoogleMailPart(partId: "0", mimeType: "multipart/alternative", filename: "", headers: [], body: GoogleMailBody(size: 0), parts: bodyParts)
        let attachments = message.attachments.enumerated().map { index, attachment in
            GoogleMailPart(partId: "\(index + 1)", mimeType: attachment.mimeType, filename: attachment.filename, headers: [],
                           body: GoogleMailBody(attachmentId: attachment.id, size: attachment.data.count))
        }
        let payload = GoogleMailPart(partId: "", mimeType: "multipart/mixed", filename: "", headers: message.headers,
                                     body: GoogleMailBody(size: 0), parts: [content] + attachments)
        return GoogleMailMessage(id: message.id, threadId: message.threadId, labelIds: message.labelIds.sorted(),
                                 snippet: message.snippet, historyId: String(state.historyID),
                                 internalDate: String(message.internalDate), payload: payload,
                                 sizeEstimate: message.plain.utf8.count)
    }

    static let systemLabels: Set<String> = ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED", "IMPORTANT",
                                            "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    // MARK: Calendar

    private func calendar(method: String, parts: [String], query: [String: String], body: Data) throws -> (Int, Data) {
        if method == "GET", parts == ["users", "me", "calendarList"] {
            return ok(GooglePage(items: state.calendars))
        }
        guard parts.count >= 3, parts[0] == "calendars", parts[2] == "events" else {
            throw MockFailure(404, "Unknown Calendar endpoint \(parts.joined(separator: "/"))")
        }
        let calendarID = parts[1]
        guard let calendar = state.calendars.first(where: { $0.id == calendarID }) else { throw MockFailure(404, "Not Found") }
        let writable = calendar.accessRole == "owner" || calendar.accessRole == "writer"
        switch (method, parts.count) {
        case ("GET", 3):
            return ok(try listEvents(calendarID: calendarID, query: query))
        case ("POST", 3):
            guard writable else { throw MockFailure(403, "You need to have writer access to this calendar.") }
            let patch = try decode(MockEventBody.self, body)
            if let id = patch.id, state.events.contains(where: { $0.calendarID == calendarID && $0.event.id == id }) {
                throw MockFailure(409, "Event ID already exists")
            }
            state.idCounter += 1
            var event = GoogleEvent(id: patch.id ?? "ev\(state.idCounter)", summary: patch.summary ?? "", start: patch.start ?? GoogleEventDateTime(),
                                    end: patch.end ?? GoogleEventDateTime(), description: patch.description, location: patch.location,
                                    recurrence: patch.recurrence?.isEmpty == true ? nil : patch.recurrence, attendees: patch.attendees)
            event.status = "confirmed"
            event.organizer = selfAttendee()
            event.creator = selfAttendee()
            stamp(&event)
            state.events.append(MockEvent(calendarID: calendarID, event: event, version: bumpVersion()))
            return saved(event)
        case ("GET", 4):
            return ok(try currentEvent(calendarID: calendarID, id: parts[3]))
        case ("PATCH", 4), ("PUT", 4):
            guard writable else { throw MockFailure(403, "You need to have writer access to this calendar.") }
            return saved(try patchEvent(calendarID: calendarID, id: parts[3], body: body))
        case ("DELETE", 4):
            guard writable else { throw MockFailure(403, "You need to have writer access to this calendar.") }
            try deleteEvent(calendarID: calendarID, id: parts[3])
            persist()
            return (204, Data())
        case ("POST", 5) where parts[4] == "move":
            guard writable, let destination = query["destination"],
                  state.calendars.contains(where: { $0.id == destination }) else { throw MockFailure(400, "Invalid destination") }
            guard let index = state.events.firstIndex(where: { $0.calendarID == calendarID && $0.event.id == parts[3] && !$0.deleted }) else {
                throw MockFailure(404, "Not Found")
            }
            var moved = state.events[index]
            state.events[index].deleted = true
            state.events[index].version = bumpVersion()
            moved.calendarID = destination
            stamp(&moved.event)
            moved.version = bumpVersion()
            state.events.append(moved)
            return saved(moved.event)
        default:
            throw MockFailure(404, "Unknown Calendar endpoint \(method) \(parts.joined(separator: "/"))")
        }
    }

    private func listEvents(calendarID: String, query: [String: String]) throws -> GooglePage<GoogleEvent> {
        let window: (min: Date, max: Date, since: Int)
        if let token = query["syncToken"] {
            guard let data = Data(base64URL: token), let decoded = try? decoder.decode(SyncToken.self, from: data) else {
                throw MockFailure(410, "Sync token is no longer valid, a full sync is required.")
            }
            window = (decoded.min, decoded.max, decoded.version)
        } else {
            let parse = { (value: String?) in value.flatMap { CalendarService.date(GoogleEventDateTime(dateTime: $0)) } }
            window = (parse(query["timeMin"]) ?? .distantPast, parse(query["timeMax"]) ?? .distantFuture, -1)
        }
        var items: [GoogleEvent] = []
        for stored in state.events where stored.calendarID == calendarID && stored.version > window.since {
            let isSeries = stored.event.recurrence?.isEmpty == false
            if stored.deleted || (isSeries && window.since >= 0) {
                if window.since >= 0 { items.append(cancelled(stored.event.id)) }
                if stored.deleted { continue }
            }
            if isSeries {
                items += MockRecurrence.instances(of: stored, from: window.min, to: window.max)
            } else if overlaps(stored.event, window.min, window.max) {
                items.append(stored.event)
            } else if window.since >= 0 {
                items.append(cancelled(stored.event.id))
            }
        }
        let token = SyncToken(version: state.calendarVersion, min: window.min, max: window.max)
        return GooglePage(items: items, nextSyncToken: (try? encoder.encode(token))?.base64URL)
    }

    private func currentEvent(calendarID: String, id: String) throws -> GoogleEvent {
        if let stored = state.events.first(where: { $0.calendarID == calendarID && $0.event.id == id && !$0.deleted }) {
            return stored.event
        }
        guard let (index, start) = seriesIndex(calendarID: calendarID, instanceID: id),
              let instance = MockRecurrence.instance(of: state.events[index], originalStart: start) else {
            throw MockFailure(404, "Not Found")
        }
        return instance
    }

    private func patchEvent(calendarID: String, id: String, body: Data) throws -> GoogleEvent {
        let patch = try decode(MockEventBody.self, body)
        if let index = state.events.firstIndex(where: { $0.calendarID == calendarID && $0.event.id == id && !$0.deleted }) {
            var event = state.events[index].event
            apply(patch, to: &event, isInstance: false)
            stamp(&event)
            state.events[index].event = event
            state.events[index].version = bumpVersion()
            return event
        }
        guard let (index, start) = seriesIndex(calendarID: calendarID, instanceID: id),
              var instance = MockRecurrence.instance(of: state.events[index], originalStart: start) else {
            throw MockFailure(404, "Not Found")
        }
        apply(patch, to: &instance, isInstance: true)
        stamp(&instance)
        state.events[index].exceptions[id] = instance
        state.events[index].version = bumpVersion()
        return instance
    }

    private func deleteEvent(calendarID: String, id: String) throws {
        if let index = state.events.firstIndex(where: { $0.calendarID == calendarID && $0.event.id == id && !$0.deleted }) {
            state.events[index].deleted = true
            state.events[index].version = bumpVersion()
            return
        }
        guard let (index, start) = seriesIndex(calendarID: calendarID, instanceID: id),
              var instance = MockRecurrence.instance(of: state.events[index], originalStart: start) else {
            throw MockFailure(410, "Resource has been deleted")
        }
        instance.status = "cancelled"
        state.events[index].exceptions[id] = instance
        state.events[index].version = bumpVersion()
    }

    private func seriesIndex(calendarID: String, instanceID: String) -> (Int, Date)? {
        guard let separator = instanceID.lastIndex(of: "_") else { return nil }
        let masterID = String(instanceID[..<separator])
        guard let start = MockRecurrence.parseInstanceStamp(String(instanceID[instanceID.index(after: separator)...])),
              let index = state.events.firstIndex(where: { $0.calendarID == calendarID && $0.event.id == masterID && !$0.deleted }) else { return nil }
        return (index, start)
    }

    private func apply(_ patch: MockEventBody, to event: inout GoogleEvent, isInstance: Bool) {
        if let value = patch.summary { event.summary = value }
        if let value = patch.description { event.description = value }
        if let value = patch.location { event.location = value }
        if let value = patch.start { event.start = value }
        if let value = patch.end { event.end = value }
        if let value = patch.status { event.status = value }
        if let value = patch.transparency { event.transparency = value }
        if !isInstance, let value = patch.recurrence { event.recurrence = value.isEmpty ? nil : value }
        if let attendees = patch.attendees {
            if patch.attendeesOmitted == true {
                // An RSVP patch names only the changed attendee; keep everyone else.
                var merged = event.attendees ?? []
                for attendee in attendees {
                    if let index = merged.firstIndex(where: { $0.email?.lowercased() == attendee.email?.lowercased() }) {
                        merged[index].responseStatus = attendee.responseStatus
                    } else { merged.append(attendee) }
                }
                event.attendees = merged
            } else { event.attendees = attendees }
        }
    }

    private func overlaps(_ event: GoogleEvent, _ min: Date, _ max: Date) -> Bool {
        guard let start = CalendarService.date(event.start), let end = CalendarService.date(event.end) else { return false }
        return start < max && end > min
    }

    private func cancelled(_ id: String) -> GoogleEvent {
        var event = GoogleEvent(id: id, summary: "", start: GoogleEventDateTime(), end: GoogleEventDateTime())
        event.status = "cancelled"
        return event
    }

    private func stamp(_ event: inout GoogleEvent) {
        state.idCounter += 1
        event.etag = "\"\(state.idCounter)\""
        event.updated = ISO8601DateFormatter().string(from: .now)
    }

    private func bumpVersion() -> Int {
        state.calendarVersion += 1
        return state.calendarVersion
    }

    private func selfAttendee() -> GoogleAttendee {
        var attendee = GoogleAttendee(email: Self.accountEmail, responseStatus: "accepted")
        attendee.isSelf = true
        attendee.displayName = Self.accountName
        return attendee
    }

    // MARK: Plumbing

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func paginate(_ ids: [String], query: [String: String]) -> (items: [String], next: String?) {
        let offset = Int(query["pageToken"] ?? "") ?? 0
        let size = Int(query["maxResults"] ?? "") ?? 100
        let end = min(ids.count, offset + size)
        guard offset < end else { return ([], nil) }
        return (Array(ids[offset..<end]), end < ids.count ? String(end) : nil)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw MockFailure(400, "Invalid request body") }
    }

    private func ok<T: Encodable>(_ value: T) -> (Int, Data) {
        (200, (try? encoder.encode(value)) ?? Data("{}".utf8))
    }

    private func saved<T: Encodable>(_ value: T) -> (Int, Data) {
        persist()
        return ok(value)
    }

    private func error(_ status: Int, _ message: String) -> (Int, Data) {
        (status, (try? encoder.encode(["error": ["code": "\(status)", "message": message]])) ?? Data())
    }

    private func persist() {
        guard let fileURL, let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct MockFailure: Error { var status: Int; var message: String; init(_ s: Int, _ m: String) { status = s; message = m } }
    private struct SyncToken: Codable { var version: Int; var min: Date; var max: Date }
    private struct NameBody: Decodable { var name: String }
    private struct IDBody: Decodable { var id: String }
    private struct RawBody: Decodable { var raw: String; var threadId: String? }
    private struct DraftBody: Decodable { var message: RawBody }
    private struct LabelChangeBody: Decodable { var addLabelIds: [String]?; var removeLabelIds: [String]? }
    private struct ThreadListBody: Encodable { var threads: [GoogleMailThread]; var nextPageToken: String? }
    private struct MessageListBody: Encodable { var messages: [GoogleMailMessage]; var nextPageToken: String? }
    private struct DraftListBody: Encodable { var drafts: [GoogleDraft] }
    private struct MockEventBody: Decodable {
        var id: String?
        var summary: String?, description: String?, location: String?
        var start: GoogleEventDateTime?, end: GoogleEventDateTime?
        var recurrence: [String]?, attendees: [GoogleAttendee]?
        var status: String?, transparency: String?, attendeesOmitted: Bool?
    }
}

/// Routes URLSession traffic for the Google hosts to a MockGoogleBackend.
public final class MockGoogleURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) public static var backend: MockGoogleBackend?

    public override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "gmail.googleapis.com" || host == "www.googleapis.com"
    }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let backend = Self.backend, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
            stream.open(); defer { stream.close() }
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { data.append(buffer, count: count) }
            request.httpBody = data
        }
        let result = backend.handle(request)
        let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    public override func stopLoading() {}

    /// A session whose Google traffic never leaves the process.
    public static func session(backend: MockGoogleBackend) -> URLSession {
        Self.backend = backend
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGoogleURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

public struct MockTokenProvider: GoogleTokenProvider {
    public init() {}
    public func accessToken(forceRefresh: Bool) async throws -> String { "mock-token" }
}
