import Foundation
import Testing
@testable import EmailCalendarCore

struct PlannerTests {
    private func makeService() throws -> (PlannerService, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (PlannerService(store: try LocalStore(url: directory.appendingPathComponent("cache.sqlite"))), directory)
    }

    private func link(_ threadID: String, _ target: LinkTarget, at date: Date = .now) -> MailLink {
        MailLink(threadID: threadID, target: target, subject: "Subject \(threadID)", senderName: "Sender", senderEmail: "s@example.com",
                 targetTitle: "Target", createdAt: date)
    }

    @Test func todosAndLinksPersistPerAccount() async throws {
        let (service, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invoice = TodoItem(title: "Send invoice", note: "PO 4471")
        try await service.save(invoice, accountID: "alex")
        try await service.add(link("t-acme", .todo(invoice.id)), accountID: "alex")
        try await service.add(link("t-dental", .event("alex|cal|seed9")), accountID: "alex")

        let alex = try await service.snapshot(accountID: "alex")
        #expect(alex.todos == [invoice])
        #expect(alex.links(threadID: "t-acme").map(\.target) == [.todo(invoice.id)])
        #expect(alex.links(to: .event("alex|cal|seed9")).map(\.threadID) == ["t-dental"])
        #expect(try await service.snapshot(accountID: "bob") == PlannerSnapshot())
    }

    @Test func linkingTwiceKeepsTheFirstLink() async throws {
        let (service, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = link("t-1", .todo("a"), at: Date(timeIntervalSince1970: 100))
        #expect(try await service.add(first, accountID: "alex"))
        #expect(try await service.add(link("t-1", .todo("a"), at: Date(timeIntervalSince1970: 900)), accountID: "alex") == false)
        #expect(try await service.snapshot(accountID: "alex").links == [first])
    }

    @Test func deletingATodoDropsOnlyItsLinksAndReturnsThem() async throws {
        let (service, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = TodoItem(title: "Keep"), drop = TodoItem(title: "Drop")
        try await service.save(keep, accountID: "alex")
        try await service.save(drop, accountID: "alex")
        let dropped = link("t-1", .todo(drop.id)), kept = link("t-1", .todo(keep.id)), event = link("t-2", .event("e"))
        for item in [dropped, kept, event] { try await service.add(item, accountID: "alex") }

        let removed = try await service.delete(todoID: drop.id, accountID: "alex")
        #expect(removed == [dropped])
        let snapshot = try await service.snapshot(accountID: "alex")
        #expect(snapshot.todos == [keep])
        #expect(Set(snapshot.links.map(\.id)) == [kept.id, event.id])
    }

    @Test func todosSortOpenNewestFirstAndDoneByCompletion() {
        let old = TodoItem(title: "Old", createdAt: Date(timeIntervalSince1970: 1))
        let new = TodoItem(title: "New", createdAt: Date(timeIntervalSince1970: 5))
        let doneEarly = TodoItem(title: "Done early", createdAt: .distantPast, completedAt: Date(timeIntervalSince1970: 10))
        let doneLate = TodoItem(title: "Done late", createdAt: .distantPast, completedAt: Date(timeIntervalSince1970: 20))
        let snapshot = PlannerSnapshot(todos: [old, doneEarly, new, doneLate])
        #expect(snapshot.openTodos.map(\.title) == ["New", "Old"])
        #expect(snapshot.doneTodos.map(\.title) == ["Done late", "Done early"])
    }

    @Test func seededFlagSticks() async throws {
        let (service, directory) = try makeService()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await service.isSeeded(accountID: "alex") == false)
        try await service.markSeeded(accountID: "alex")
        #expect(try await service.isSeeded(accountID: "alex"))
        #expect(try await service.isSeeded(accountID: "bob") == false)
    }

    @Test func agendaGroupsSevenDaysWithAllDayFirstAndSkipsCancelled() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 42))!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false, status: String = "confirmed") -> CalendarEvent {
            CalendarEvent(id: title, calendarID: "c", accountID: "a", title: title, start: start, end: end, isAllDay: allDay, status: status)
        }
        let events = [
            event("Lunch", at(13, 12, 30), at(13, 13, 15)),
            event("Standup", at(13, 9), at(13, 9, 15)),
            event("Trip", at(15, 0), at(17, 0), allDay: true),
            event("Cancelled", at(14, 10), at(14, 11), status: "cancelled"),
            event("Too late", at(20, 10), at(20, 11)),
            event("Yesterday", at(12, 10), at(12, 11)),
        ]
        let days = AgendaDay.days(from: now, count: 7, events: events, calendar: calendar)
        #expect(days.count == 7)
        #expect(days.first?.date == at(13, 0))
        #expect(days[0].timed.map(\.title) == ["Standup", "Lunch"])
        #expect(days[1].isEmpty)
        #expect(days[2].allDay.map(\.title) == ["Trip"] && days[3].allDay.map(\.title) == ["Trip"] && days[4].isEmpty)
        #expect(days.allSatisfy { !($0.timed + $0.allDay).contains { ["Too late", "Yesterday", "Cancelled"].contains($0.title) } })
    }
}
