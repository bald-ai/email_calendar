import Foundation

/// The composer's text-and-images body as email HTML and plain text, and back again for reopened drafts.
/// The body string marks each inline image with U+FFFC (the character text views use for attachments),
/// and the matching images are listed in the same order.
public enum RichBody {
    public static let imageMarker: Character = "\u{FFFC}"

    // MARK: Writing

    /// The plain-text copy: images become "[image: name]".
    public static func plainText(body: String, images: [OutgoingAttachment]) -> String {
        var index = 0, result = ""
        for character in body {
            if character == imageMarker {
                result += "[image: \(index < images.count ? images[index].name : "image")]"
                index += 1
            } else { result.append(character) }
        }
        return result
    }

    /// One `<div>` per line, Gmail's own convention, so drafts round-trip with Gmail on other devices.
    public static func htmlFragment(body: String, images: [OutgoingAttachment]) -> String {
        var index = 0
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        return lines.map { line -> String in
            var html = "", text = ""
            func flush() { html += escapeText(text); text = "" }
            for character in line {
                if character == imageMarker {
                    flush()
                    if index < images.count, let tag = imageTag(images[index]) { html += tag }
                    index += 1
                } else { text.append(character) }
            }
            flush()
            return html.isEmpty ? "<div><br></div>" : "<div>\(html)</div>"
        }.joined()
    }

    /// The complete HTML part: the new text, then the quoted original.
    public static func document(body: String, images: [OutgoingAttachment], quote: MailQuote?) -> String {
        "<div dir=\"ltr\">\(htmlFragment(body: body, images: images))</div>" + (quote.map { "<br>" + $0.html } ?? "")
    }

    public static func replyQuote(header: String, originalHTML: String?, originalText: String, images: [OutgoingAttachment] = []) -> MailQuote {
        let inner = originalHTML.map(quotableHTML) ?? htmlFragment(body: originalText, images: [])
        let html = "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">\(escapeText(header))<br></div>"
            + "<blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">"
            + inner + "</blockquote></div>"
        let quoted = normalizedNewlines(originalText).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        return MailQuote(html: html, text: header + "\n" + quoted, images: images)
    }

    public static func forwardQuote(headerLines: [String], originalHTML: String?, originalText: String, images: [OutgoingAttachment] = []) -> MailQuote {
        let inner = originalHTML.map(quotableHTML) ?? htmlFragment(body: originalText, images: [])
        let html = "<div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">"
            + headerLines.map(escapeText).joined(separator: "<br>") + "<br></div><br><br>" + inner + "</div>"
        return MailQuote(html: html, text: headerLines.joined(separator: "\n") + "\n\n" + normalizedNewlines(originalText), images: images)
    }

    /// Someone else's HTML, made safe to include in a reply: no scripts, forms, frames or event handlers.
    public static func quotableHTML(_ html: String) -> String {
        var value = bodyContent(html)
        for tag in ["script", "style", "head", "title", "iframe", "object", "embed", "form", "textarea", "select", "button", "noscript"] {
            value = value.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"(?i)<(?:input|link|meta|base|frame)\b[^>]*>"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\s+on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)(href|src)\s*=\s*(["'])\s*javascript:[^"']*\2"#, with: "$1=\"#\"", options: .regularExpression)
        return value
    }

    /// Content-IDs an HTML body refers to with `cid:` sources.
    public static func contentIDs(in html: String) -> [String] {
        matches(of: #"(?i)src\s*=\s*["']?cid:([^"'\s>]+)"#, in: html).map { $0[1] }
    }

    // MARK: Reading

    public struct Parsed: Equatable, Sendable {
        /// Editable text with an image marker per entry of `imageIDs`.
        public var body: String
        /// Content-IDs of the images in the body, in order.
        public var imageIDs: [String]
        /// The quoted original, kept exactly as it was.
        public var quoteHTML: String?
        /// Formatting or remote images the composer cannot show were flattened or left out.
        public var simplified: Bool
    }

    /// Splits an email's HTML into editable text and images, and the quoted original. Nothing is fetched.
    public static func parse(html: String) -> Parsed {
        var source = bodyContent(html)
        var quote: String?
        if let range = source.range(of: #"<div[^>]*class\s*=\s*["'][^"']*gmail_quote"#, options: [.regularExpression, .caseInsensitive]) {
            quote = String(source[range.lowerBound...])
            source = String(source[..<range.lowerBound])
            // The separator before the quote, and the wrapper the quote closed, are not part of the text.
            source = source.replacingOccurrences(of: #"(?i)(<br\s*/?>\s*)+$"#, with: "", options: .regularExpression)
            // A quote nested inside the text's wrapper also carries the wrapper's closing tag.
            if let block = quote, occurrences(of: "<div", in: block) < occurrences(of: "</div", in: block),
               let trailing = block.range(of: #"(?i)</div>\s*$"#, options: .regularExpression) {
                quote?.removeSubrange(trailing)
            }
        }
        let text = text(from: source, keepingImages: true)
        return Parsed(body: text.body, imageIDs: text.imageIDs, quoteHTML: quote, simplified: text.simplified)
    }

    /// The readable text of an HTML fragment, for showing a quote while writing and for the plain-text copy.
    public static func plainText(fromHTML html: String) -> String {
        text(from: bodyContent(html), keepingImages: false).body
    }

    private static func text(from html: String, keepingImages: Bool) -> (body: String, imageIDs: [String], simplified: Bool) {
        var source = html
        var simplified = false
        var ids: [String] = []
        // Images: inline ones become markers; remote ones are dropped so nothing is fetched.
        var rebuilt = "", cursor = source.startIndex
        let imageExpression = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
        for match in imageExpression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            rebuilt += source[cursor..<range.lowerBound]
            let tag = String(source[range])
            if keepingImages, let id = contentIDs(in: tag).first { rebuilt.append(imageMarker); ids.append(id) }
            else if keepingImages { simplified = true }
            cursor = range.upperBound
        }
        rebuilt += source[cursor...]
        source = rebuilt
        for tag in ["script", "style", "head", "title"] {
            source = source.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: "", options: .regularExpression)
        }
        if source.range(of: #"(?i)<(b|strong|i|em|u|s|a|ul|ol|li|table|font|h[1-6]|blockquote|pre|code)\b|<span\b[^>]*style"#, options: .regularExpression) != nil {
            simplified = true
        }
        // Gmail writes a line as <div>…</div> and an empty line as <div><br></div>.
        source = source.replacingOccurrences(of: #"(?i)<br\s*/?>\s*(</(?:div|p)>)"#, with: "$1", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?i)</(?:div|p|li|tr|h[1-6]|blockquote|pre)\s*>"#, with: "\n", options: .regularExpression)
        source = source.replacingOccurrences(of: #"(?i)<(?:div|p|li|tr|h[1-6]|blockquote|pre)\b[^>]*>"#, with: "\u{1}", options: .regularExpression)
        source = source.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        // A block that starts mid-line starts a new line.
        var result = ""
        for character in source {
            if character == "\u{1}" { if let last = result.last, last != "\n" { result.append("\n") } }
            else { result.append(character) }
        }
        result = decodeEntities(result)
        while let last = result.last, last == "\n" || last == " " { result.removeLast() }
        return (result, ids, simplified)
    }

    // MARK: Helpers

    static func escapeText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        // Keep runs of spaces, which HTML would otherwise collapse.
        value = value.replacingOccurrences(of: "  ", with: " &nbsp;")
        if value.hasPrefix(" ") { value = "&nbsp;" + value.dropFirst() }
        return value
    }

    private static func imageTag(_ image: OutgoingAttachment) -> String? {
        guard let id = image.contentID, !id.contains(where: { "\"'<> \r\n".contains($0) }) else { return nil }
        let width = image.displayWidth.map { " width=\"\($0)\"" } ?? ""
        return "<img src=\"cid:\(id)\" alt=\"\(escapeText(image.name))\"\(width) style=\"max-width:100%;height:auto\">"
    }

    private static func bodyContent(_ html: String) -> String {
        guard let range = html.range(of: #"(?is)<body\b[^>]*>(.*)</body\s*>"#, options: .regularExpression) else { return html }
        let inner = String(html[range])
        return inner.replacingOccurrences(of: #"(?is)^<body\b[^>]*>|</body\s*>$"#, with: "", options: .regularExpression)
    }

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.lowercased().components(separatedBy: needle).count - 1
    }

    private static func matches(of pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&", "ndash": "–", "mdash": "—",
                     "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "euro": "€"]
        var result = "", cursor = text.startIndex
        let expression = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<whole.lowerBound]
            let name = String(text[nameRange])
            var replacement: String?
            if name.hasPrefix("#x") { replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
            else if name.hasPrefix("#") { replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } }
            else { replacement = named[name.lowercased()] }
            result += replacement ?? String(text[whole])
            cursor = whole.upperBound
        }
        result += text[cursor...]
        return result
    }
}

extension OutgoingAttachment {
    /// An inline image of a received or saved message, by Content-ID, if its bytes are at hand.
    /// `data` holds downloaded attachment bytes by attachment ID.
    public static func inlineImage(_ contentID: String, of message: MailMessage, data: [String: Data]) -> OutgoingAttachment? {
        guard let attachment = message.attachments.first(where: { $0.contentID == contentID }),
              let bytes = data[attachment.id] ?? attachment.inlineData else { return nil }
        return OutgoingAttachment(name: attachment.name, mimeType: attachment.mimeType, data: bytes, contentID: contentID)
    }

    /// The message's file attachments, leaving out images shown inside its HTML.
    public static func files(of message: MailMessage, data: [String: Data], excluding inline: Set<String>) -> [OutgoingAttachment] {
        message.attachments.filter { !($0.contentID.map(inline.contains) ?? false) }.compactMap { attachment in
            (data[attachment.id] ?? attachment.inlineData).map { OutgoingAttachment(name: attachment.name, mimeType: attachment.mimeType, data: $0) }
        }
    }
}

extension OutgoingMessage {
    /// A saved draft made editable again: its text and images go back into the editor, a quoted original is
    /// kept exactly as it was, and the rest stay attachments. `simplified` says formatting was flattened.
    public static func reopening(_ draft: MailMessage, accountEmail: String, data: [String: Data]) -> (message: OutgoingMessage, simplified: Bool) {
        var body = draft.plainText.isEmpty ? (draft.html.map(RichBody.plainText(fromHTML:)) ?? "") : draft.plainText
        var images: [OutgoingAttachment] = [], quote: MailQuote?, simplified = false, used = Set<String>()
        if let html = draft.html {
            let parsed = RichBody.parse(html: html)
            // An image whose bytes are missing loses its place instead of shifting the others.
            var index = 0, kept = ""
            for character in parsed.body {
                guard character == RichBody.imageMarker else { kept.append(character); continue }
                let id = parsed.imageIDs[index]; index += 1
                if let image = OutgoingAttachment.inlineImage(id, of: draft, data: data) { kept.append(character); images.append(image); used.insert(id) }
            }
            body = kept
            if let block = parsed.quoteHTML {
                let ids = RichBody.contentIDs(in: block)
                quote = MailQuote(html: block, text: RichBody.plainText(fromHTML: block),
                                  images: ids.compactMap { OutgoingAttachment.inlineImage($0, of: draft, data: data) })
                used.formUnion(ids)
            }
            simplified = parsed.simplified
        }
        let from = draft.from.email.isEmpty || draft.from.email.lowercased() == accountEmail.lowercased() ? nil : draft.from.email
        let message = OutgoingMessage(to: draft.to.map(\.email), cc: draft.cc.map(\.email), bcc: draft.bcc.map(\.email),
            subject: draft.subject, body: body, attachments: OutgoingAttachment.files(of: draft, data: data, excluding: used),
            draftID: draft.draftID, threadID: draft.threadID, inReplyTo: draft.inReplyTo, references: draft.references,
            rfcMessageID: draft.rfcMessageID ?? "<\(UUID().uuidString.lowercased())@emailcalendar.local>",
            from: from, isHTML: true, inlineImages: images, quote: quote)
        return (message, simplified)
    }
}
