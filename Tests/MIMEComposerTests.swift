import Foundation
import XCTest
@testable import EmailCalendarCore

final class MIMEComposerTests: XCTestCase {
    func testReplyDraftHeaderSurvivesMappingAndCacheReopen() throws {
        let json = #"{"id":"draft-message","threadId":"original-thread","labelIds":["DRAFT"],"payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"owner@example.com"},{"name":"To","value":"reader@example.com"},{"name":"Subject","value":"Re: A report"},{"name":"In-Reply-To","value":"<original@example.com>"},{"name":"References","value":"<root@example.com> <original@example.com>"}]}}"#
        let source = try JSONDecoder().decode(GoogleMailMessage.self, from: Data(json.utf8))
        let mapped = MailMapping.message(source, accountID: "owner@example.com", labels: [:], draftID: "draft-1")
        let cache = try JSONEncoder().encode(mapped)
        let reopened = try JSONDecoder().decode(MailMessage.self, from: cache)
        XCTAssertEqual(reopened.inReplyTo, "<original@example.com>")
        XCTAssertEqual(reopened.references, ["<root@example.com>", "<original@example.com>"])
        let outgoing = OutgoingMessage(to: reopened.to.map(\.email), subject: reopened.subject,
                                       draftID: reopened.draftID, threadID: reopened.threadID,
                                       inReplyTo: reopened.inReplyTo, references: reopened.references)
        let raw = try MIMEComposer.compose(outgoing, from: "owner@example.com")
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("In-Reply-To: <original@example.com>\r\n"))

        // Existing cache records predate this optional field and must stay readable.
        var oldRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: cache) as? [String: Any])
        oldRecord.removeValue(forKey: "inReplyTo")
        let oldData = try JSONSerialization.data(withJSONObject: oldRecord)
        XCTAssertNil(try JSONDecoder().decode(MailMessage.self, from: oldData).inReplyTo)
    }

    func testRejectsHeaderInjectionInSubjectAddressAndFilename() throws {
        let messages = [
            OutgoingMessage(to: ["reader@example.com"], subject: "Hello\r\nBcc: intruder@example.com"),
            OutgoingMessage(to: ["reader@example.com\nBcc: intruder@example.com"], subject: "Hello"),
            OutgoingMessage(to: ["reader@example.com"], subject: "Hello", attachments: [
                OutgoingAttachment(name: "report\r\nContent-Type: text/html", mimeType: "text/plain", data: Data())
            ])
        ]
        for message in messages {
            XCTAssertThrowsError(try MIMEComposer.compose(message, from: "owner@example.com"))
        }
    }

    func testUnicodeSubjectEncodedWordsRoundTrip() throws {
        let subject = String(repeating: "Příští týden 📅 — 東京 ", count: 9)
        let raw = try MIMEComposer.compose(OutgoingMessage(to: ["reader@example.com"], subject: subject), from: "owner@example.com")
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
        let header = try XCTUnwrap(text.range(of: "Subject: "))
        let remaining = text[header.upperBound...]
        let encoded = String(remaining.components(separatedBy: "\r\nMIME-Version:")[0])
        let words = encoded.components(separatedBy: "\r\n ")
        var decoded = ""
        for word in words {
            XCTAssertLessThanOrEqual(word.utf8.count, 75)
            XCTAssertTrue(word.hasPrefix("=?UTF-8?B?"))
            XCTAssertTrue(word.hasSuffix("?="))
            let base64 = String(word.dropFirst(10).dropLast(2))
            decoded += try XCTUnwrap(String(data: try XCTUnwrap(Data(base64Encoded: base64)), encoding: .utf8))
        }
        XCTAssertEqual(decoded, subject)
    }

    func testBinaryAttachmentsBccAndReplyHeaders() throws {
        let payload = Data((0...255).map(UInt8.init))
        let outgoing = OutgoingMessage(to: ["\"Jane Reader\" <jane@example.com>"], cc: ["copy@example.com"],
            bcc: ["private@example.com"], subject: "Re: A report", body: "First line\nSecond line",
            attachments: [OutgoingAttachment(name: "Příloha.pdf", mimeType: "application/pdf", data: payload)],
            inReplyTo: "<original@example.com>", references: ["<root@example.com>", "<original@example.com>"])
        let raw = try MIMEComposer.compose(outgoing, from: "owner@example.com")
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
        XCTAssertTrue(text.contains("Bcc: private@example.com\r\n"))
        XCTAssertTrue(text.contains("In-Reply-To: <original@example.com>\r\n"))
        XCTAssertTrue(text.contains("References: <root@example.com>\r\n <original@example.com>\r\n"))
        XCTAssertTrue(text.contains("filename*=utf-8''P%C5%99%C3%ADloha.pdf"))
        XCTAssertTrue(text.contains("Content-Type: multipart/mixed; boundary="))
        let chunks = text.components(separatedBy: "Content-Transfer-Encoding: base64\r\n\r\n")
        XCTAssertEqual(chunks.count, 3)
        let bodyEncoded = chunks[1].components(separatedBy: "\r\n--")[0]
        XCTAssertEqual(Data(base64Encoded: bodyEncoded, options: .ignoreUnknownCharacters), Data("First line\r\nSecond line".utf8))
        let attachmentEncoded = chunks[2].components(separatedBy: "\r\n--")[0]
        XCTAssertEqual(Data(base64Encoded: attachmentEncoded, options: .ignoreUnknownCharacters), payload)
        for line in attachmentEncoded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
    }

    func testBase64URLRoundTripsArbitraryBinaryAndPaddingLengths() {
        for length in 0...257 {
            let payload = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 37) })
            let encoded = payload.base64URL
            XCTAssertFalse(encoded.contains("+"))
            XCTAssertFalse(encoded.contains("/"))
            XCTAssertFalse(encoded.contains("="))
            XCTAssertEqual(Data(base64URL: encoded), payload)
        }
    }
}
