import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmailCalendarCore

private struct MailTestToken: GoogleTokenProvider {
    let value: String
    func accessToken(forceRefresh: Bool) async throws -> String { value }
}

private actor MailSlowTestToken: GoogleTokenProvider {
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

private final class MailMockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: MailMockServer] = [:]
    func insert(_ server: MailMockServer, token: String) { lock.withLock { servers[token] = server } }
    func server(token: String) -> MailMockServer? { lock.withLock { servers[token] } }
    func remove(token: String) { _ = lock.withLock { servers.removeValue(forKey: token) } }
}

private final class MailTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = MailMockRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request.withMaterializedBody()
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
        guard let server = Self.registry.server(token: token), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        do {
            let (status, object) = try server.response(request)
            let data = try JSONSerialization.data(withJSONObject: object)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class MailMockServer: @unchecked Sendable {
    struct Message {
        var id: String
        var threadID: String
        var from: String
        var to: String
        var labels: Set<String>
        var json: [String: Any] {
            ["id": id, "threadId": threadID, "labelIds": Array(labels), "internalDate": "1770000000000", "snippet": "A calm note",
             "payload": ["mimeType": "text/plain", "headers": [
                ["name": "From", "value": from], ["name": "To", "value": to],
                ["name": "Subject", "value": "A calm note"], ["name": "Message-ID", "value": "<\(id)@example.com>"]],
                "body": ["data": Data("Hello".utf8).base64URL, "size": 5]]]
        }
    }
    private let lock = NSLock()
    private var messages: [String: Message] = [:]
    private var sentSeed: [Message] = []
    private var filters: [String: [String: Any]] = [:]
    private var nextFilter = 0
    private var failNextModify = false
    private var expiredHistory = false
    private var sentTokens: [String] = []
    private var changedIDs: Set<String> = []
    private var recordedRequestCount = 0
    private var shouldFailAfterSend = false
    private var sendCount = 0
    private var sentRaw: [String] = []
    private var draftCreateCount = 0
    private var shouldFailDraftRefresh = false
    private var labelNames = ["INBOX": "INBOX", "UNREAD": "UNREAD", "SENT": "SENT", "DRAFT": "DRAFT", "TRASH": "TRASH",
                              "aside": "HEY/Set Aside", "bubble": "HEY/Bubble Up", "screen": "HEY/Screener", "out": "HEY/Screened Out"]

    init() {
        addInbound(id: "known", from: "known@example.com")
        addInbound(id: "unknown", from: "new@example.net")
        sentSeed = [
            Message(id: "seed1", threadID: "sent1", from: "owner@example.com", to: "known@example.com", labels: ["SENT"]),
            Message(id: "seed2", threadID: "sent2", from: "owner@example.com", to: "older@example.org", labels: ["SENT"])
        ]
    }
    func addInbound(id: String, from: String) {
        lock.withLock {
            var labels: Set<String> = ["INBOX", "UNREAD"]
            for filter in filters.values {
                let criteria = filter["criteria"] as? [String: Any] ?? [:]
                let fromCriterion = criteria["from"] as? String ?? ""
                let exception = (criteria["negatedQuery"] as? String ?? "").contains("from:" + from)
                if from.hasSuffix(fromCriterion), !exception {
                    let action = filter["action"] as? [String: Any] ?? [:]
                    labels.formUnion(action["addLabelIds"] as? [String] ?? [])
                    labels.subtract(action["removeLabelIds"] as? [String] ?? [])
                }
            }
            messages[id] = Message(id: id, threadID: id, from: from, to: "owner@example.com", labels: labels)
            changedIDs.insert(id)
        }
    }
    func addSentPart(threadID: String) {
        lock.withLock { messages["reply"] = Message(id: "reply", threadID: threadID, from: "owner@example.com", to: "known@example.com", labels: ["SENT"]) }
    }
    func trashOnPhone(messageID: String) {
        lock.withLock {
            messages[messageID]?.labels.insert("TRASH")
            messages[messageID]?.labels.remove("INBOX")
            if let threadID = messages[messageID]?.threadID { changedIDs.insert(threadID) }
        }
    }
    func screenOutOnPhone(messageID: String) {
        lock.withLock {
            messages[messageID]?.labels.insert("out")
            messages[messageID]?.labels.remove("INBOX")
            if let threadID = messages[messageID]?.threadID { changedIDs.insert(threadID) }
        }
    }
    func failRefreshAfterDraftSave() { lock.withLock { shouldFailDraftRefresh = true } }
    var createdDraftCount: Int { lock.withLock { draftCreateCount } }
    func failRefreshAfterSend() { lock.withLock { shouldFailAfterSend = true } }
    var requestCount: Int { lock.withLock { recordedRequestCount } }
    var confirmedSendCount: Int { lock.withLock { sendCount } }
    var lastSentRaw: String? { lock.withLock { sentRaw.last } }
    func expireHistory() { lock.withLock { expiredHistory = true } }
    func failOneMutation() { lock.withLock { failNextModify = true } }
    func labels(messageID: String) -> Set<String> { lock.withLock { messages[messageID]?.labels ?? [] } }
    var filterCount: Int { lock.withLock { filters.count } }
    var requestedSentTokens: [String] { lock.withLock { sentTokens } }

    func response(_ request: URLRequest) throws -> (Int, [String: Any]) {
        try lock.withLock {
            recordedRequestCount += 1
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let path = components.path.split(separator: "/").dropFirst(4).map(String.init)
            let parameters = components.queryItems ?? []
            func query(_ name: String) -> String? { parameters.first(where: { $0.name == name })?.value }
            let body: [String: Any]
            if let data = request.httpBody { body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
            else { body = [:] }
            func thread(_ id: String) -> [String: Any] {
                ["id": id, "historyId": "101", "messages": messages.values.filter { $0.threadID == id }.map(\.json)]
            }
            if path == ["profile"] { return (200, ["emailAddress": "owner@example.com", "historyId": "100"]) }
            if path == ["labels"] {
                return (200, ["labels": labelNames.map { ["id": $0.key, "name": $0.value, "type": "user"] }])
            }
            if path == ["settings", "sendAs"] {
                return (200, ["sendAs": [
                    ["sendAsEmail": "owner@example.com", "isPrimary": true],
                    ["sendAsEmail": "work@example.org", "verificationStatus": "accepted"],
                    ["sendAsEmail": "pending@example.org", "verificationStatus": "pending"]]])
            }
            if path == ["messages", "send"] {
                sendCount += 1
                if let raw = body["raw"] as? String, let data = Data(base64URL: raw) { sentRaw.append(String(decoding: data, as: UTF8.self)) }
                let sent = Message(id: "confirmed-send", threadID: "sent-thread", from: "owner@example.com", to: "known@example.com", labels: ["SENT"])
                messages[sent.id] = sent
                return (200, sent.json)
            }
            if path == ["drafts"], request.httpMethod == "POST" {
                draftCreateCount += 1
                let message = Message(id: "draft-message", threadID: "draft-thread", from: "owner@example.com", to: "known@example.com", labels: ["DRAFT"])
                messages[message.id] = message
                return (200, ["id": "saved-draft", "message": message.json])
            }
            if path == ["drafts", "saved-draft"], request.httpMethod == "PUT" {
                return (200, ["id": "saved-draft", "message": messages["draft-message"]!.json])
            }
            if path == ["threads", "draft-thread"], shouldFailDraftRefresh {
                return (403, ["error": ["message": "Draft cache unavailable"]])
            }
            if path == ["drafts"] {
                if shouldFailAfterSend && sendCount > 0 { return (403, ["error": ["message": "Cache refresh unavailable"]]) }
                return (200, ["drafts": []])
            }
            if path == ["messages"] {
                let page = query("pageToken") ?? "first"
                sentTokens.append(page)
                if page == "first" { return (200, ["messages": [["id": "seed1", "threadId": "sent1"]], "nextPageToken": "second"]) }
                return (200, ["messages": [["id": "seed2", "threadId": "sent2"]]])
            }
            if path.count == 2, path[0] == "messages", let seed = sentSeed.first(where: { $0.id == path[1] }) { return (200, seed.json) }
            if path == ["threads"] {
                let labels = Set(parameters.filter { $0.name == "labelIds" }.compactMap(\.value))
                let sender = query("q")?.hasPrefix("from:(") == true ? String(query("q")!.dropFirst(6).dropLast()) : nil
                let matches = messages.values.filter { message in
                    (labels.isEmpty || !message.labels.isDisjoint(with: labels)) && (sender == nil || message.from.hasSuffix(sender!))
                }
                return (200, ["threads": Set(matches.map(\.threadID)).map { ["id": $0] }])
            }
            if path == ["history"] {
                if expiredHistory { return (404, ["error": ["message": "Expired history"]]) }
                return (200, ["historyId": "102", "history": [["id": "102", "messages": changedIDs.map { ["id": $0, "threadId": $0] }]]])
            }
            if path == ["settings", "filters"], request.httpMethod == "POST" {
                nextFilter += 1
                let id = "filter-\(nextFilter)"
                var filter = body; filter["id"] = id; filters[id] = filter
                return (200, filter)
            }
            if path.count == 3, path[0...1] == ["settings", "filters"], request.httpMethod == "DELETE" {
                filters.removeValue(forKey: path[2]); return (200, [:])
            }
            if path.count == 3, path[2] == "modify", ["threads", "messages"].contains(path[0]) {
                if failNextModify { failNextModify = false; return (500, ["error": ["message": "Offline mutation"]]) }
                let adding = Set(body["addLabelIds"] as? [String] ?? [])
                let removing = Set(body["removeLabelIds"] as? [String] ?? [])
                for id in Array(messages.keys) where path[0] == "threads" ? messages[id]?.threadID == path[1] : id == path[1] {
                    messages[id]?.labels.formUnion(adding)
                    messages[id]?.labels.subtract(removing)
                    if let threadID = messages[id]?.threadID { changedIDs.insert(threadID) }
                }
                if path[0] == "threads" { return (200, thread(path[1])) }
                return (200, messages[path[1]]?.json ?? [:])
            }
            if path.count == 2, path[0] == "threads", messages.values.contains(where: { $0.threadID == path[1] }) { return (200, thread(path[1])) }
            return (404, ["error": ["message": "Missing mock endpoint \(path)"]])
        }
    }
}

final class MailServiceTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (MailService, LocalStore, MailMockServer, Account) {
        let token = UUID().uuidString, server = MailMockServer()
        MailTestURLProtocol.registry.insert(server, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MailTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(url: directory.appendingPathComponent("mail.sqlite"))
        addTeardownBlock {
            session.invalidateAndCancel()
            MailTestURLProtocol.registry.remove(token: token)
            try? FileManager.default.removeItem(at: directory)
        }
        let api = GoogleAPI(auth: MailTestToken(value: token), session: session)
        return (MailService(api: api, store: store), store, server, Account(id: "owner@example.com", email: "owner@example.com"))
    }

    /// Treat the fixture's Inbox as mail arriving after setup, so the Screener applies to it.
    private func markInboxSeeded(_ store: LocalStore, _ account: Account) async throws {
        try await store.setMetadata(true, key: "inboxSendersSeeded", accountID: account.id)
    }

    func testFirstSyncApprovesExistingInboxSendersInsteadOfScreeningThem() async throws {
        let (service, _, server, account) = try fixture()
        let snapshot = try await service.sync(account: account)
        XCTAssertTrue(server.labels(messageID: "unknown").contains("INBOX"))
        XCTAssertFalse(server.labels(messageID: "unknown").contains("screen"))
        XCTAssertTrue(snapshot.rules.contains { $0.decision == .approved && !$0.key.hasSuffix("example.org") })
    }

    func testSeedPagesAllSentRecipientsBeforeScreeningUnknownSender() async throws {
        let (service, store, server, account) = try fixture()
        try await markInboxSeeded(store, account)
        let snapshot = try await service.sync(account: account)
        XCTAssertEqual(server.requestedSentTokens, ["first", "second"])
        XCTAssertEqual(snapshot.rules.first(where: { $0.key == "older@example.org" })?.decision, .approved)
        XCTAssertTrue(server.labels(messageID: "known").contains("INBOX"))
        XCTAssertFalse(server.labels(messageID: "unknown").contains("INBOX"))
        XCTAssertTrue(server.labels(messageID: "unknown").contains("screen"))
    }

    func testRejectCreatesPhoneFilterAndUndoRestoresApprovalAndPerMessageLabels() async throws {
        let (service, _, server, account) = try fixture()
        server.addSentPart(threadID: "known")
        _ = try await service.sync(account: account)
        let reject = try await service.decide(sender: "known@example.com", decision: .blocked, account: account)
        XCTAssertEqual(server.filterCount, 1)
        XCTAssertTrue(server.labels(messageID: "known").contains("out"))
        try await service.undo(tokenID: reject.id, account: account)
        XCTAssertEqual(server.filterCount, 0)
        XCTAssertEqual(server.labels(messageID: "known"), ["INBOX", "UNREAD"])
        XCTAssertEqual(server.labels(messageID: "reply"), ["SENT"])
        let snapshot = try await service.cached(accountID: account.id)
        XCTAssertEqual(snapshot.rules.first(where: { $0.key == "known@example.com" })?.decision, .approved)
        let archive = try await service.archive(threadID: "known", account: account)
        try await service.undo(tokenID: archive.id, account: account)
        XCTAssertEqual(server.labels(messageID: "reply"), ["SENT"])
    }

    func testRejectedDecisionRollsBackFilterWhenMovingMailFails() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        server.failOneMutation()
        do {
            _ = try await service.decide(sender: "known@example.com", decision: .blocked, account: account)
            XCTFail("The label write must fail")
        } catch let error as GoogleAPIError { XCTAssertEqual(error.statusCode, 500) }
        XCTAssertEqual(server.filterCount, 0)
        XCTAssertEqual(server.labels(messageID: "known"), ["INBOX", "UNREAD"])
        let snapshot = try await service.cached(accountID: account.id)
        XCTAssertEqual(snapshot.rules.first(where: { $0.key == "known@example.com" })?.decision, .approved)
    }

    func testDomainRejectionOverridesSeededAddressAndUndoRestoresIt() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        let token = try await service.decide(sender: "@example.com", decision: .blocked, domain: true, account: account)
        let blocked = try await service.cached(accountID: account.id)
        XCTAssertNil(blocked.rules.first(where: { $0.key == "known@example.com" }))
        XCTAssertEqual(blocked.rules.first(where: { $0.key == "@example.com" })?.decision, .blocked)
        XCTAssertEqual(server.filterCount, 1)
        try await service.undo(tokenID: token.id, account: account)
        let restored = try await service.cached(accountID: account.id)
        XCTAssertEqual(restored.rules.first(where: { $0.key == "known@example.com" })?.decision, .approved)
        XCTAssertNil(restored.rules.first(where: { $0.key == "@example.com" }))
        XCTAssertEqual(server.filterCount, 0)
    }

    func testAddressApprovalIsAlsoAnExceptionToThePhoneDomainFilter() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        _ = try await service.decide(sender: "@example.com", decision: .blocked, domain: true, account: account)
        _ = try await service.decide(sender: "known@example.com", decision: .approved, account: account)
        XCTAssertEqual(server.filterCount, 1)
        server.addInbound(id: "allowed-on-phone", from: "known@example.com")
        server.addInbound(id: "blocked-on-phone", from: "stranger@example.com")
        XCTAssertTrue(server.labels(messageID: "allowed-on-phone").contains("INBOX"))
        XCTAssertFalse(server.labels(messageID: "allowed-on-phone").contains("out"))
        XCTAssertFalse(server.labels(messageID: "blocked-on-phone").contains("INBOX"))
        XCTAssertTrue(server.labels(messageID: "blocked-on-phone").contains("out"))
    }

    func testDueBubbleNeverResurfacesMailTrashedOnPhoneWhileAppWasClosed() async throws {
        let (service, store, server, account) = try fixture()
        _ = try await service.sync(account: account)
        _ = try await service.bubbleUp(threadID: "known", date: .now.addingTimeInterval(-60), account: account)
        server.trashOnPhone(messageID: "known")
        let surfaced = try await service.processDueBubbles(account: account)
        XCTAssertTrue(surfaced.isEmpty)
        XCTAssertFalse(server.labels(messageID: "known").contains("INBOX"))
        XCTAssertTrue(server.labels(messageID: "known").contains("TRASH"))
        let pending = try await store.load(BubbleRecord.self, id: "known", collection: "bubbles", accountID: account.id)
        XCTAssertNil(pending)
    }

    func testDueBubblePersistsOnFailureAndSurfacesOnceAfterRestart() async throws {
        let (service, store, server, account) = try fixture()
        _ = try await service.sync(account: account)
        let due = Date.now.addingTimeInterval(-60)
        _ = try await service.bubbleUp(threadID: "known", date: due, account: account)
        server.failOneMutation()
        do { _ = try await service.processDueBubbles(account: account); XCTFail("Mutation should fail") }
        catch let error as GoogleAPIError { XCTAssertEqual(error.statusCode, 500) }
        let pending = try await store.load(BubbleRecord.self, id: "known", collection: "bubbles", accountID: account.id)
        XCTAssertNil(pending?.surfacedAt)
        XCTAssertTrue(server.labels(messageID: "known").contains("bubble"))
        // Recreating the service models a relaunch. The timer and label IDs come from SQLite.
        let token = UUID().uuidString
        MailTestURLProtocol.registry.insert(server, token: token)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MailTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); MailTestURLProtocol.registry.remove(token: token) }
        let restarted = MailService(api: GoogleAPI(auth: MailTestToken(value: token), session: session), store: store)
        let surfaced = try await restarted.processDueBubbles(account: account)
        XCTAssertEqual(surfaced.map(\.id), ["known"])
        XCTAssertNotNil(surfaced.first?.bubbledAt)
        XCTAssertNil(surfaced.first?.bubbleUpAt)
        let secondPass = try await restarted.processDueBubbles(account: account)
        XCTAssertTrue(secondPass.isEmpty)
        XCTAssertTrue(server.labels(messageID: "known").contains("INBOX"))
        XCTAssertFalse(server.labels(messageID: "known").contains("bubble"))
    }

    func testExpiredHistoryRebuildsCacheWithoutLosingSenderDecisions() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        server.addInbound(id: "after-expiration", from: "known@example.com")
        server.expireHistory()
        let snapshot = try await service.sync(account: account)
        XCTAssertTrue(snapshot.threads.contains(where: { $0.id == "after-expiration" }))
        XCTAssertEqual(snapshot.rules.first(where: { $0.key == "known@example.com" })?.decision, .approved)
        XCTAssertEqual(server.requestedSentTokens, ["first", "second"], "Successful Sent seeding runs once")
    }

    func testSenderApprovalReleasesMailThatArrivedDuringFilterRemoval() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        // Models delivery by the old rejection filter immediately before its deletion.
        server.screenOutOnPhone(messageID: "known")
        _ = try await service.sync(account: account)
        XCTAssertTrue(server.labels(messageID: "known").contains("INBOX"))
        XCTAssertFalse(server.labels(messageID: "known").contains("out"))
    }

    func testSendAddressesListOnlyVerifiedAliasesAndSendUsesChosenOne() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        let addresses = try await service.sendAddresses(account: account)
        XCTAssertEqual(addresses, ["owner@example.com", "work@example.org"])
        let cached = try await service.cachedSendAddresses(accountID: account.id)
        XCTAssertEqual(cached, addresses)

        try await service.send(OutgoingMessage(to: ["known@example.com"], subject: "Hello", body: "As work", from: "work@example.org"), account: account)
        XCTAssertTrue(try XCTUnwrap(server.lastSentRaw).contains("From: work@example.org\r\n"))
        try await service.send(OutgoingMessage(to: ["known@example.com"], subject: "Hello", body: "As owner"), account: account)
        XCTAssertTrue(try XCTUnwrap(server.lastSentRaw).contains("From: owner@example.com\r\n"))
    }

    func testConfirmedSendSucceedsWhenSubsequentCacheRefreshFails() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        server.failRefreshAfterSend()
        let receipt = try await service.send(OutgoingMessage(to: ["known@example.com"], subject: "Hello", body: "Sent once"), account: account)
        XCTAssertEqual(receipt.messageID, "confirmed-send")
        XCTAssertNotNil(receipt.warning)
        XCTAssertEqual(server.confirmedSendCount, 1)
    }

    func testConfirmedDraftSaveReturnsIDDespiteCacheFailureSoAutosaveUpdatesIt() async throws {
        let (service, _, server, account) = try fixture()
        _ = try await service.sync(account: account)
        server.failRefreshAfterDraftSave()
        let first = try await service.saveDraft(OutgoingMessage(to: ["known@example.com"], subject: "Draft", body: "First version"), account: account)
        XCTAssertEqual(first.draftID, "saved-draft")
        var changed = first; changed.body = "Second version"
        let second = try await service.saveDraft(changed, account: account)
        XCTAssertEqual(second.draftID, first.draftID)
        XCTAssertEqual(server.createdDraftCount, 1)
    }

    func testSignOutCancelsAndDrainsNetworkBeforeTheNextAccountSyncs() async throws {
        let token = UUID().uuidString, server = MailMockServer()
        MailTestURLProtocol.registry.insert(server, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MailTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            session.invalidateAndCancel()
            MailTestURLProtocol.registry.remove(token: token)
            try? FileManager.default.removeItem(at: directory)
        }
        let provider = MailSlowTestToken(value: token)
        let store = try LocalStore(url: directory.appendingPathComponent("mail.sqlite"))
        let service = MailService(api: GoogleAPI(auth: provider, session: session), store: store)
        let oldAccount = Account(id: "old-account", email: "owner@example.com")
        let sync = Task { try await service.sync(account: oldAccount) }
        while !(await provider.started) { await Task.yield() }
        await service.cancelAllOperations()
        do { _ = try await sync.value; XCTFail("The old account request must be cancelled") }
        catch is CancellationError { }
        let wasCancelled = await provider.wasCancelled
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(server.requestCount, 0)
        let newAccount = Account(id: "new-account", email: "owner@example.com")
        let next = try await service.sync(account: newAccount)
        XCTAssertFalse(next.threads.isEmpty)
        let oldCache = try await service.cached(accountID: oldAccount.id)
        XCTAssertTrue(oldCache.threads.isEmpty)
        XCTAssertTrue(next.threads.allSatisfy { $0.accountID == newAccount.id })
    }

    func testLoadingImagesDoesNotApproveUnknownSender() async throws {
        let (service, store, _, account) = try fixture()
        try await markInboxSeeded(store, account)
        _ = try await service.sync(account: account)
        try await service.setRemoteImages(sender: "new@example.net", allowed: true, account: account)
        let snapshot = try await service.cached(accountID: account.id)
        XCTAssertTrue(snapshot.remoteImageSenders.contains("new@example.net"))
        XCTAssertNil(snapshot.rules.first(where: { $0.key == "new@example.net" }))
    }
}
