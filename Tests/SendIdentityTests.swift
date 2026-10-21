import Foundation
import XCTest
@testable import EmailCalendarCore

final class SendIdentityTests: XCTestCase {
    private let addresses = ["owner@example.com", "Work@Example.org"]

    private func message(from: String, to: [String], cc: [String] = []) -> MailMessage {
        MailMessage(id: "m", threadID: "t", accountID: "owner@example.com", from: MailAddress(email: from),
                    to: to.map { MailAddress(email: $0) }, cc: cc.map { MailAddress(email: $0) })
    }

    func testReplyToMailForwardedFromAliasGoesOutFromAliasWithGmailSpelling() {
        let original = message(from: "recruiter@company.com", to: ["work@example.org"])
        XCTAssertEqual(SendIdentity.address(for: original, addresses: addresses, accountEmail: "owner@example.com"), "Work@Example.org")
    }

    func testReplyToMailForOwnAddressUsesDefault() {
        let original = message(from: "friend@example.net", to: ["owner@example.com"], cc: ["work@example.org"])
        XCTAssertNil(SendIdentity.address(for: original, addresses: addresses, accountEmail: "owner@example.com"))
    }

    func testFollowUpToOwnAliasMessageKeepsAlias() {
        let original = message(from: "work@example.org", to: ["recruiter@company.com"])
        XCTAssertEqual(SendIdentity.address(for: original, addresses: addresses, accountEmail: "owner@example.com"), "Work@Example.org")
    }

    func testUnverifiedAliasIsNeverChosen() {
        let original = message(from: "recruiter@company.com", to: ["work@example.org"])
        XCTAssertNil(SendIdentity.address(for: original, addresses: ["owner@example.com"], accountEmail: "owner@example.com"))
    }

    func testAliasBecomesFromHeaderAndOldDraftsDecodeWithoutIt() throws {
        let outgoing = OutgoingMessage(to: ["recruiter@company.com"], subject: "Hello", from: "work@example.org")
        let raw = String(decoding: try MIMEComposer.compose(outgoing, from: outgoing.from ?? "owner@example.com"), as: UTF8.self)
        XCTAssertTrue(raw.contains("From: work@example.org\r\n"))

        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(outgoing)) as? [String: Any])
        record.removeValue(forKey: "from")
        XCTAssertNil(try JSONDecoder().decode(OutgoingMessage.self, from: JSONSerialization.data(withJSONObject: record)).from)
    }
}

final class SpamThreadTests: XCTestCase {
    private func thread(_ labels: [Set<String>]) -> MailThread {
        let messages = labels.enumerated().map { index, labels in
            MailMessage(id: "m\(index)", threadID: "t", accountID: "owner@example.com", from: MailAddress(email: "a@example.net"), labels: labels)
        }
        return MailThread(id: "t", accountID: "owner@example.com", messages: messages,
                          labels: labels.reduce(into: Set<String>()) { $0.formUnion($1) })
    }

    func testOneSpamReplyDoesNotHideTheConversation() {
        let mixed = thread([["INBOX"], ["SPAM"]])
        XCTAssertTrue(mixed.hasSpam)
        XCTAssertFalse(mixed.isSpam)
    }

    func testConversationIsSpamWhenEveryRealMessageIs() {
        XCTAssertTrue(thread([["SPAM"], ["SPAM", "UNREAD"], ["DRAFT"]]).isSpam)
        XCTAssertFalse(thread([["INBOX"]]).hasSpam)
    }
}
