import Foundation

/// RFC mailbox headers can contain quoted commas and encoded display names.
enum MailMapping {
    static func addresses(_ header: String?) -> [MailAddress] {
        guard let header else { return [] }
        var chunks: [String] = [], current = "", quoted = false, escaped = false, angleDepth = 0
        for character in header {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quoted { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if character == "<" { angleDepth += 1 }
                if character == ">" { angleDepth = max(0, angleDepth - 1) }
            }
            if character == "," && !quoted && angleDepth == 0 { chunks.append(current); current = "" }
            else { current.append(character) }
        }
        chunks.append(current)
        return chunks.compactMap { chunk in
            let value = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
                let email = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard email.contains("@") else { return nil }
                let name = value[..<open].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return MailAddress(email: email, name: decodedHeader(name))
            }
            let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            guard cleaned.contains("@") else { return nil }
            return MailAddress(email: cleaned.lowercased())
        }
    }

    static func decodedHeader(_ value: String?) -> String {
        guard let value else { return "" }
        guard let expression = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return value }
        let nsValue = value as NSString
        let matches = expression.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        var result = "", end = 0, previousEncoded = false
        for match in matches {
            let separator = nsValue.substring(with: NSRange(location: end, length: match.range.location - end))
            if !(previousEncoded && separator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { result += separator }
            let charset = nsValue.substring(with: match.range(at: 1)).lowercased()
            let encoding = nsValue.substring(with: match.range(at: 2)).lowercased()
            let content = nsValue.substring(with: match.range(at: 3))
            let data: Data?
            if encoding == "b" { data = Data(base64Encoded: content) }
            else {
                let bytes = Array(content.replacingOccurrences(of: "_", with: " ").utf8)
                var decoded: [UInt8] = [], index = 0
                while index < bytes.count {
                    if bytes[index] == 61, index + 2 < bytes.count,
                       let byte = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                        decoded.append(byte); index += 3
                    } else { decoded.append(bytes[index]); index += 1 }
                }
                data = Data(decoded)
            }
            let stringEncoding: String.Encoding = charset.contains("8859") || charset == "latin1" ? .isoLatin1 : (charset == "windows-1252" ? .windowsCP1252 : .utf8)
            result += data.flatMap { String(data: $0, encoding: stringEncoding) } ?? nsValue.substring(with: match.range)
            end = match.range.location + match.range.length
            previousEncoded = true
        }
        result += nsValue.substring(from: end)
        return result
    }

    static func message(_ source: GoogleMailMessage, accountID: String, labels: [String: String], draftID: String? = nil) -> MailMessage {
        let parts = source.payload?.descendants ?? []
        func text(mime: String) -> String {
            parts.filter { $0.mimeType == mime && ($0.filename ?? "").isEmpty }.compactMap { part in
                part.decodedData.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
            }.joined(separator: "\n")
        }
        let html = text(mime: "text/html")
        let attachments = parts.filter { part in
            !(part.filename ?? "").isEmpty || (part.headers?.contains { $0.name.caseInsensitiveCompare("Content-ID") == .orderedSame } == true && !(part.mimeType ?? "").hasPrefix("text/"))
        }.map { part in
            MailAttachment(id: part.body?.attachmentId ?? "inline:\(part.partId ?? part.filename ?? "attachment")",
                           name: (part.filename?.isEmpty == false ? part.filename! : "Inline image"), mimeType: part.mimeType ?? "application/octet-stream",
                           size: part.body?.size ?? 0, inlineData: part.decodedData,
                           contentID: part.headers?.first { $0.name.caseInsensitiveCompare("Content-ID") == .orderedSame }?.value.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
        }
        let references = (source.header("References") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        return MailMessage(id: source.id, threadID: source.threadId, accountID: accountID,
                           from: addresses(source.header("From")).first ?? MailAddress(email: ""),
                           to: addresses(source.header("To")), cc: addresses(source.header("Cc")), bcc: addresses(source.header("Bcc")),
                           date: source.date ?? .distantPast, subject: decodedHeader(source.header("Subject")),
                           snippet: decodedSnippet(source.snippet ?? ""), plainText: plainBody(text(mime: "text/plain"), html: html), html: html.isEmpty ? nil : html,
                           attachments: attachments, labels: Set((source.labelIds ?? []).map { labels[$0] ?? $0 }),
                           rfcMessageID: source.header("Message-ID"), references: references, draftID: draftID,
                           replyTo: addresses(source.header("Reply-To")), inReplyTo: source.header("In-Reply-To"))
    }

    static func thread(_ source: GoogleMailThread, accountID: String, labels: [String: String], drafts: [String: String] = [:], previous: MailThread? = nil, bubble: BubbleRecord? = nil) -> MailThread {
        let messages = (source.messages ?? []).map { message($0, accountID: accountID, labels: labels, draftID: drafts[$0.id]) }.sorted { $0.date < $1.date }
        return MailThread(id: source.id, accountID: accountID, messages: messages,
                          labels: messages.reduce(into: Set<String>()) { $0.formUnion($1.labels) },
                          historyID: source.historyId, bubbleUpAt: bubble?.surfacedAt == nil ? bubble?.dueAt : nil,
                          bubbledAt: bubble?.surfacedAt ?? previous?.bubbledAt)
    }

    private static func plainBody(_ plain: String, html: String) -> String {
        guard plain.isEmpty, !html.isEmpty else { return plain }
        var value = html
        for pattern in [#"<(script|style)\b[^>]*>.*?</\1>"#, #"<(br\s*/?|/p|/div|/li|/tr)>"#, #"<[^>]+>"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            value = expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: pattern.contains("br") ? "\n" : "")
        }
        return decodedSnippet(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodedSnippet(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
}
