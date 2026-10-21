import Foundation

public struct Account: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var email: String
    public var displayName: String
    public init(id: String, email: String, displayName: String = "") {
        self.id = id; self.email = email; self.displayName = displayName
    }
}

public enum Mailbox: String, CaseIterable, Identifiable, Sendable {
    case imbox, setAside, bubbleUp, screener, screenedOut, spam, sent, drafts, allMail, calendar
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .imbox: "Imbox"
        case .setAside: "Set Aside"
        case .bubbleUp: "Bubble Up"
        case .screener: "Screener"
        case .screenedOut: "Screened Out"
        case .spam: "Spam"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .allMail: "Everything"
        case .calendar: "Calendar"
        }
    }
    public var symbol: String {
        switch self {
        case .imbox: "tray"
        case .setAside: "pin"
        case .bubbleUp: "bubbles.and.sparkles"
        case .screener: "person.crop.circle.badge.questionmark"
        case .screenedOut: "hand.raised"
        case .spam: "xmark.bin"
        case .sent: "paperplane"
        case .drafts: "square.and.pencil"
        case .allMail: "archivebox"
        case .calendar: "calendar"
        }
    }
}

public struct MailAddress: Codable, Sendable, Hashable {
    public var email: String
    public var name: String
    public init(email: String, name: String = "") { self.email = email; self.name = name }
    public var displayName: String { name.isEmpty ? email : name }
    public var address: String { email }
    public var formatted: String { name.isEmpty ? email : "\(name) <\(email)>" }
}

public struct MailAttachment: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var size: Int
    public var inlineData: Data?
    public var contentID: String?
    public init(id: String, name: String, mimeType: String, size: Int = 0, inlineData: Data? = nil, contentID: String? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size; self.inlineData = inlineData
        self.contentID = contentID
    }
    public var filename: String { name }
}

public struct MailMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var threadID: String
    public var accountID: String
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var date: Date
    public var subject: String
    public var snippet: String
    public var plainText: String
    public var html: String?
    public var attachments: [MailAttachment]
    public var labels: Set<String>
    public var rfcMessageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var draftID: String?
    public var replyTo: [MailAddress]
    public var bodyIsExternal: Bool?
    public var needsBodyHydration: Bool {
        bodyIsExternal == true || (bodyIsExternal == nil && plainText.isEmpty && html == nil && !snippet.isEmpty)
    }
    public init(id: String, threadID: String, accountID: String, from: MailAddress,
                to: [MailAddress] = [], cc: [MailAddress] = [], bcc: [MailAddress] = [],
                date: Date = .now, subject: String = "", snippet: String = "", plainText: String = "",
                html: String? = nil, attachments: [MailAttachment] = [], labels: Set<String> = [],
                rfcMessageID: String? = nil, references: [String] = [], draftID: String? = nil, replyTo: [MailAddress] = [], inReplyTo: String? = nil, bodyIsExternal: Bool = false) {
        self.bodyIsExternal = bodyIsExternal
        self.id = id; self.threadID = threadID; self.accountID = accountID; self.from = from
        self.to = to; self.cc = cc; self.bcc = bcc; self.date = date; self.subject = subject
        self.snippet = snippet; self.plainText = plainText; self.html = html; self.attachments = attachments
        self.labels = labels; self.rfcMessageID = rfcMessageID; self.references = references; self.draftID = draftID
        self.replyTo = replyTo
        self.inReplyTo = inReplyTo
    }
    public var unread: Bool { labels.contains("UNREAD") }
    public var sentAt: Date { date }
    public var bodyText: String { plainText }
    public var bodyHTML: String? { html }
}

public struct MailThread: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var accountID: String
    public var messages: [MailMessage]
    public var labels: Set<String>
    public var historyID: String?
    public var bubbleUpAt: Date?
    public var bubbledAt: Date?
    public init(id: String, accountID: String, messages: [MailMessage] = [], labels: Set<String> = [],
                historyID: String? = nil, bubbleUpAt: Date? = nil, bubbledAt: Date? = nil) {
        self.id = id; self.accountID = accountID; self.messages = messages; self.labels = labels
        self.historyID = historyID; self.bubbleUpAt = bubbleUpAt; self.bubbledAt = bubbledAt
    }
    public var latestMessage: MailMessage? { messages.max { $0.date < $1.date } }
    public var subject: String { latestMessage?.subject.isEmpty == false ? latestMessage!.subject : "(No subject)" }
    public var snippet: String { latestMessage?.snippet ?? "" }
    public var updatedAt: Date { latestMessage?.date ?? .distantPast }
    public var unread: Bool { messages.contains { $0.unread } }
    public var sender: MailAddress {
        messages.filter { !$0.labels.contains("SENT") && !$0.labels.contains("DRAFT") && $0.from.email.lowercased() != accountID.lowercased() }
            .max { $0.date < $1.date }?.from ?? latestMessage?.from ?? MailAddress(email: "")
    }
    public var isSetAside: Bool { labels.contains("HEY/Set Aside") }
    /// Gmail marks spam per message. A conversation counts as spam only when every message is,
    /// so one spam reply never hides the rest of it; Spam lists any conversation that has one.
    public var hasSpam: Bool { labels.contains("SPAM") }
    public var isSpam: Bool {
        let real = messages.filter { !$0.labels.contains("DRAFT") }
        return hasSpam && (real.isEmpty ? true : real.allSatisfy { $0.labels.contains("SPAM") })
    }
}

public struct OutgoingAttachment: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var data: Data
    /// Set for an image shown inside the email body, which refers to it as `cid:<contentID>`.
    public var contentID: String?
    /// The width the image is shown at, in points; the full-resolution pixels are still sent.
    public var displayWidth: Int?
    public init(id: String = UUID().uuidString, name: String, mimeType: String, data: Data,
                contentID: String? = nil, displayWidth: Int? = nil) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.data = data
        self.contentID = contentID; self.displayWidth = displayWidth
    }
}

/// The quoted original of a reply or forward. It is added below the new text when the email is
/// saved or sent, and is never rendered while writing, so its remote images cannot load.
public struct MailQuote: Codable, Sendable, Equatable {
    /// A complete `gmail_quote` block, with scripts, forms and event handlers removed.
    public var html: String
    /// The same quote for the plain-text copy of the email.
    public var text: String
    /// Inline images the quoted HTML refers to, with their original Content-IDs.
    public var images: [OutgoingAttachment]
    public init(html: String, text: String, images: [OutgoingAttachment] = []) {
        self.html = html; self.text = text; self.images = images
    }
}

public struct OutgoingMessage: Codable, Sendable, Equatable {
    /// Stable across autosaves and retries, so an interrupted send can be found in Gmail.
    public var rfcMessageID: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    public var attachments: [OutgoingAttachment]
    public var draftID: String?
    public var threadID: String?
    public var inReplyTo: String?
    public var references: [String]
    /// A verified Gmail "Send mail as" address; nil sends from the account's own address.
    public var from: String?
    /// Sent as HTML with a plain-text copy. The body then marks each inline image with
    /// `RichBody.imageMarker`, in the order of `inlineImages`. False sends plain text only.
    public var isHTML: Bool
    public var inlineImages: [OutgoingAttachment]
    public var quote: MailQuote?
    public init(to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String = "", body: String = "",
                attachments: [OutgoingAttachment] = [], draftID: String? = nil, threadID: String? = nil,
                inReplyTo: String? = nil, references: [String] = [],
                rfcMessageID: String? = "<\(UUID().uuidString.lowercased())@emailcalendar.local>", from: String? = nil,
                isHTML: Bool = false, inlineImages: [OutgoingAttachment] = [], quote: MailQuote? = nil) {
        self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.body = body
        self.attachments = attachments; self.draftID = draftID; self.threadID = threadID
        self.inReplyTo = inReplyTo; self.references = references
        self.rfcMessageID = rfcMessageID; self.from = from
        self.isHTML = isHTML; self.inlineImages = inlineImages; self.quote = quote
    }

    /// Recovery copies saved before HTML email existed have no format fields.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rfcMessageID = try c.decodeIfPresent(String.self, forKey: .rfcMessageID)
        to = try c.decode([String].self, forKey: .to); cc = try c.decode([String].self, forKey: .cc)
        bcc = try c.decode([String].self, forKey: .bcc)
        subject = try c.decode(String.self, forKey: .subject); body = try c.decode(String.self, forKey: .body)
        attachments = try c.decode([OutgoingAttachment].self, forKey: .attachments)
        draftID = try c.decodeIfPresent(String.self, forKey: .draftID); threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        inReplyTo = try c.decodeIfPresent(String.self, forKey: .inReplyTo)
        references = try c.decode([String].self, forKey: .references)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        isHTML = try c.decodeIfPresent(Bool.self, forKey: .isHTML) ?? false
        inlineImages = try c.decodeIfPresent([OutgoingAttachment].self, forKey: .inlineImages) ?? []
        quote = try c.decodeIfPresent(MailQuote.self, forKey: .quote)
    }

    /// Everything that travels with the email, for the size shown while writing.
    public var totalAttachmentBytes: Int {
        (attachments + inlineImages + (quote?.images ?? [])).reduce(0) { $0 + $1.data.count }
    }
}

/// Picks which of the account's "Send mail as" addresses a reply or forward goes out from.
public enum SendIdentity {
    /// The address the original was sent from (when it is one of ours) or to; nil means the account's own address.
    /// `addresses` are the verified Gmail send-as addresses, including the account's own.
    public static func address(for original: MailMessage, addresses: [String], accountEmail: String) -> String? {
        let own = Dictionary(addresses.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let involved = ([original.from] + original.to + original.cc).map { $0.email.lowercased() }
        guard let match = involved.first(where: { own[$0] != nil }), match != accountEmail.lowercased() else { return nil }
        return own[match]
    }
}

public enum ScreeningDecision: String, Codable, Sendable { case approved, blocked }

public struct SenderRule: Codable, Sendable, Identifiable, Equatable {
    public var accountID: String
    public var key: String
    public var decision: ScreeningDecision
    public var filterID: String?
    public var allowsRemoteImages: Bool
    public var id: String { "\(accountID):\(key)" }
    public var isDomain: Bool { key.hasPrefix("@") }
    public init(accountID: String, key: String, decision: ScreeningDecision, filterID: String? = nil,
                allowsRemoteImages: Bool = false) {
        self.accountID = accountID; self.key = key.lowercased(); self.decision = decision
        self.filterID = filterID; self.allowsRemoteImages = allowsRemoteImages
    }
}

public struct BubbleRecord: Codable, Sendable, Identifiable, Equatable {
    public var accountID: String
    public var threadID: String
    public var dueAt: Date
    public var surfacedAt: Date?
    public var id: String { "\(accountID):\(threadID)" }
    public init(accountID: String, threadID: String, dueAt: Date, surfacedAt: Date? = nil) {
        self.accountID = accountID; self.threadID = threadID; self.dueAt = dueAt; self.surfacedAt = surfacedAt
    }
}

public struct CalendarRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var accountID: String
    public var title: String
    public var colorHex: String
    public var isVisible: Bool
    public var isPrimary: Bool
    public var accessRole: String
    public init(id: String, accountID: String, title: String, colorHex: String = "#6586B5", isVisible: Bool = true,
                isPrimary: Bool = false, accessRole: String = "owner") {
        self.id = id; self.accountID = accountID; self.title = title; self.colorHex = colorHex
        self.isVisible = isVisible; self.isPrimary = isPrimary; self.accessRole = accessRole
    }
    public var color: String { colorHex }
    public var canEdit: Bool { accessRole == "owner" || accessRole == "writer" }
}

public enum AttendanceStatus: String, Codable, Sendable, CaseIterable {
    case accepted, declined, tentative, needsAction
}
public enum EventEditScope: String, Codable, Sendable { case thisEvent, allEvents }

public struct EventAttendee: Codable, Sendable, Identifiable, Equatable {
    public var email: String
    public var name: String?
    public var response: AttendanceStatus
    public var isSelf: Bool
    public var isOrganizer: Bool
    public var id: String { email }
    public init(email: String, name: String? = nil, response: AttendanceStatus = .needsAction,
                isSelf: Bool = false, isOrganizer: Bool = false) {
        self.email = email; self.name = name; self.response = response; self.isSelf = isSelf; self.isOrganizer = isOrganizer
    }
}

public struct CalendarEvent: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var calendarID: String
    public var accountID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var notes: String
    public var recurrence: [String]
    public var recurringEventID: String?
    public var originalStart: Date?
    public var videoURL: URL?
    public var htmlLink: URL?
    public var attendees: [EventAttendee]
    public var status: String
    public var etag: String?
    /// IANA zone in which timed recurrences are expanded.
    public var timeZone: String?
    public init(id: String = UUID().uuidString, calendarID: String, accountID: String, title: String = "",
                start: Date = .now, end: Date = .now.addingTimeInterval(1800), isAllDay: Bool = false,
                location: String = "", notes: String = "", recurrence: [String] = [],
                recurringEventID: String? = nil, originalStart: Date? = nil, videoURL: URL? = nil,
                htmlLink: URL? = nil, attendees: [EventAttendee] = [], status: String = "confirmed", etag: String? = nil, timeZone: String? = nil) {
        self.id = id; self.calendarID = calendarID; self.accountID = accountID; self.title = title
        self.start = start; self.end = end; self.isAllDay = isAllDay; self.location = location; self.notes = notes
        self.recurrence = recurrence; self.recurringEventID = recurringEventID; self.originalStart = originalStart
        self.videoURL = videoURL; self.htmlLink = htmlLink; self.attendees = attendees; self.status = status; self.etag = etag; self.timeZone = timeZone
    }
    public var isRecurring: Bool { recurringEventID != nil || !recurrence.isEmpty }
    public var isCancelled: Bool { status == "cancelled" }
    public var cacheID: String { "\(accountID)|\(calendarID)|\(id)" }
}
