import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmailCalendarCore

/// Runs the real mail and calendar services end to end against the in-app mock backend.
final class MockBackendTests: XCTestCase, @unchecked Sendable {
    func testDiscardRemovesTheDraftButKeepsTheConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = MockGoogleBackend(fileURL: directory.appendingPathComponent("google.json"))
        let api = GoogleAPI(auth: MockTokenProvider(), session: MockGoogleURLProtocol.session(backend: backend))
        let mail = MailService(api: api, store: try LocalStore(url: directory.appendingPathComponent("cache.sqlite")))
        let account = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail)
        _ = try await mail.sync(account: account)
        let originals = try await mail.sync(account: account).threads.first { $0.id == "t-climb" }?.messages.count

        let reply = try await mail.saveDraft(OutgoingMessage(to: ["tom@beckerfamily.net"], subject: "Re: Climbing Saturday?",
                                                             body: "Never mind", threadID: "t-climb"), account: account)
        try await mail.discardDraft(reply, account: account)
        // A large email goes through the upload endpoint and still lands, attachment included.
        let pdf = OutgoingAttachment(name: "portfolio.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 4_000_000))
        let big = try await mail.saveDraft(OutgoingMessage(to: ["tom@beckerfamily.net"], subject: "Portfolio", attachments: [pdf]), account: account)
        try await mail.send(big, account: account)
        let sent = try await mail.sync(account: account).threads.flatMap(\.messages).first { $0.subject == "Portfolio" }
        XCTAssertTrue(sent?.labels.contains("SENT") == true)
        XCTAssertEqual(sent?.attachments.first?.name, "portfolio.pdf")

        let fresh = try await mail.saveDraft(OutgoingMessage(to: ["someone@example.com"], subject: "Second thoughts"), account: account)
        try await mail.discardDraft(fresh, account: account)

        let snapshot = try await mail.sync(account: account)
        let climb = try XCTUnwrap(snapshot.threads.first { $0.id == "t-climb" })
        XCTAssertEqual(climb.messages.count, originals)
        XCTAssertFalse(climb.messages.contains { $0.labels.contains("DRAFT") })
        XCTAssertFalse(snapshot.threads.contains { $0.subject == "Second thoughts" })
    }

    func testDemoMailboxAndCalendarWorkEndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = MockGoogleBackend(fileURL: directory.appendingPathComponent("google.json"))
        let api = GoogleAPI(auth: MockTokenProvider(), session: MockGoogleURLProtocol.session(backend: backend))
        let store = try LocalStore(url: directory.appendingPathComponent("cache.sqlite"))
        let mail = MailService(api: api, store: store)
        let calendar = CalendarService(api: api, store: store)
        let account = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail)

        // First sync: the existing Inbox stays put and its senders are approved.
        var snapshot = try await mail.sync(account: account)
        let inbox = snapshot.threads.filter { $0.labels.contains("INBOX") }
        XCTAssertGreaterThan(inbox.count, 8)
        XCTAssertTrue(snapshot.threads.contains { $0.labels.contains("HEY/Set Aside") })
        XCTAssertTrue(snapshot.threads.contains { $0.labels.contains("DRAFT") })
        XCTAssertFalse(snapshot.threads.contains { $0.labels.contains("HEY/Screener") })

        // The next sync brings mail from new senders, which lands in the Screener.
        snapshot = try await mail.sync(account: account)
        let screened = snapshot.threads.filter { $0.labels.contains("HEY/Screener") }
        XCTAssertEqual(screened.count, 3)

        // Screening a sender out creates a Gmail filter that also catches their later mail.
        _ = try await mail.decide(sender: "promo@dealsweekly.example", decision: .blocked, account: account)
        _ = try await mail.decide(sender: "lena@parkandco.studio", decision: .approved, account: account)
        for _ in 0..<6 { backend.simulateIncomingMail() }
        snapshot = try await mail.sync(account: account)
        let deals = snapshot.threads.filter { $0.messages.contains { $0.from.email == "promo@dealsweekly.example" } }
        XCTAssertTrue(deals.allSatisfy { $0.labels.contains("HEY/Screened Out") && !$0.labels.contains("INBOX") })
        XCTAssertTrue(snapshot.threads.contains { $0.id == "t-roadmap" && $0.messages.count == 4 })

        // Set Aside, Bubble Up, archive and sending all round-trip through the backend.
        _ = try await mail.toggleSetAside(threadID: "t-mom", account: account)
        _ = try await mail.bubbleUp(threadID: "t-bank", date: .now.addingTimeInterval(-1), account: account)
        _ = try await mail.archive(threadID: "t-pr", account: account)
        let surfaced = try await mail.processDueBubbles(account: account)
        XCTAssertEqual(surfaced.map(\.id), ["t-bank"])
        let draft = try await mail.saveDraft(OutgoingMessage(to: ["tom@beckerfamily.net"], subject: "Re: Climbing Saturday?",
                                                             body: "See you there", threadID: "t-climb"), account: account)
        try await mail.send(draft, account: account)
        snapshot = try await mail.sync(account: account)
        XCTAssertTrue(snapshot.threads.first { $0.id == "t-mom" }?.labels.contains("HEY/Set Aside") == true)
        XCTAssertTrue(snapshot.threads.first { $0.id == "t-bank" }?.labels.contains("INBOX") == true)
        XCTAssertFalse(snapshot.threads.first { $0.id == "t-pr" }?.labels.contains("INBOX") == true)
        let climb = try XCTUnwrap(snapshot.threads.first { $0.id == "t-climb" })
        XCTAssertTrue(climb.messages.contains { $0.labels.contains("SENT") && $0.plainText.contains("See you there") })
        XCTAssertFalse(climb.messages.contains { $0.labels.contains("DRAFT") })
        let search = try await mail.search(query: "lisbon", account: account)
        XCTAssertEqual(search.map(\.id), ["t-trip"])

        // Calendar: recurring events expand, and edits, deletes and RSVPs survive a sync.
        try await calendar.sync(accountID: account.id)
        var events = try await calendar.cachedEvents(accountID: account.id, visibleOnly: false)
        let standups = events.filter { $0.title == "Daily standup" }
        XCTAssertGreaterThanOrEqual(standups.count, 10)
        XCTAssertTrue(events.contains { $0.title == "Lisbon trip" && $0.isAllDay })

        let primary = MockGoogleBackend.accountEmail
        let start = Date.now.addingTimeInterval(3 * 3_600)
        let created = try await calendar.create(CalendarEvent(id: "", calendarID: primary, accountID: account.id,
                                                              title: "Coffee", start: start, end: start.addingTimeInterval(1_800)))
        var renamed = created
        renamed.title = "Coffee with Lena"
        _ = try await calendar.update(renamed)
        let oneStandup = try XCTUnwrap(standups.sorted { $0.start < $1.start }.last)
        var moved = oneStandup
        moved.start = oneStandup.start.addingTimeInterval(1_800)
        moved.end = oneStandup.end.addingTimeInterval(1_800)
        _ = try await calendar.update(moved, scope: .thisEvent)
        let gym = try XCTUnwrap(events.first { $0.title == "Gym" })
        try await calendar.delete(gym, scope: .allEvents)
        let invite = try XCTUnwrap(events.first { $0.title == "Quarterly all-hands" })
        _ = try await calendar.respond(to: invite, status: .accepted)

        try await calendar.sync(accountID: account.id)
        events = try await calendar.cachedEvents(accountID: account.id, visibleOnly: false)
        XCTAssertTrue(events.contains { $0.title == "Coffee with Lena" })
        XCTAssertFalse(events.contains { $0.title == "Gym" })
        XCTAssertEqual(events.first { $0.id == oneStandup.id }?.start, moved.start)
        XCTAssertEqual(events.filter { $0.title == "Daily standup" }.count, standups.count)
        let accepted = try XCTUnwrap(events.first { $0.title == "Quarterly all-hands" })
        XCTAssertEqual(accepted.attendees.first { $0.isSelf }?.response, .accepted)
        XCTAssertEqual(accepted.attendees.count, 3)

        // State persists: a new backend instance reads the same mailbox from disk.
        let reopened = MockGoogleBackend(fileURL: directory.appendingPathComponent("google.json"))
        let reopenedAPI = GoogleAPI(auth: MockTokenProvider(), session: MockGoogleURLProtocol.session(backend: reopened))
        let filters = try await reopenedAPI.filters()
        XCTAssertEqual(filters.map(\.criteria.from), ["promo@dealsweekly.example"])
    }
}
