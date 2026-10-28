import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EmailCalendarCore

private func seenThread(_ id: String, date: TimeInterval = 100, unread: Bool = false,
                        seenAt: TimeInterval? = nil, bubbledAt: TimeInterval? = nil) -> MailThread {
    let labels: Set<String> = unread ? ["INBOX", "UNREAD"] : ["INBOX"]
    let message = MailMessage(id: "m-" + id, threadID: id, accountID: "owner", from: MailAddress(email: "friend@example.com"),
                              date: Date(timeIntervalSince1970: date), labels: labels)
    return MailThread(id: id, accountID: "owner", messages: [message], labels: labels, historyID: "100",
                      bubbledAt: bubbledAt.map { Date(timeIntervalSince1970: $0) },
                      seenAt: seenAt.map { Date(timeIntervalSince1970: $0) })
}

private func seenSource(_ id: String, unread: Bool = false, historyID: String = "100") -> GoogleMailThread {
    GoogleMailThread(id: id, historyId: historyID, messages: [
        GoogleMailMessage(id: "m-" + id, threadId: id, labelIds: unread ? ["INBOX", "UNREAD"] : ["INBOX"],
                          internalDate: "100000", payload: GoogleMailPart(headers: [
                            GoogleMailHeader(name: "From", value: "friend@example.com")
                          ]))
    ])
}

struct SeenOrderingTests {
    @Test func bubbleReturnTakesPriorityOverSeenTimeWithLegacyMailLast() {
        let rows = [seenThread("legacy", date: 10_000), seenThread("older-seen", date: 500, seenAt: 200, bubbledAt: 250),
                    seenThread("latest-seen", date: 1, seenAt: 300), seenThread("legacy-old", date: 10)]
        #expect(rows.sorted { MailThread.imboxPrecedes($0, $1) }.map(\.id) == ["older-seen", "latest-seen", "legacy", "legacy-old"])
    }

    @Test func bubbleReturnAlsoLiftsLegacyReadMailWithoutChangingItsSeenTime() {
        let returned = seenThread("returned", date: 1, bubbledAt: 500)
        let rows = [seenThread("legacy", date: 10_000), seenThread("seen", seenAt: 400), returned]
        #expect(rows.sorted { MailThread.imboxPrecedes($0, $1) }.map(\.id) == ["returned", "seen", "legacy"])
        #expect(returned.seenAt == nil)
    }

    @Test func batchTiesHaveStableOrderAndNewMailKeepsBubblePriority() {
        let rows = [seenThread("b", seenAt: 200), seenThread("a", seenAt: 200), seenThread("c", date: 300, seenAt: 200),
                    seenThread("newer", date: 400, unread: true), seenThread("bubbled", date: 10, unread: true, bubbledAt: 200)]
        let expected = ["bubbled", "newer", "c", "a", "b"]
        #expect(rows.sorted { MailThread.imboxPrecedes($0, $1) }.map(\.id) == expected)
        #expect(rows.reversed().sorted { MailThread.imboxPrecedes($0, $1) }.map(\.id) == expected)
        #expect(!MailThread.imboxPrecedes(rows[0], rows[0]))
    }

    @Test func bubbledThreadsSortByReturnTimeAheadOfNewerSeenTimes() {
        let rows = [seenThread("newest-seen", seenAt: 900), seenThread("first-return", seenAt: 800, bubbledAt: 200),
                    seenThread("latest-return", seenAt: 100, bubbledAt: 300)]
        let expected = ["latest-return", "first-return", "newest-seen"]
        #expect(rows.sorted { MailThread.imboxPrecedes($0, $1) }.map(\.id) == expected)
        #expect(rows.reversed().sorted { MailThread.imboxPrecedes($0, $1) }.map(\.id) == expected)
    }

    @Test func openUnreadRowStaysWithNewMailUntilClosed() {
        let rows = [seenThread("seen", seenAt: 200), seenThread("open", date: 300, seenAt: 100),
                    seenThread("unread", date: 400, unread: true)]
        #expect(rows.sorted { MailThread.imboxPrecedes($0, $1, openedUnreadID: "open") }.map(\.id) == ["unread", "open", "seen"])
        #expect(rows.sorted { MailThread.imboxPrecedes($0, $1) }.map(\.id) == ["unread", "seen", "open"])
    }

    @Test func oldCacheAndInitiallyReadMailDoNotGetInventedSeenTimes() throws {
        let oldJSON = #"{"id":"old","accountID":"owner","messages":[],"labels":["INBOX"]}"#
        let old = try JSONDecoder().decode(MailThread.self, from: Data(oldJSON.utf8))
        #expect(old.seenAt == nil)
        #expect(old.seenHistoryID == nil)
        let imported = MailMapping.thread(seenSource("old"), accountID: "owner", labels: [:])
        #expect(imported.seenAt == nil)
        #expect(imported.seenHistoryID == "100")
    }

    @Test func mappingTracksReadTransitionsWithoutBumpingRefreshesOrPartialReads() {
        let time = Date(timeIntervalSince1970: 500)
        var source = seenSource("thread", historyID: "101")
        source.messages?.append(GoogleMailMessage(id: "reply", threadId: "thread", labelIds: ["INBOX", "UNREAD"]))
        let partial = MailMapping.thread(source, accountID: "owner", labels: [:], previous: seenThread("thread", unread: true), observedAt: time)
        #expect(partial.unread)
        #expect(partial.seenAt == nil)
        let read = MailMapping.thread(seenSource("thread", historyID: "102"), accountID: "owner", labels: [:], previous: partial, observedAt: time)
        #expect(read.seenAt == time)
        let refreshed = MailMapping.thread(seenSource("thread", historyID: "103"), accountID: "owner", labels: [:], previous: read, observedAt: time.addingTimeInterval(10))
        #expect(refreshed.seenAt == time)
        #expect(refreshed.seenHistoryID == "102")
        let reply = MailMapping.thread(seenSource("thread", unread: true, historyID: "104"), accountID: "owner", labels: [:], previous: refreshed)
        #expect(reply.unread)
        let reread = MailMapping.thread(seenSource("thread", historyID: "105"), accountID: "owner", labels: [:], previous: reply, observedAt: time.addingTimeInterval(20))
        #expect(reread.seenAt == time.addingTimeInterval(20))
    }

    @Test func localReadSurvivesRefreshRestartAndOwnHistoryEcho() async throws {
        let fixture = try SeenFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let readAt = Date(timeIntervalSince1970: 500)
        _ = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: readAt, account: fixture.account)
        _ = try await fixture.mail.fetchThread(id: "a", account: fixture.account)
        _ = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: readAt.addingTimeInterval(50), account: fixture.account)
        let reopened = try LocalStore(url: fixture.databaseURL)
        let restarted = MailService(api: fixture.api, store: reopened)
        let synced = try await restarted.sync(account: fixture.account)
        #expect(synced.threads.first { $0.id == "a" }?.seenAt == readAt)
        #expect(try await reopened.all(MailThread.self, collection: "threads", accountID: "other").isEmpty)
    }

    @Test func unreadReadAndUndoRestorePreviousSeenPositionIncludingNil() async throws {
        let fixture = try SeenFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let first = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: Date(timeIntervalSince1970: 500), account: fixture.account)
        try await fixture.mail.undo(tokenID: first.id, account: fixture.account)
        var thread = try #require(try await fixture.mail.cached(accountID: "owner").threads.first { $0.id == "a" })
        #expect(thread.unread)
        #expect(thread.seenAt == nil)
        _ = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: Date(timeIntervalSince1970: 600), account: fixture.account)
        let unread = try await fixture.mail.markUnread(threadID: "a", unread: true, account: fixture.account)
        try await fixture.mail.undo(tokenID: unread.id, account: fixture.account)
        thread = try #require(try await fixture.mail.sync(account: fixture.account).threads.first { $0.id == "a" })
        #expect(!thread.unread)
        #expect(thread.seenAt == Date(timeIntervalSince1970: 600))
        _ = try await fixture.mail.markUnread(threadID: "a", unread: true, account: fixture.account)
        _ = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: Date(timeIntervalSince1970: 700), account: fixture.account)
        #expect(try await fixture.mail.cached(accountID: "owner").threads.first { $0.id == "a" }?.seenAt == Date(timeIntervalSince1970: 700))
    }

    @Test func bulkReadUsesOneSeenTimeAndUndoRestoresBothThreads() async throws {
        let fixture = try SeenFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let token = try await fixture.mail.change(.read(true), threadIDs: ["a", "b"], account: fixture.account)
        let read = try await fixture.mail.cached(accountID: "owner").threads
        #expect(read.allSatisfy { !$0.unread && $0.seenAt != nil })
        #expect(Set(read.compactMap(\.seenAt)).count == 1)
        try await fixture.mail.undo(tokenID: token.id, account: fixture.account)
        #expect(try await fixture.mail.sync(account: fixture.account).threads.allSatisfy { $0.unread && $0.seenAt == nil })
    }

    @Test func separateMarkAllCallsCanShareOneSeenTime() async throws {
        let fixture = try SeenFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let time = Date(timeIntervalSince1970: 500)
        for id in ["a", "b"] {
            _ = try await fixture.mail.markUnread(threadID: id, unread: false, seenAt: time, account: fixture.account)
        }
        #expect(try await fixture.mail.cached(accountID: "owner").threads.allSatisfy { $0.seenAt == time })
    }

    @Test func historyCatchesReadCyclesBetweenPollsEvenAfterAnUnrelatedFetch() async throws {
        let fixture = try SeenFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let original = Date(timeIntervalSince1970: 500)
        _ = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: original, account: fixture.account)
        _ = try await fixture.mail.sync(account: fixture.account)
        _ = try await fixture.api.modifyThread(id: "a", addLabelIDs: ["UNREAD"])
        _ = try await fixture.api.modifyThread(id: "a", removeLabelIDs: ["UNREAD"])
        _ = try await fixture.mail.fetchThread(id: "a", account: fixture.account)
        let detectedAfter = Date.now
        var thread = try #require(try await fixture.mail.sync(account: fixture.account).threads.first { $0.id == "a" })
        #expect(try #require(thread.seenAt) >= detectedAfter)
        let detectedAt = thread.seenAt
        _ = try await fixture.api.modifyThread(id: "a", addLabelIDs: ["STARRED"])
        thread = try #require(try await fixture.mail.sync(account: fixture.account).threads.first { $0.id == "a" })
        #expect(thread.seenAt == detectedAt)
    }

    @Test func fullSyncKeepsSeenTimesAndDetectsAnExternalReadWithoutHistory() async throws {
        let fixture = try SeenFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let time = Date(timeIntervalSince1970: 500)
        _ = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: time, account: fixture.account)
        _ = try await fixture.api.modifyThread(id: "b", removeLabelIDs: ["UNREAD"])
        try await fixture.store.removeMetadata(key: "mailHistoryID", accountID: "owner")
        let snapshot = try await fixture.mail.sync(account: fixture.account)
        #expect(snapshot.threads.first { $0.id == "a" }?.seenAt == time)
        #expect(snapshot.threads.first { $0.id == "b" }?.seenAt != nil)
    }

    @Test func failedMutationDoesNotStampButConfirmedReadSurvivesFailedRefresh() async throws {
        let fixture = try SeenFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        fixture.server.failMutation()
        do {
            _ = try await fixture.mail.markUnread(threadID: "a", unread: false, account: fixture.account)
            Issue.record("The failed mutation should throw")
        } catch is GoogleAPIError {}
        #expect(try await fixture.mail.cached(accountID: "owner").threads.first { $0.id == "a" }?.seenAt == nil)
        fixture.server.failRefreshAfterMutation()
        let time = Date(timeIntervalSince1970: 500)
        let token = try await fixture.mail.markUnread(threadID: "a", unread: false, seenAt: time, account: fixture.account)
        #expect(token.warning != nil)
        let cached = try #require(try await fixture.mail.cached(accountID: "owner").threads.first { $0.id == "a" })
        #expect(!cached.unread)
        #expect(cached.seenAt == time)
        #expect(try await fixture.mail.sync(account: fixture.account).threads.first { $0.id == "a" }?.seenAt == time)
        try await fixture.mail.undo(tokenID: token.id, account: fixture.account)
        #expect(try await fixture.mail.cached(accountID: "owner").threads.first { $0.id == "a" }?.unread == true)
    }
}

private struct SeenFixture {
    let account = Account(id: "owner", email: "owner@example.com")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seen-tests-" + UUID().uuidString)
    var databaseURL: URL { directory.appendingPathComponent("cache.sqlite") }
    let server: SeenServer
    let store: LocalStore
    let api: GoogleAPI
    let mail: MailService
    let session: URLSession
    let token: String

    init() throws {
        server = SeenServer()
        token = UUID().uuidString
        SeenProtocol.registry.set(server, token: token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeenProtocol.self]
        session = URLSession(configuration: configuration)
        api = GoogleAPI(auth: SeenToken(value: token), session: session)
        store = try LocalStore(url: directory.appendingPathComponent("cache.sqlite"))
        mail = MailService(api: api, store: store)
    }

    func prepare() async throws {
        try await store.setMetadata(true, key: "sentRecipientsSeeded", accountID: account.id)
        _ = try await mail.sync(account: account)
    }

    func cleanup() {
        session.invalidateAndCancel()
        SeenProtocol.registry.set(nil, token: token)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct SeenToken: GoogleTokenProvider {
    let value: String
    func accessToken(forceRefresh: Bool) async throws -> String { value }
}

private final class SeenServer: @unchecked Sendable {
    private let lock = NSLock()
    private var threads = ["a": seenSource("a", unread: true), "b": seenSource("b", unread: true)]
    private var history: [GoogleHistoryRecord] = []
    private var historyID = 100
    private var mutationFails = false
    private var refreshWillFail = false
    private var refreshFails = false

    func failMutation() { lock.withLock { mutationFails = true } }
    func failRefreshAfterMutation() { lock.withLock { refreshWillFail = true } }

    func response(_ request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            func encoded<T: Encodable>(_ value: T) throws -> (Int, Data) { (200, try JSONEncoder().encode(value)) }
            func failure() -> (Int, Data) { (403, Data(#"{"error":{"message":"Test failure"}}"#.utf8)) }
            let url = request.url!
            let path = url.path.split(separator: "/").dropFirst(4).map(String.init)
            if path == ["profile"] { return try encoded(GoogleMailProfile(emailAddress: "owner@example.com", historyId: String(historyID))) }
            if path == ["labels"] {
                let names = ["INBOX", "UNREAD", "HEY/Set Aside", "HEY/Bubble Up", "HEY/Screener", "HEY/Screened Out"]
                return try encoded(["labels": names.map { GoogleLabel(id: $0, name: $0) }])
            }
            if path == ["drafts"] { return (200, Data(#"{"drafts":[]}"#.utf8)) }
            if path == ["history"] {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let cursor = Int(query.first { $0.name == "startHistoryId" }?.value ?? "0") ?? 0
                return try encoded(GoogleHistoryPage(history: history.filter { Int($0.id)! > cursor }, historyId: String(historyID)))
            }
            if path == ["threads"] { return try encoded(["threads": Array(threads.values)]) }
            if path.count == 2, path[0] == "threads", let thread = threads[path[1]] {
                if refreshFails { refreshFails = false; return failure() }
                return try encoded(thread)
            }
            if path.count == 3, path[2] == "modify" {
                if mutationFails { mutationFails = false; return failure() }
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: [String]]
                let additions = Set(body["addLabelIds"] ?? [])
                let removals = Set(body["removeLabelIds"] ?? [])
                for id in Array(threads.keys) where path[0] == "threads" ? id == path[1] : threads[id]!.messages!.contains(where: { $0.id == path[1] }) {
                    var thread = threads[id]!
                    for index in thread.messages!.indices where path[0] == "threads" || thread.messages![index].id == path[1] {
                        var message = thread.messages![index]
                        let before = Set(message.labelIds ?? [])
                        let after = before.union(additions).subtracting(removals)
                        if before != after {
                            historyID += 1
                            message.labelIds = after.sorted()
                            let reference = GoogleMailMessage(id: message.id, threadId: id)
                            history.append(GoogleHistoryRecord(id: String(historyID),
                                labelsAdded: [.init(message: reference, labelIds: Array(after.subtracting(before)))],
                                labelsRemoved: [.init(message: reference, labelIds: Array(before.subtracting(after)))]))
                        }
                        thread.messages![index] = message
                    }
                    thread.historyId = String(historyID)
                    threads[id] = thread
                    if refreshWillFail { refreshFails = true; refreshWillFail = false }
                    if path[0] == "threads" { return try encoded(thread) }
                    return try encoded(thread.messages!.first { $0.id == path[1] }!)
                }
            }
            return (404, Data(#"{"error":{"message":"Unknown test endpoint"}}"#.utf8))
        }
    }
}

private final class SeenRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [String: SeenServer] = [:]
    func set(_ server: SeenServer?, token: String) { lock.withLock { servers[token] = server } }
    func get(_ token: String) -> SeenServer? { lock.withLock { servers[token] } }
}

private final class SeenProtocol: URLProtocol, @unchecked Sendable {
    static let registry = SeenRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request.withMaterializedBody()
        let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        guard let server = Self.registry.get(token), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        do {
            let (status, data) = try server.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
