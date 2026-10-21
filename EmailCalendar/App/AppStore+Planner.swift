#if os(macOS)
import Foundation

/// Asks a drawer to bring one event or to-do into view and highlight it.
struct PlannerReveal: Equatable {
    var target: LinkTarget
    var id = UUID()
}

/// To-dos, email links and the drawers beside mail.
extension AppStore {
    func loadPlanner(accountID: String) async throws {
        guard account?.id == accountID, let plannerService else { return }
        let snapshot = try await plannerService.snapshot(accountID: accountID)
        if account?.id == accountID { planner = snapshot }
    }

    private func reloadPlanner(_ accountID: String) async {
        do { try await loadPlanner(accountID: accountID) } catch { reportError(error) }
    }

    // MARK: Lookups

    func links(threadID: String) -> [MailLink] { planner.links(threadID: threadID) }
    func links(to target: LinkTarget) -> [MailLink] { planner.links(to: target) }
    func isLinked(_ threadID: String) -> Bool { planner.links.contains { $0.threadID == threadID } }
    func event(cacheID: String) -> CalendarEvent? { events.first { $0.cacheID == cacheID } }
    func todo(id: String) -> TodoItem? { planner.todos.first { $0.id == id } }

    /// The live title and start of a link's event or to-do, or nil when it no longer exists here.
    func targetSummary(_ target: LinkTarget) -> (title: String, start: Date?)? {
        switch target {
        case .event(let id): event(cacheID: id).map { ($0.title.isEmpty ? "Untitled event" : $0.title, $0.start) }
        case .todo(let id): todo(id: id).map { ($0.title, nil) }
        }
    }

    private func makeLink(_ thread: MailThread, _ target: LinkTarget, title: String, start: Date?) -> MailLink {
        MailLink(threadID: thread.id, target: target, subject: thread.subject, senderName: thread.sender.displayName,
                 senderEmail: thread.sender.email, targetTitle: title, targetStart: start)
    }

    // MARK: To-dos

    @discardableResult
    func addTodo(title: String, note: String = "", linking thread: MailThread? = nil) async -> TodoItem? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let account, let plannerService else { return nil }
        let todo = TodoItem(title: title, note: note)
        do {
            try await plannerService.save(todo, accountID: account.id)
            if let thread {
                try await plannerService.add(makeLink(thread, .todo(todo.id), title: todo.title, start: nil), accountID: account.id)
            }
        } catch { reportError(error) }
        await reloadPlanner(account.id)
        return todo
    }

    func updateTodo(_ todo: TodoItem) async {
        guard let account, let plannerService else { return }
        do { try await plannerService.save(todo, accountID: account.id) } catch { reportError(error) }
        await reloadPlanner(account.id)
    }

    func setDone(_ todo: TodoItem, _ done: Bool) async {
        var changed = todo
        changed.completedAt = done ? .now : nil
        await updateTodo(changed)
    }

    func deleteTodo(_ todo: TodoItem) async {
        guard let account, let plannerService else { return }
        let accountID = account.id
        do {
            let removedLinks = try await plannerService.delete(todoID: todo.id, accountID: accountID)
            await reloadPlanner(accountID)
            offerUndo("To-do deleted") { [weak self] in
                guard let self, self.account?.id == accountID, let plannerService = self.plannerService else { return }
                do {
                    try await plannerService.save(todo, accountID: accountID)
                    for link in removedLinks { try await plannerService.add(link, accountID: accountID) }
                } catch { self.reportError(error) }
                await self.reloadPlanner(accountID)
            }
        } catch { reportError(error) }
    }

    /// Makes a to-do from the thread, linked to it, and takes the thread out of the Imbox. Undo reverses both.
    func moveToTodo(_ thread: MailThread) async {
        guard let todo = await addTodo(title: thread.subject, linking: thread), let accountID = account?.id else { return }
        let removeTodo: @MainActor () async -> Void = { [weak self] in
            guard let self, self.account?.id == accountID, let plannerService = self.plannerService else { return }
            do { try await plannerService.delete(todoID: todo.id, accountID: accountID) } catch { self.reportError(error) }
            await self.reloadPlanner(accountID)
        }
        if thread.labels.contains("INBOX"), await archive(thread) {
            undoFollowUp = removeTodo
            undoMessage = "Moved to To-do"
            advanceAfterAction(from: thread.id)
        } else {
            offerUndo("Added to To-do", removeTodo)
        }
        reveal(.todo(todo.id))
    }

    // MARK: Links

    /// Links a thread to an event or to-do. Linking the same pair twice keeps the first link.
    @discardableResult
    func link(threadID: String, to target: LinkTarget) async -> Bool {
        guard let account, let plannerService, let thread = thread(id: threadID), let summary = targetSummary(target) else { return false }
        let accountID = account.id
        do {
            let link = makeLink(thread, target, title: summary.title, start: summary.start)
            let added = try await plannerService.add(link, accountID: accountID)
            await reloadPlanner(accountID)
            plannerReveal = PlannerReveal(target: target)
            guard added else { return false }
            offerUndo("Linked to \(summary.title)") { [weak self] in
                guard let self, self.account?.id == accountID, let plannerService = self.plannerService else { return }
                do { try await plannerService.remove(linkID: link.id, accountID: accountID) } catch { self.reportError(error) }
                await self.reloadPlanner(accountID)
            }
            return true
        } catch { reportError(error); return false }
    }

    /// Dropping mail on the add field makes one linked to-do per thread; the mail stays where it is.
    func addTodos(fromThreadIDs threadIDs: [String]) async {
        var last: TodoItem?
        for id in threadIDs {
            guard let thread = thread(id: id) else { continue }
            last = await addTodo(title: thread.subject, linking: thread) ?? last
        }
        if let last { plannerReveal = PlannerReveal(target: .todo(last.id)) }
    }

    func unlink(_ link: MailLink) async {
        guard let account, let plannerService else { return }
        let accountID = account.id
        do { try await plannerService.remove(linkID: link.id, accountID: accountID) } catch { reportError(error); return }
        await reloadPlanner(accountID)
        offerUndo("Link removed") { [weak self] in
            guard let self, self.account?.id == accountID, let plannerService = self.plannerService else { return }
            do { try await plannerService.add(link, accountID: accountID) } catch { self.reportError(error) }
            await self.reloadPlanner(accountID)
        }
    }

    /// Link mode: the next event or to-do clicked in a drawer gets this thread. Opens Days if no drawer is showing.
    func startLinking(_ thread: MailThread) {
        linkingThreadID = thread.id
        if drawerPosition == 0 { drawerPosition = 1 }
    }

    func cancelLinking() { linkingThreadID = nil }

    /// Returns true when the click was used to finish link mode.
    @discardableResult
    func completeLinking(to target: LinkTarget) -> Bool {
        guard let threadID = linkingThreadID else { return false }
        linkingThreadID = nil
        Task { await link(threadID: threadID, to: target) }
        return true
    }

    // MARK: Drawers

    func reveal(_ target: LinkTarget) {
        switch target {
        case .event: drawerPosition = 1
        case .todo: drawerPosition = -1
        }
        plannerReveal = PlannerReveal(target: target)
    }

    /// One step toward Days (+1) or To-do (-1), the way a two-finger swipe moves them.
    func slideDrawers(_ step: Int) { drawerPosition = max(-1, min(1, drawerPosition + step)) }

    /// 1 for Days, -1 for To-do: shows that drawer, or hides it when it is already showing.
    func toggleDrawer(_ side: Int) { drawerPosition = drawerPosition == side ? 0 : side }

    func focusTodoField() {
        drawerPosition = -1
        todoFieldRequest = UUID()
    }

    // MARK: Demo

    /// Demo mode starts with a few to-dos and links, so the drawers show what they are for.
    func seedDemoPlannerIfNeeded() async {
        guard isDemoMode, let account, let plannerService else { return }
        do {
            guard try await plannerService.isSeeded(accountID: account.id) == false else { return }
            let now = Date.now
            let invoice = TodoItem(title: "Send the October invoice to the client", createdAt: now)
            let birthday = TodoItem(title: "Book a table for Mom's birthday", createdAt: now.addingTimeInterval(-60))
            let passport = TodoItem(title: "Renew passport before Lisbon", note: "The photo booth at Národní 20 is the quickest.",
                                    createdAt: now.addingTimeInterval(-120))
            let boiler = TodoItem(title: "Pay the boiler technician", createdAt: now.addingTimeInterval(-3_600),
                                  completedAt: now.addingTimeInterval(-1_800))
            for todo in [invoice, birthday, passport, boiler] { try await plannerService.save(todo, accountID: account.id) }
            if let trip = thread(id: "t-trip") {
                try await plannerService.add(makeLink(trip, .todo(passport.id), title: passport.title, start: nil), accountID: account.id)
            }
            if let climb = thread(id: "t-climb"),
               let event = events.filter({ $0.title == "Climbing with Tom" }).min(by: { $0.start < $1.start }) {
                try await plannerService.add(makeLink(climb, .event(event.cacheID), title: event.title, start: event.start), accountID: account.id)
            }
            try await plannerService.markSeeded(accountID: account.id)
            await reloadPlanner(account.id)
        } catch { reportError(error) }
    }
}
#endif
