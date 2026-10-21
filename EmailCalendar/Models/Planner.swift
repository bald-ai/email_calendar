import Foundation

/// A to-do kept on this Mac, next to the mail and calendar it often comes from.
public struct TodoItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var note: String
    public var createdAt: Date
    public var completedAt: Date?
    public init(id: String = UUID().uuidString, title: String, note: String = "", createdAt: Date = .now, completedAt: Date? = nil) {
        self.id = id; self.title = title; self.note = note; self.createdAt = createdAt; self.completedAt = completedAt
    }
    public var isDone: Bool { completedAt != nil }
}

/// What an email thread is linked to: a calendar event (by `CalendarEvent.cacheID`) or a to-do.
public enum LinkTarget: Codable, Sendable, Hashable {
    case event(String)
    case todo(String)

    public var key: String {
        switch self {
        case .event(let id): "event:\(id)"
        case .todo(let id): "todo:\(id)"
        }
    }
}

/// An email thread attached to an event or to-do. The titles are kept so a link still reads well
/// when its thread or event is not loaded (archived mail, an event outside the synced range).
public struct MailLink: Codable, Sendable, Identifiable, Equatable {
    public var threadID: String
    public var target: LinkTarget
    public var subject: String
    public var senderName: String
    public var senderEmail: String
    public var targetTitle: String
    public var targetStart: Date?
    public var createdAt: Date
    public var id: String { "\(threadID)>\(target.key)" }
    public init(threadID: String, target: LinkTarget, subject: String, senderName: String, senderEmail: String,
                targetTitle: String, targetStart: Date? = nil, createdAt: Date = .now) {
        self.threadID = threadID; self.target = target; self.subject = subject; self.senderName = senderName
        self.senderEmail = senderEmail; self.targetTitle = targetTitle; self.targetStart = targetStart; self.createdAt = createdAt
    }
}

public struct PlannerSnapshot: Sendable, Equatable {
    public var todos: [TodoItem]
    public var links: [MailLink]
    public init(todos: [TodoItem] = [], links: [MailLink] = []) { self.todos = todos; self.links = links }

    /// Open to-dos newest first, then finished ones, most recently finished first.
    public var openTodos: [TodoItem] { todos.filter { !$0.isDone }.sorted { $0.createdAt > $1.createdAt } }
    public var doneTodos: [TodoItem] {
        todos.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    public func links(threadID: String) -> [MailLink] {
        links.filter { $0.threadID == threadID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func links(to target: LinkTarget) -> [MailLink] {
        links.filter { $0.target == target }.sorted { $0.createdAt < $1.createdAt }
    }
}
