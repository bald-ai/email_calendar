import Foundation

/// Small REST models keep transport details out of the app's persistent models.
public struct GooglePage<Item: Codable & Sendable>: Codable, Sendable {
    public var items: [Item]
    public var nextPageToken: String?
    public var nextSyncToken: String?

    public init(items: [Item], nextPageToken: String? = nil, nextSyncToken: String? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken
        self.nextSyncToken = nextSyncToken
    }

    private enum CodingKeys: String, CodingKey { case items, nextPageToken, nextSyncToken }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([Item].self, forKey: .items) ?? []
        nextPageToken = try values.decodeIfPresent(String.self, forKey: .nextPageToken)
        nextSyncToken = try values.decodeIfPresent(String.self, forKey: .nextSyncToken)
    }
}

public struct GoogleMailProfile: Codable, Sendable {
    public var emailAddress: String
    public var messagesTotal: Int?
    public var threadsTotal: Int?
    public var historyId: String
}

public struct GoogleMailThread: Codable, Sendable, Identifiable {
    public var id: String
    public var historyId: String?
    public var snippet: String?
    public var messages: [GoogleMailMessage]?
}

public struct GoogleMailMessage: Codable, Sendable, Identifiable {
    public var id: String
    public var threadId: String
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: String?
    public var internalDate: String?
    public var payload: GoogleMailPart?
    public var raw: String?
    public var sizeEstimate: Int?

    public func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var date: Date? {
        internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
}

public struct GoogleMailHeader: Codable, Sendable {
    public var name: String
    public var value: String
}

public struct GoogleMailPart: Codable, Sendable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GoogleMailHeader]?
    public var body: GoogleMailBody?
    public var parts: [GoogleMailPart]?

    public var descendants: [GoogleMailPart] { [self] + (parts ?? []).flatMap(\.descendants) }

    public var decodedData: Data? { body?.data.flatMap(Data.init(base64URL:)) }
}

public struct GoogleMailBody: Codable, Sendable {
    public var attachmentId: String?
    public var size: Int?
    public var data: String?
}

public struct GoogleLabel: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: String?
    public var messageListVisibility: String?
    public var labelListVisibility: String?
}

public struct GoogleDraft: Codable, Sendable, Identifiable {
    public var id: String
    public var message: GoogleMailMessage?
}

public struct GoogleFilter: Codable, Sendable, Identifiable {
    public var id: String?
    public var criteria: Criteria
    public var action: Action

    public struct Criteria: Codable, Sendable {
        public var from: String?
        public var to: String?
        public var subject: String?
        public var query: String?
        public var negatedQuery: String?
        public var hasAttachment: Bool?

        public init(from: String? = nil, query: String? = nil) {
            self.from = from
            self.query = query
        }
    }

    public struct Action: Codable, Sendable {
        public var addLabelIds: [String]?
        public var removeLabelIds: [String]?

        public init(addLabelIds: [String]? = nil, removeLabelIds: [String]? = nil) {
            self.addLabelIds = addLabelIds
            self.removeLabelIds = removeLabelIds
        }
    }

    public init(id: String? = nil, criteria: Criteria, action: Action) {
        self.id = id
        self.criteria = criteria
        self.action = action
    }
}

public struct GoogleHistoryPage: Codable, Sendable {
    public var history: [GoogleHistoryRecord]?
    public var nextPageToken: String?
    public var historyId: String
}

public struct GoogleHistoryRecord: Codable, Sendable {
    public var id: String
    public var messages: [GoogleMailMessage]?
    public var messagesAdded: [MessageChange]?
    public var messagesDeleted: [MessageChange]?
    public var labelsAdded: [LabelChange]?
    public var labelsRemoved: [LabelChange]?

    public struct MessageChange: Codable, Sendable {
        public var message: GoogleMailMessage
    }
    public struct LabelChange: Codable, Sendable {
        public var message: GoogleMailMessage
        public var labelIds: [String]
    }
    public var changedThreadIDs: Set<String> {
        var result = Set((messages ?? []).map(\.threadId))
        result.formUnion((messagesAdded ?? []).map { $0.message.threadId })
        result.formUnion((messagesDeleted ?? []).map { $0.message.threadId })
        result.formUnion((labelsAdded ?? []).map { $0.message.threadId })
        result.formUnion((labelsRemoved ?? []).map { $0.message.threadId })
        return result
    }
}

public struct GoogleCalendar: Codable, Sendable, Identifiable {
    public var id: String
    public var summary: String?
    public var summaryOverride: String?
    public var description: String?
    public var timeZone: String?
    public var backgroundColor: String?
    public var foregroundColor: String?
    public var primary: Bool?
    public var selected: Bool?
    public var accessRole: String?
    public var deleted: Bool?
}

public struct GoogleEventDateTime: Codable, Sendable, Equatable {
    public var date: String?
    public var dateTime: String?
    public var timeZone: String?

    public init(date: String? = nil, dateTime: String? = nil, timeZone: String? = nil) {
        self.date = date
        self.dateTime = dateTime
        self.timeZone = timeZone
    }
}

public struct GoogleAttendee: Codable, Sendable, Equatable {
    public var email: String?
    public var displayName: String?
    public var organizer: Bool?
    public var isSelf: Bool?
    public var responseStatus: String?
    public var optional: Bool?
    public var comment: String?

    private enum CodingKeys: String, CodingKey {
        case email, displayName, organizer, responseStatus, optional, comment
        case isSelf = "self"
    }

    public init(email: String, responseStatus: String? = nil) {
        self.email = email
        self.responseStatus = responseStatus
    }
}

public struct GoogleEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var status: String?
    public var summary: String?
    public var description: String?
    public var location: String?
    public var start: GoogleEventDateTime?
    public var end: GoogleEventDateTime?
    public var recurrence: [String]?
    public var recurringEventId: String?
    public var originalStartTime: GoogleEventDateTime?
    public var attendees: [GoogleAttendee]?
    public var organizer: GoogleAttendee?
    public var creator: GoogleAttendee?
    public var htmlLink: String?
    public var hangoutLink: String?
    public var conferenceData: ConferenceData?
    public var updated: String?
    public var etag: String?
    public var transparency: String?

    public struct ConferenceData: Codable, Sendable, Equatable {
        public var entryPoints: [EntryPoint]?
        public struct EntryPoint: Codable, Sendable, Equatable {
            public var entryPointType: String?
            public var uri: String?
            public var label: String?
        }
    }

    public init(id: String = "", summary: String, start: GoogleEventDateTime, end: GoogleEventDateTime,
                description: String? = nil, location: String? = nil, recurrence: [String]? = nil,
                attendees: [GoogleAttendee]? = nil) {
        self.id = id
        self.summary = summary
        self.start = start
        self.end = end
        self.description = description
        self.location = location
        self.recurrence = recurrence
        self.attendees = attendees
    }
}

extension Data {
    public init?(base64URL string: String) {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value, options: .ignoreUnknownCharacters)
    }
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
