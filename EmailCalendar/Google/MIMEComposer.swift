import Foundation

public enum MIMEComposerError: Error, LocalizedError, Sendable {
    case invalidHeader(String)
    case invalidAddress(String)
    case oversizedMessage

    public var errorDescription: String? {
        switch self {
        case let .invalidHeader(field): "The \(field) contains characters that cannot be used in an email header."
        case let .invalidAddress(address): "Check the email address: \(address)"
        case .oversizedMessage: "This email is too large for Gmail. Reduce the attachment sizes and try again."
        }
    }
}

/// RFC 5322 / MIME encoding, including Unicode headers and binary attachments.
/// Gmail accepts the returned bytes base64url encoded in its `raw` message field.
public enum MIMEComposer {
    /// Use the encoder's mailbox rules for the Send button as well as the actual request.
    public static func hasValidRecipients(_ outgoing: OutgoingMessage) -> Bool {
        let recipients = outgoing.to + outgoing.cc + outgoing.bcc
        return !recipients.isEmpty && recipients.allSatisfy { (try? address($0)) != nil }
    }

    public static func compose(_ outgoing: OutgoingMessage, from: String) throws -> Data {
        try validateHeader(outgoing.subject, field: "subject")
        let fromAddress = try address(from)
        let to = try outgoing.to.map(address)
        let cc = try outgoing.cc.map(address)
        let bcc = try outgoing.bcc.map(address)
        let boundary = "EmailCalendar-\(UUID().uuidString)"
        let senderDomain = from.components(separatedBy: "@").last?.replacingOccurrences(of: ">", with: "") ?? "localhost"
        let messageID = outgoing.rfcMessageID ?? "<\(UUID().uuidString.lowercased())@\(senderDomain)>"
        try validateMessageID(messageID)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var headers = ["From: \(fromAddress)", "Date: \(date.string(from: .now))", "Message-ID: \(messageID)", "X-EmailCalendar-Delivery-ID: \(messageID)"]
        if !to.isEmpty { headers.append(foldAddressList("To", to)) }
        if !cc.isEmpty { headers.append(foldAddressList("Cc", cc)) }
        // Gmail strips this header from the delivered message after routing the Bcc recipients.
        if !bcc.isEmpty { headers.append(foldAddressList("Bcc", bcc)) }
        headers.append("Subject: \(encodeHeader(outgoing.subject))")
        if let reply = outgoing.inReplyTo {
            try validateMessageID(reply)
            headers.append("In-Reply-To: \(reply)")
        }
        if !outgoing.references.isEmpty {
            try outgoing.references.forEach(validateMessageID)
            headers.append("References: \(outgoing.references.joined(separator: "\r\n "))")
        }
        headers.append("MIME-Version: 1.0")
        var content = headers.joined(separator: "\r\n") + "\r\n"

        if outgoing.attachments.isEmpty {
            content += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            content += base64Lines(Data(normalizedNewlines(outgoing.body).utf8)) + "\r\n"
        } else {
            content += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            content += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            content += base64Lines(Data(normalizedNewlines(outgoing.body).utf8)) + "\r\n"
            for attachment in outgoing.attachments {
                try validateHeader(attachment.name, field: "attachment name")
                guard isMIMEType(attachment.mimeType) else { throw MIMEComposerError.invalidHeader("attachment MIME type") }
                content += "--\(boundary)\r\n"
                content += "Content-Type: \(attachment.mimeType)\r\n"
                content += "Content-Disposition: attachment;\r\n \(filenameParameter(attachment.name))\r\n"
                content += "Content-Transfer-Encoding: base64\r\n\r\n"
                content += base64Lines(attachment.data) + "\r\n"
            }
            content += "--\(boundary)--\r\n"
        }
        let result = Data(content.utf8)
        // Gmail's raw-message API has a 35 MB upload limit, including MIME overhead.
        guard result.count <= 35 * 1_024 * 1_024 else { throw MIMEComposerError.oversizedMessage }
        return result
    }

    private static func validateHeader(_ text: String, field: String) throws {
        guard !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw MIMEComposerError.invalidHeader(field)
        }
    }

    private static func address(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate the original too: trimming must not make an injected newline safe.
        try validateHeader(raw, field: "email address")
        let email: String
        let name: String?
        if let opening = value.lastIndex(of: "<"), value.hasSuffix(">") {
            email = String(value[value.index(after: opening)..<value.index(before: value.endIndex)])
            let prefix = String(value[..<opening]).trimmingCharacters(in: .whitespaces)
            name = prefix.isEmpty ? nil : prefix.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } else { email = value; name = nil }
        let pieces = email.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty,
              email.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![34, 40, 41, 44, 59, 60, 62, 92].contains($0) }) else {
            throw MIMEComposerError.invalidAddress(value)
        }
        guard let name else { return email }
        return "\(encodeHeader(name, quoteASCII: true)) <\(email)>"
    }

    private static func validateMessageID(_ value: String) throws {
        try validateHeader(value, field: "reply identifier")
        guard value.hasPrefix("<"), value.hasSuffix(">"), !value.contains(" "),
              value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw MIMEComposerError.invalidHeader("reply identifier") }
    }

    private static func encodeHeader(_ value: String, quoteASCII: Bool = false) -> String {
        if value.unicodeScalars.allSatisfy({ $0.isASCII }), value.utf8.count < 70 {
            return quoteASCII ? "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" : value
        }
        // Each encoded word is below RFC 2047's 75-character limit and ends at a
        // Unicode-scalar boundary, so no multi-byte character is split between words.
        var chunks: [Data] = []
        var current = Data()
        for scalar in value.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if current.count + bytes.count > 42 { chunks.append(current); current = Data() }
            current.append(bytes)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?\($0.base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func foldAddressList(_ field: String, _ addresses: [String]) -> String {
        "\(field): \(addresses.joined(separator: ",\r\n "))"
    }

    private static func normalizedNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func base64Lines(_ data: Data) -> String {
        let encoded = Array(data.base64EncodedString().utf8)
        return stride(from: 0, to: encoded.count, by: 76).map { start in
            String(decoding: encoded[start..<min(start + 76, encoded.count)], as: UTF8.self)
        }.joined(separator: "\r\n")
    }

    private static func filenameParameter(_ value: String) -> String {
        let value = value.isEmpty ? "attachment" : value
        if value.utf8.count <= 60 && value.unicodeScalars.allSatisfy(\.isASCII) {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "filename=\"\(escaped)\""
        }
        // Do not also send a lossy ASCII filename: Gmail/HEY can prefer it over
        // filename*, permanently replacing Unicode characters with underscores.
        // RFC 2231 continuations keep long UTF-8 names within header line limits.
        let atoms = value.utf8.map { byte -> String in
            if rfc2231Allowed.contains(UnicodeScalar(byte)) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }
        var chunks: [String] = [], current = ""
        for atom in atoms {
            if current.count + atom.count > 60 { chunks.append(current); current = "" }
            current += atom
        }
        if !current.isEmpty { chunks.append(current) }
        if chunks.count == 1 { return "filename*=utf-8''\(chunks[0])" }
        return chunks.enumerated().map { index, chunk in
            "filename*\(index)*=\(index == 0 ? "utf-8''" : "")\(chunk)"
        }.joined(separator: ";\r\n ")
    }

    private static func isMIMEType(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty }) else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [33, 35, 36, 38, 43, 45, 46, 47, 94, 95].contains($0) }
    }

    private static var rfc2231Allowed: CharacterSet {
        CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~")
    }
}
