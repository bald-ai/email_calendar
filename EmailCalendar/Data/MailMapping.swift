import Foundation

/// RFC mailbox headers can contain quoted commas and encoded display names.
enum MailMapping {
    static func addresses(_ header: String?) -> [MailAddress] {
        guard let header else { return [] }
        return mailboxes(header).compactMap { chunk in
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

    /// Split only between mailboxes; quoted display names may themselves contain commas or semicolons.
    static func mailboxes(_ header: String, allowsSemicolons: Bool = false) -> [String] {
        var chunks: [String] = [], current = "", quoted = false, escaped = false, angleDepth = 0
        for character in header {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quoted { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if character == "<" { angleDepth += 1 }
                if character == ">" { angleDepth = max(0, angleDepth - 1) }
            }
            if (character == "," || (allowsSemicolons && character == ";")) && !quoted && angleDepth == 0 { chunks.append(current); current = "" }
            else { current.append(character) }
        }
        chunks.append(current)
        return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            result += data.flatMap { string($0, charset: charset) } ?? nsValue.substring(with: match.range)
            end = match.range.location + match.range.length
            previousEncoded = true
        }
        result += nsValue.substring(from: end)
        return result
    }

    /// Text in its declared charset (Czech mail is often windows-1250 or ISO-8859-2), else UTF-8, else Latin-1.
    static func string(_ data: Data, charset: String?) -> String? {
        if let encoding = encoding(charset: charset), let text = String(data: data, encoding: encoding) { return text }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func charset(of part: GoogleMailPart) -> String? {
        guard let type = part.headers?.first(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value,
              let range = type.range(of: "charset=", options: .caseInsensitive) else { return nil }
        return type[range.upperBound...].split(separator: ";").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")) }
    }

    private static func encoding(charset: String?) -> String.Encoding? {
        guard let name = charset?.lowercased(), !name.isEmpty else { return nil }
        switch name {
        case "utf-8", "utf8": return .utf8
        // As browsers do: mail labelled Latin-1 or ASCII is usually really windows-1252 (curly quotes, €).
        case "us-ascii", "ascii", "iso-8859-1", "iso8859-1", "latin1", "windows-1252", "cp1252": return .windowsCP1252
        case "iso-8859-2", "iso8859-2", "latin2": return .isoLatin2
        case "windows-1250", "cp1250": return .windowsCP1250
        case "windows-1251", "cp1251": return .windowsCP1251
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "iso-2022-jp": return .iso2022JP
        case "euc-jp": return .japaneseEUC
        default:
            #if canImport(Darwin)
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)) }
            #endif
            return nil
        }
    }

    static func message(_ source: GoogleMailMessage, accountID: String, labels: [String: String], draftID: String? = nil) -> MailMessage {
        let parts = source.payload?.descendants ?? []
        func text(mime: String) -> String {
            parts.filter { $0.mimeType == mime && ($0.filename ?? "").isEmpty }.compactMap { part in
                part.decodedData.flatMap { string($0, charset: charset(of: part)) }
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
        let references = (source.header("References") ?? "").split { $0.isWhitespace || $0 == "," }.map(String.init)
        return MailMessage(id: source.id, threadID: source.threadId, accountID: accountID,
                           from: addresses(source.header("From")).first ?? MailAddress(email: ""),
                           to: addresses(source.header("To")), cc: addresses(source.header("Cc")), bcc: addresses(source.header("Bcc")),
                           date: source.date ?? .distantPast, subject: decodedHeader(source.header("Subject")),
                           snippet: decodedSnippet(source.snippet ?? ""), plainText: plainBody(text(mime: "text/plain"), html: html), html: html.isEmpty ? nil : html,
                           attachments: attachments, labels: Set((source.labelIds ?? []).map { labels[$0] ?? $0 }),
                           rfcMessageID: source.header("Message-ID"), references: references, draftID: draftID,
                           replyTo: addresses(source.header("Reply-To")), inReplyTo: source.header("In-Reply-To"),
                           bodyIsExternal: parts.contains { ["text/plain", "text/html"].contains($0.mimeType ?? "") && ($0.filename ?? "").isEmpty && $0.body?.data == nil && $0.body?.attachmentId != nil })
    }

    static func thread(_ source: GoogleMailThread, accountID: String, labels: [String: String], drafts: [String: String] = [:], previous: MailThread? = nil, bubble: BubbleRecord? = nil, observedAt: Date = .now) -> MailThread {
        var messages = (source.messages ?? []).map { message($0, accountID: accountID, labels: labels, draftID: drafts[$0.id]) }.sorted { $0.date < $1.date }
        for index in messages.indices where messages[index].needsBodyHydration {
            if let hydrated = previous?.messages.first(where: { $0.id == messages[index].id && $0.bodyIsExternal == false }) {
                messages[index].plainText = hydrated.plainText
                messages[index].html = hydrated.html
                messages[index].bodyIsExternal = false
            }
        }
        var thread = MailThread(id: source.id, accountID: accountID, messages: messages,
                          labels: messages.reduce(into: Set<String>()) { $0.formUnion($1.labels) },
                          historyID: source.historyId, bubbleUpAt: bubble?.surfacedAt == nil ? bubble?.dueAt : nil,
                          bubbledAt: bubble?.surfacedAt ?? previous?.bubbledAt,
                          seenAt: previous?.seenAt,
                          seenHistoryID: previous?.seenHistoryID ?? previous?.historyID ?? source.historyId)
        if previous?.unread == true && !thread.unread {
            thread.seenAt = observedAt
            thread.seenHistoryID = source.historyId ?? thread.seenHistoryID
        }
        return thread
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
