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

    func testSavingParkedDraftPreservesAnotherComposersRecovery() async throws {
        let store = try store(), gmail = FakeGmail()
        let parked = ParkedDrafts(store: store)
        let closed = email("Closed while offline")
        try await parked.park(closed, id: "closed", title: "Closed", accountID: "owner", save: { outgoing in
            let saved = try await gmail.save(outgoing)
            try await store.removeDraftRecovery(ifMatching: saved, accountID: "owner")
            return saved
        })
        let open = email("Still editing")
        let recovery = DraftRecovery(title: "Open", buffer: try XCTUnwrap(open.recoveryBuffer))
        try await store.setMetadata(recovery, key: DraftRecovery.metadataKey, accountID: "owner")

        gmail.online = true
        let failures = await parked.saveAll(accountID: "owner")
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(parked.count, 0)
        let retained = try await store.metadata(DraftRecovery.self, key: DraftRecovery.metadataKey, accountID: "owner")
        XCTAssertEqual(retained, recovery, "Saving a different draft must not erase the open email's crash recovery")

        var savedOpen = open.outgoing
        savedOpen.draftID = "new-gmail-id"
        try await store.removeDraftRecovery(ifMatching: savedOpen, accountID: "owner")
        let cleared = try await store.metadata(DraftRecovery.self, key: DraftRecovery.metadataKey, accountID: "owner")
        XCTAssertNil(cleared, "Saving the checkpoint's own message clears it even when Gmail just assigned its ID")
    }
}
