import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import EmailCalendarCore

/// Stands in for Gmail: offline until told otherwise.
@MainActor
private final class FakeGmail {
    var online = false
    var refuses = false
    var saved: [OutgoingMessage] = []
    var save: ParkedDrafts.Saver {
        { [unowned self] outgoing in
            guard online else { throw URLError(.notConnectedToInternet) }
            if refuses { throw MIMEComposerError.invalidAddress("not-an-address") }
            var result = outgoing; result.draftID = "draft-\(saved.count + 1)"
            saved.append(result)
            return result
        }
    }
}

@MainActor
final class ParkedDraftsTests: XCTestCase {
    private func store() throws -> LocalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try LocalStore(url: directory.appendingPathComponent("cache.sqlite"))
    }

    private func email(_ subject: String) -> DraftSession {
        DraftSession(message: OutgoingMessage(to: ["recruiter@example.com"], subject: subject, body: "Thanks for the call."), delay: .seconds(60))
    }

    func testEmailKeptOfflineSurvivesRelaunchAndLeavesOnceGmailHasIt() async throws {
        let store = try store(), gmail = FakeGmail()
        let parked = ParkedDrafts(store: store)
        try await parked.park(email("Follow-up"), id: "one", title: "Follow-up", accountID: "owner", save: gmail.save)
        try await parked.park(email("Portfolio"), id: "two", title: "Portfolio", accountID: "owner", save: gmail.save)

        // Still offline: nothing is refused, nothing is lost, and the two don't replace each other.
        let offline = await parked.saveAll(accountID: "owner")
        XCTAssertTrue(offline.isEmpty)
        let stored = try await store.all(ParkedDraft.self, collection: ParkedDraft.collection, accountID: "owner")
        XCTAssertEqual(stored.count, 2)

        // Quit and relaunch while still offline.
        parked.drop()
        let relaunched = ParkedDrafts(store: store)
        try await relaunched.restore(accountID: "owner", delay: .seconds(60), save: gmail.save)
        XCTAssertEqual(relaunched.count, 2)

        gmail.online = true
        let online = await relaunched.saveAll(accountID: "owner")
        XCTAssertTrue(online.isEmpty)
        XCTAssertEqual(Set(gmail.saved.map(\.subject)), ["Follow-up", "Portfolio"])
        XCTAssertEqual(gmail.saved.first?.body, "Thanks for the call.")
        XCTAssertEqual(relaunched.count, 0)
        let remaining = try await store.all(ParkedDraft.self, collection: ParkedDraft.collection, accountID: "owner")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testARefusalThatIsNotTheNetworkIsReportedAndTheEmailIsKept() async throws {
        let store = try store(), gmail = FakeGmail()
        gmail.online = true; gmail.refuses = true
        let parked = ParkedDrafts(store: store)
        try await parked.park(email("Offer"), id: "one", title: "Offer", accountID: "owner", save: gmail.save)
        let refused = await parked.saveAll(accountID: "owner")
        XCTAssertEqual(refused.map(\.title), ["Offer"])
        let kept = try await store.all(ParkedDraft.self, collection: ParkedDraft.collection, accountID: "owner")
        XCTAssertEqual(kept.count, 1)
        let otherAccount = await parked.saveAll(accountID: "someone-else")
        XCTAssertTrue(otherAccount.isEmpty, "Only the signed-in account's emails are tried")
    }

    func testOnlyNetworkTroubleCountsAsTemporary() {
        XCTAssertTrue(ParkedDrafts.isConnectivityFailure(URLError(.timedOut)))
        XCTAssertTrue(ParkedDrafts.isConnectivityFailure(GoogleAPIError.authorization("No token")))
        XCTAssertTrue(ParkedDrafts.isConnectivityFailure(GoogleAPIError.http(status: 503, message: "Unavailable")))
        XCTAssertFalse(ParkedDrafts.isConnectivityFailure(GoogleAPIError.http(status: 400, message: "Bad request")))
        XCTAssertFalse(ParkedDrafts.isConnectivityFailure(MIMEComposerError.invalidAddress("x")))
    }
}
