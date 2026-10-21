import Foundation
import XCTest
@testable import EmailCalendarCore

final class RichBodyTests: XCTestCase {
    private let shot = OutgoingAttachment(name: "shot.png", mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]),
                                          contentID: "img1@emailcalendar.local", displayWidth: 640)
    private var body: String { "Hi <team>\n\nSee:\(RichBody.imageMarker)\nThanks" }

    func testBodyBecomesGmailStyleHTMLAndPlainText() {
        let html = RichBody.htmlFragment(body: body, images: [shot])
        XCTAssertEqual(html, "<div>Hi &lt;team&gt;</div><div><br></div><div>See:<img src=\"cid:img1@emailcalendar.local\" alt=\"shot.png\" width=\"640\" style=\"max-width:100%;height:auto\"></div><div>Thanks</div>")
        XCTAssertEqual(RichBody.plainText(body: body, images: [shot]), "Hi <team>\n\nSee:[image: shot.png]\nThanks")
    }

    func testSavedDraftReopensWithSameTextImagesAndQuote() {
        let quote = RichBody.replyQuote(header: "On 21 Oct, Maya wrote:", originalHTML: "<p>Original <b>text</b></p>", originalText: "Original text")
        let parsed = RichBody.parse(html: RichBody.document(body: body, images: [shot], quote: quote))
        XCTAssertEqual(parsed.body, body)
        XCTAssertEqual(parsed.imageIDs, ["img1@emailcalendar.local"])
        XCTAssertEqual(parsed.quoteHTML, quote.html)
        XCTAssertFalse(parsed.simplified)
        XCTAssertEqual(quote.text, "On 21 Oct, Maya wrote:\n> Original text")
    }

    func testGmailWebDraftIsFlattenedAndSaysSo() {
        let html = #"<div dir="ltr">Hello<div>second line</div><div><br></div><div>third <b>bold</b> &amp; more</div><img src="https://tracker.example/p.gif"></div>"#
        let parsed = RichBody.parse(html: html)
        XCTAssertEqual(parsed.body, "Hello\nsecond line\n\nthird bold & more")
        XCTAssertTrue(parsed.imageIDs.isEmpty)
        XCTAssertTrue(parsed.simplified)
        XCTAssertNil(parsed.quoteHTML)
    }

    func testQuoteNestedInsideTheWrapperIsSeparated() {
        let html = #"<div dir="ltr">Thanks!<br><div class="gmail_quote"><div class="gmail_attr">On Mon, A wrote:<br></div><blockquote class="gmail_quote">Hi</blockquote></div></div>"#
        let parsed = RichBody.parse(html: html)
        XCTAssertEqual(parsed.body, "Thanks!")
        XCTAssertEqual(parsed.quoteHTML, #"<div class="gmail_quote"><div class="gmail_attr">On Mon, A wrote:<br></div><blockquote class="gmail_quote">Hi</blockquote></div>"#)
    }

    func testQuotedHTMLLosesScriptsHandlersAndJavaScriptLinks() {
        let html = #"<html><head><style>p{}</style></head><body><p onclick="steal()">Hi <a href="javascript:alert(1)">x</a></p><script>bad()</script><form><input name="q"></form></body></html>"#
        let safe = RichBody.quotableHTML(html)
        XCTAssertEqual(safe, ##"<p>Hi <a href="#">x</a></p>"##)
        XCTAssertEqual(RichBody.plainText(fromHTML: "<div>A&nbsp;&#39;b&#x1F600;</div><div>c</div>"), "A 'b😀\nc")
    }

    func testHTMLEmailCarriesPlainCopyInlineImagesQuoteImagesAndAttachments() throws {
        let quoteImage = OutgoingAttachment(name: "logo.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: "q1")
        let quote = RichBody.replyQuote(header: "On Mon, A wrote:", originalHTML: #"<p>Original<img src="cid:q1"></p>"#,
                                        originalText: "Original", images: [quoteImage])
        let file = OutgoingAttachment(name: "notes.txt", mimeType: "text/plain", data: Data("notes".utf8))
        let outgoing = OutgoingMessage(to: ["reader@example.com"], subject: "Report", body: body, attachments: [file],
                                       isHTML: true, inlineImages: [shot], quote: quote)
        let raw = String(decoding: try MIMEComposer.compose(outgoing, from: "owner@example.com"), as: UTF8.self)
        for part in ["multipart/mixed", "multipart/alternative", "multipart/related", "Content-ID: <img1@emailcalendar.local>",
                     "Content-ID: <q1>", "Content-Disposition: inline;", "Content-Disposition: attachment;"] {
            XCTAssertTrue(raw.contains(part), part)
        }
        let parsed = MockMIME.parse(Data(raw.utf8))
        XCTAssertTrue(try XCTUnwrap(parsed.html).contains("cid:img1@emailcalendar.local"))
        XCTAssertTrue(try XCTUnwrap(parsed.html).contains("gmail_quote"))
        XCTAssertEqual(parsed.plain, "Hi <team>\n\nSee:[image: shot.png]\nThanks\n\nOn Mon, A wrote:\n> Original")
        XCTAssertEqual(parsed.attachments.map(\.contentID), ["img1@emailcalendar.local", "q1", nil])
        XCTAssertEqual(parsed.attachments.first?.data, shot.data)
    }

    func testRecoveryCopiesFromBeforeHTMLStillOpen() throws {
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OutgoingMessage(to: ["a@example.com"], body: "Hi"))) as? [String: Any])
        for key in ["isHTML", "inlineImages", "quote"] { record.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(OutgoingMessage.self, from: JSONSerialization.data(withJSONObject: record))
        XCTAssertFalse(old.isHTML)
        XCTAssertTrue(old.inlineImages.isEmpty)
        XCTAssertEqual(old.body, "Hi")
    }

    func testReopenedDraftRestoresImagesQuoteAndFilesAndDropsMissingImages() {
        let quote = RichBody.replyQuote(header: "On Mon, A wrote:", originalHTML: #"<p>Hi<img src="cid:q1"></p>"#, originalText: "Hi")
        let missing = OutgoingAttachment(name: "gone.png", mimeType: "image/png", data: Data([9]), contentID: "gone")
        let body = "Before\(RichBody.imageMarker)middle\(RichBody.imageMarker)after"
        let html = RichBody.document(body: body, images: [shot, missing], quote: quote)
        let draft = MailMessage(id: "m", threadID: "t", accountID: "owner@example.com", from: MailAddress(email: "work@example.org"),
                                to: [MailAddress(email: "reader@example.com")], subject: "Report", html: html,
                                attachments: [MailAttachment(id: "a1", name: "shot.png", mimeType: "image/png", contentID: "img1@emailcalendar.local"),
                                              MailAttachment(id: "a2", name: "logo.png", mimeType: "image/png", inlineData: Data([7]), contentID: "q1"),
                                              MailAttachment(id: "a3", name: "notes.txt", mimeType: "text/plain")],
                                draftID: "d1")
        let reopened = OutgoingMessage.reopening(draft, accountEmail: "owner@example.com",
                                                 data: ["a1": shot.data, "a3": Data("notes".utf8)])
        XCTAssertEqual(reopened.message.body, "Before\(RichBody.imageMarker)middleafter")
        XCTAssertEqual(reopened.message.inlineImages.map(\.contentID), ["img1@emailcalendar.local"])
        XCTAssertEqual(reopened.message.quote?.html, quote.html)
        XCTAssertEqual(reopened.message.quote?.images.map(\.data), [Data([7])])
        XCTAssertEqual(reopened.message.attachments.map(\.name), ["notes.txt"])
        XCTAssertEqual(reopened.message.from, "work@example.org")
        XCTAssertEqual(reopened.message.draftID, "d1")
        XCTAssertTrue(reopened.message.isHTML)
        XCTAssertFalse(reopened.simplified)
    }

    func testPlainDraftFromBeforeHTMLReopensAsItWas() {
        let draft = MailMessage(id: "m", threadID: "t", accountID: "owner@example.com", from: MailAddress(email: "owner@example.com"),
                                plainText: "Plain words\n> old quote", draftID: "d1")
        let reopened = OutgoingMessage.reopening(draft, accountEmail: "owner@example.com", data: [:])
        XCTAssertEqual(reopened.message.body, "Plain words\n> old quote")
        XCTAssertNil(reopened.message.quote)
        XCTAssertNil(reopened.message.from)
    }
}
