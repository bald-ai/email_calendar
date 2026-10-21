import Foundation

/// To-dos and email links live only on this Mac, per account, in the same database as the mail cache.
actor PlannerService {
    static let todoCollection = "planner.todos"
    static let linkCollection = "planner.links"
    private let store: LocalStore

    init(store: LocalStore) { self.store = store }

    func snapshot(accountID: String) async throws -> PlannerSnapshot {
        PlannerSnapshot(todos: try await store.all(TodoItem.self, collection: Self.todoCollection, accountID: accountID),
                        links: try await store.all(MailLink.self, collection: Self.linkCollection, accountID: accountID))
    }

    func save(_ todo: TodoItem, accountID: String) async throws {
        try await store.save(todo, id: todo.id, collection: Self.todoCollection, accountID: accountID, sortDate: todo.createdAt)
    }

    /// Deleting a to-do also drops its links; they are returned so an undo can put them back.
    @discardableResult
    func delete(todoID: String, accountID: String) async throws -> [MailLink] {
        let orphaned = try await store.all(MailLink.self, collection: Self.linkCollection, accountID: accountID)
            .filter { $0.target == .todo(todoID) }
        try await store.save([LocalStore.Record<MailLink>](), collection: Self.linkCollection, accountID: accountID,
                             removing: Set(orphaned.map(\.id)))
        try await store.remove(id: todoID, collection: Self.todoCollection, accountID: accountID)
        return orphaned
    }

    /// Adding a link that already exists keeps the original, so its date and order stay put.
    @discardableResult
    func add(_ link: MailLink, accountID: String) async throws -> Bool {
        if try await store.load(MailLink.self, id: link.id, collection: Self.linkCollection, accountID: accountID) != nil { return false }
        try await store.save(link, id: link.id, collection: Self.linkCollection, accountID: accountID, sortDate: link.createdAt)
        return true
    }

    func remove(linkID: String, accountID: String) async throws {
        try await store.remove(id: linkID, collection: Self.linkCollection, accountID: accountID)
    }

    func isSeeded(accountID: String) async throws -> Bool {
        try await store.metadata(Bool.self, key: "planner.seeded", accountID: accountID) == true
    }

    func markSeeded(accountID: String) async throws {
        try await store.setMetadata(true, key: "planner.seeded", accountID: accountID)
    }
}

/// The next few days as an agenda: all-day events first, then timed ones in order.
struct AgendaDay: Sendable, Identifiable, Equatable {
    var date: Date
    var allDay: [CalendarEvent]
    var timed: [CalendarEvent]
    var id: Date { date }
    var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }

    static func days(from now: Date, count: Int, events: [CalendarEvent], calendar: Calendar = .current) -> [AgendaDay] {
        let index = EventDayIndex(events.filter { !$0.isCancelled }, calendar: calendar)
        let first = calendar.startOfDay(for: now)
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let events = index.events(on: day)
            return AgendaDay(date: day, allDay: events.filter(\.isAllDay), timed: events.filter { !$0.isAllDay })
        }
    }
}
