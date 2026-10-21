import Foundation

struct MailSnapshot: Sendable {
    var account: Account?
    var threads: [MailThread]
    var rules: [SenderRule]
    var bubbles: [BubbleRecord]
    var remoteImageSenders: Set<String>
    var revision: UInt64 = 0
}

extension LocalStore {
    /// All mail collections and their revision are read in one actor turn, so the stamp matches the data.
    func mailSnapshot(accountID: String) throws -> MailSnapshot {
        let threads = try all(MailThread.self, collection: "threads", accountID: accountID)
        let rules = try all(SenderRule.self, collection: "senderRules", accountID: accountID)
        let bubbles = try all(BubbleRecord.self, collection: "bubbles", accountID: accountID)
        let images = try all(ImagePreference.self, collection: "remoteImages", accountID: accountID)
        return MailSnapshot(account: try metadata(Account.self, key: "account", accountID: accountID),
                            threads: threads.sorted { max($0.bubbledAt ?? .distantPast, $0.updatedAt) > max($1.bubbledAt ?? .distantPast, $1.updatedAt) },
                            rules: rules.sorted { $0.key < $1.key }, bubbles: bubbles,
                            remoteImageSenders: Set(images.map(\.sender)), revision: mailRevision(accountID: accountID))
    }

    /// A search page rereads only its own IDs to include any foreground changes made during download.
    func mailSearchPage(threadIDs: [String], nextPageToken: String?, accountID: String) throws -> MailSearchPage {
        let threads = try threadIDs.compactMap { try load(MailThread.self, id: $0, collection: "threads", accountID: accountID) }
        return MailSearchPage(threads: threads.sorted { $0.updatedAt > $1.updatedAt }, nextPageToken: nextPageToken,
                              revision: mailRevision(accountID: accountID))
    }

    private func mailRevision(accountID: String) -> UInt64 {
        ["threads", "senderRules", "bubbles", "remoteImages"].reduce(UInt64(0)) {
            $0 &+ revision(collection: $1, accountID: accountID)
        }
    }
}

/// Main-actor delivery may reorder concurrent reads; accept only the latest cache state per account.
struct MailSnapshotOrder {
    private var revisions: [String: UInt64] = [:]
    mutating func accept(revision: UInt64, accountID: String) -> Bool {
        if let latest = revisions[accountID], revision < latest { return false }
        revisions[accountID] = revision
        return true
    }
}

private struct ImagePreference: Codable, Sendable { var sender: String }

struct MailSearchPage: Sendable {
    var threads: [MailThread]
    var nextPageToken: String?
    var revision: UInt64 = 0
}

struct MailSendReceipt: Codable, Sendable {
    var messageID: String
    var threadID: String
    var warning: String?
}

struct MailDeliveryUncertainError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Gmail may have accepted this email, but its response was interrupted. Check send status before doing anything else. The app will look for the original message without sending another copy."
    }
}

private struct MailSendAttempt: Codable, Sendable {
    var rfcMessageID: String
    var startedAt: Date? = nil
    var receipt: MailSendReceipt?
}

struct MailUndoToken: Identifiable, Sendable {
    var id: UUID
    var message: String
    var expiresAt: Date
    var warning: String? = nil
}

/// Gmail owns labels and message content. SQLite owns sender decisions, timers and the cache.
actor MailService {
    private static let specialLabels = ["HEY/Set Aside", "HEY/Bubble Up", "HEY/Screener", "HEY/Screened Out"]
    private let api: GoogleAPI
    private let store: LocalStore
    private let undoDuration: TimeInterval
    private var labelMaps: [String: [String: String]] = [:] // Gmail ID -> stable label name.
    private var draftMaps: [String: [String: String]] = [:] // Message ID -> Gmail draft ID.
    private struct ActiveSync: Sendable { var id: UUID; var task: Task<MailSnapshot, Error> }
    private var syncTasks: [String: ActiveSync] = [:]
    private var isDraining = false
    private var operationTails: [String: Task<Void, Never>] = [:]
    private var operationCancellers: [UUID: @Sendable () -> Void] = [:]
    private var operationWaiters: [UUID: Task<Void, Never>] = [:]
    private var threadVersions: [String: [String: UInt64]] = [:]
    private var ruleIndexes: [String: (revision: UInt64, index: SenderRuleIndex)] = [:]
    private var undoActions: [UUID: UndoAction] = [:]

    private struct MessageState: Sendable { var id: String; var labels: Set<String> }
    private struct ThreadState: Sendable { var id: String; var messages: [MessageState]; var bubble: BubbleRecord? }
    private struct UndoAction: Sendable {
        var token: MailUndoToken
        var accountID: String
        var threads: [ThreadState]
        var affectedRuleKeys: Set<String> = []
        var previousRules: [SenderRule] = []
    }

    enum MailError: LocalizedError {
        case invalidSender, missingLabel, expiredUndo, invalidDraft, noRecipients
        var errorDescription: String? {
            switch self {
            case .invalidSender: "Enter a valid sender address or domain."
            case .missingLabel: "A mail label is missing. Refresh and try again."
            case .expiredUndo: "That action can no longer be undone."
            case .invalidDraft: "Google did not return a draft identifier."
            case .noRecipients: "Add at least one recipient before sending."
            }
        }
    }

    init(api: GoogleAPI, store: LocalStore, undoDuration: TimeInterval = 5) { self.api = api; self.store = store; self.undoDuration = undoDuration }

    func cached(accountID: String) async throws -> MailSnapshot {
        try await store.mailSnapshot(accountID: accountID)
    }

    func sync(account: Account, progress: (@Sendable (MailSnapshot) async -> Void)? = nil) async throws -> MailSnapshot {
        guard !isDraining else { throw CancellationError() }
        if let syncTask = syncTasks[account.id] { return try await syncTask.task.value }
        let task = Task {
            try await self.performSync(account: account, progress: progress)
        }
        let syncID = UUID()
        syncTasks[account.id] = ActiveSync(id: syncID, task: task)
        defer { if syncTasks[account.id]?.id == syncID { syncTasks.removeValue(forKey: account.id) } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Drain requests before the auth token changes, so an old cache cannot receive new-account data.
    func cancelAllOperations() async {
        isDraining = true
        defer { isDraining = false }
        let syncs = Array(syncTasks.values)
        for sync in syncs { sync.task.cancel() }
        for cancel in operationCancellers.values { cancel() }
        let tails = Array(operationWaiters.values)
        for tail in tails { await tail.value }
        for sync in syncs { _ = try? await sync.task.value }
        undoActions.removeAll()
    }

    func search(query: String, account: Account) async throws -> [MailThread] {
        try await searchPage(query: query, account: account).threads
    }

    /// `includeSpamTrash` searches inside Spam, which Gmail search otherwise leaves out.
    func searchPage(query: String, pageToken: String? = nil, includeSpamTrash: Bool = false, account: Account) async throws -> MailSearchPage {
        try await tracked {
            try await self.serialized(accountID: account.id) { try await self.prepare(account: account) }
            let page = try await self.api.listThreads(query: query, pageToken: pageToken, maxResults: 50, includeSpamTrash: includeSpamTrash)
            let threads = try await self.cacheSources(page.items.map(\.id), account: account, isSync: false)
            return try await self.store.mailSearchPage(threadIDs: threads.map(\.id), nextPageToken: page.nextPageToken, accountID: account.id)
        }
    }

    /// Recheck only the changed result, using its RFC message IDs to bound the server query.
    func matchesSearch(_ thread: MailThread, query: String, includeSpamTrash: Bool = false, account: Account) async throws -> Bool {
        let ids = thread.messages.compactMap(\.rfcMessageID).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }
        guard !ids.isEmpty else { return true }
        let scoped = "(\(query)) {" + ids.map { "rfc822msgid:" + $0 }.joined(separator: " ") + "}"
        return try await tracked {
            try await self.api.listThreads(query: scoped, maxResults: 1, includeSpamTrash: includeSpamTrash).items.contains { $0.id == thread.id }
        }
    }
    func fetchThread(id: String, account: Account) async throws -> MailThread {
        try await serialized(accountID: account.id) { try await self.fetchThreadImpl(id: id, account: account) }
    }
    func moveToSpam(threadID: String, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.moveToSpamImpl(threadID: threadID, account: account) }
    }
    func notSpam(threadID: String, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.notSpamImpl(threadID: threadID, account: account) }
    }
    func archive(threadID: String, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.archiveImpl(threadID: threadID, account: account) }
    }
    func trash(threadID: String, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.trashImpl(threadID: threadID, account: account) }
    }
    func markUnread(threadID: String, unread: Bool, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.markUnreadImpl(threadID: threadID, unread: unread, account: account) }
    }
    func toggleSetAside(threadID: String, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.toggleSetAsideImpl(threadID: threadID, account: account) }
    }
    func bubbleUp(threadID: String, date: Date, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.bubbleUpImpl(threadID: threadID, date: date, account: account) }
    }
    func processDueBubbles(account: Account, now: Date = .now) async throws -> [MailThread] {
        try await serialized(accountID: account.id) { try await self.processDueBubblesImpl(account: account, now: now) }
    }
    func decide(sender: String, decision: ScreeningDecision, domain: Bool = false, account: Account) async throws -> MailUndoToken {
        try await serialized(accountID: account.id) { try await self.decideImpl(sender: sender, decision: decision, domain: domain, account: account) }
    }
    func undo(tokenID: UUID, account: Account) async throws {
        guard let action = undoActions[tokenID], action.accountID == account.id, action.token.expiresAt > .now else { throw MailError.expiredUndo }
        // Reserve a timely click before it waits in the operation queue or cleanup runs.
        undoActions.removeValue(forKey: tokenID)
        do { try await serialized(accountID: account.id) { try await self.undoImpl(action: action, account: account) } }
        catch { undoActions[tokenID] = action; throw error }
    }
    func setRemoteImages(sender: String, allowed: Bool, account: Account) async throws {
        try await serialized(accountID: account.id) { try await self.setRemoteImagesImpl(sender: sender, allowed: allowed, account: account) }
    }
    func saveDraft(_ outgoing: OutgoingMessage, account: Account) async throws -> OutgoingMessage {
        try await serialized(accountID: account.id) { try await self.saveDraftImpl(outgoing, account: account) }
    }
    /// Verified Gmail "Send mail as" addresses, the account's own first. Cached so the composer works offline.
    func sendAddresses(account: Account) async throws -> [String] {
        let entries = try await tracked { try await self.api.sendAs() }
        var seen: Set<String> = [account.email.lowercased()]
        let aliases = entries.filter { $0.isPrimary != true && $0.verificationStatus == "accepted" }.map(\.sendAsEmail)
        let addresses = [account.email] + aliases.filter { seen.insert($0.lowercased()).inserted }
        try await store.setMetadata(addresses, key: "sendAs", accountID: account.id)
        return addresses
    }
    func cachedSendAddresses(accountID: String) async throws -> [String] {
        try await store.metadata([String].self, key: "sendAs", accountID: accountID) ?? []
    }
    @discardableResult
    func send(_ outgoing: OutgoingMessage, account: Account) async throws -> MailSendReceipt {
        try await serialized(accountID: account.id) { try await self.sendImpl(outgoing, account: account) }
    }

    private func serialized<T: Sendable>(accountID: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !isDraining else { throw CancellationError() }
        let previous = operationTails[accountID]
        let task = Task {
            if let previous { await previous.value }
            try Task.checkCancellation()
            return try await operation()
        }
        let operationID = UUID()
        operationCancellers[operationID] = { task.cancel() }
        defer { operationCancellers.removeValue(forKey: operationID); operationWaiters.removeValue(forKey: operationID) }
        operationWaiters[operationID] = Task { _ = try? await task.value }
        operationTails[accountID] = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Reads outside the write queue still participate in account-switch cancellation and draining.
    private func tracked<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !isDraining else { throw CancellationError() }
        let id = UUID(), task = Task { try await operation() }
        operationCancellers[id] = { task.cancel() }
        operationWaiters[id] = Task { _ = try? await task.value }
        defer { operationCancellers.removeValue(forKey: id); operationWaiters.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performSync(account: Account, progress: (@Sendable (MailSnapshot) async -> Void)?) async throws -> MailSnapshot {
        try await serialized(accountID: account.id) {
            try await self.store.setMetadata(account, key: "account", accountID: account.id)
            try await self.ensureLabels(accountID: account.id)
        }
        try await serialized(accountID: account.id) { try await self.refreshDraftMap(accountID: account.id) }
        let cursor = try await store.metadata(String.self, key: "mailHistoryID", accountID: account.id)
        if let cursor {
            do { try await incrementalSync(account: account, cursor: cursor) }
            catch let error as GoogleAPIError where error.statusCode == 404 {
                // History cursors expire. Rebuild the cache; app metadata and timers survive.
                try await fullSync(account: account)
            }
        } else { try await fullSync(account: account) }
        try await serialized(accountID: account.id) { try await self.seedApprovedInboxSenders(account: account) }
        if let progress { await progress(try await cached(accountID: account.id)) }
        try await seedApprovedRecipients(account: account)
        try await reconcileScreener(account: account)
        undoActions = undoActions.filter { $0.value.token.expiresAt > .now }
        return try await cached(accountID: account.id)
    }

    private func fullSync(account: Account) async throws {
        // Anchor before enumeration so changes made during this sync appear in the next history poll.
        let versions = threadVersions[account.id] ?? [:]
        let initial = try await store.all(MailThread.self, collection: "threads", accountID: account.id)
        let anchor = try await api.profile().historyId
        var ids = Set(try await threadIDs(query: "newer_than:90d"))
        for label in ["INBOX", "DRAFT"] + Self.specialLabels {
            ids.formUnion(try await threadIDs(labelIDs: [try labelID(label, accountID: account.id)]))
        }
        // Gmail deletes spam after 30 days, so the whole folder stays small enough to cache.
        ids.formUnion(try await threadIDs(labelIDs: ["SPAM"], includeSpamTrash: true))
        ids.formUnion(try await store.all(MailLink.self, collection: PlannerService.linkCollection, accountID: account.id).map(\.threadID))
        let sources = try await cacheSources(Array(ids), account: account, isSync: true)
        let present = Set(sources.map(\.id))
        try await serialized(accountID: account.id) {
            let linkedIDs = Set(try await self.store.all(MailLink.self, collection: PlannerService.linkCollection, accountID: account.id).map(\.threadID))
            for old in initial where !present.contains(old.id) {
                // A foreground action/search may have made an old thread relevant during enumeration.
                guard !linkedIDs.contains(old.id) else { continue }
                guard await self.threadVersion(old.id, accountID: account.id) == versions[old.id] else { continue }
                try await self.store.remove(id: old.id, collection: "threads", accountID: account.id)
            }
            try await self.store.setMetadata(anchor, key: "mailHistoryID", accountID: account.id)
        }
    }

    private func incrementalSync(account: Account, cursor: String) async throws {
        var pageToken: String?, ids = Set<String>(), nextCursor = cursor
        repeat {
            try Task.checkCancellation()
            let page = try await api.history(startHistoryID: cursor, pageToken: pageToken)
            for history in page.history ?? [] { ids.formUnion(history.changedThreadIDs) }
            nextCursor = page.historyId
            pageToken = page.nextPageToken
        } while pageToken != nil
        _ = try await cacheSources(Array(ids), account: account, isSync: true)
        try await store.setMetadata(nextCursor, key: "mailHistoryID", accountID: account.id)
    }

    private func seedApprovedRecipients(account: Account) async throws {
        if try await store.metadata(Bool.self, key: "sentRecipientsSeeded", accountID: account.id) == true { return }
        // Page through the entire Sent mailbox, not just the recent-mail cache window.
        var pageToken = try await store.metadata(String.self, key: "sentRecipientsPage", accountID: account.id)
        var restarted = false
        while true {
            let page: GooglePage<GoogleMailMessage>
            do { page = try await api.listMessages(labelIDs: ["SENT"], pageToken: pageToken, maxResults: 500) }
            catch let error as GoogleAPIError where error.statusCode == 400 && pageToken != nil && !restarted {
                // Gmail pagination tokens are temporary; restarting is safe because approvals are idempotent.
                try await store.removeMetadata(key: "sentRecipientsPage", accountID: account.id)
                pageToken = nil; restarted = true
                continue
            }
            let api = self.api
            for offset in stride(from: 0, to: page.items.count, by: 10) {
                let batch = Array(page.items[offset..<min(offset + 10, page.items.count)])
                let messages = try await withThrowingTaskGroup(of: GoogleMailMessage?.self, returning: [GoogleMailMessage].self) { group in
                    for reference in batch {
                        group.addTask {
                            do { return try await api.message(id: reference.id, format: "metadata") }
                            catch let error as GoogleAPIError where error.statusCode == 404 { return nil }
                        }
                    }
                    var messages: [GoogleMailMessage] = []
                    for try await message in group { if let message { messages.append(message) } }
                    return messages
                }
                try await serialized(accountID: account.id) {
                    let recipients = messages.flatMap { message in
                        MailMapping.addresses(message.header("To")) + MailMapping.addresses(message.header("Cc")) + MailMapping.addresses(message.header("Bcc"))
                    }
                    try await self.approveUnknown(recipients.map(\.email), account: account)
                }
            }
            pageToken = page.nextPageToken
            if let pageToken { try await store.setMetadata(pageToken, key: "sentRecipientsPage", accountID: account.id) }
            else { break }
        }
        // Incomplete seeds safely resume; existing user decisions are never overwritten.
        try await store.setMetadata(true, key: "sentRecipientsSeeded", accountID: account.id)
        try await store.removeMetadata(key: "sentRecipientsPage", accountID: account.id)
    }

    /// The Screener applies to senders who appear after setup. Mail already in the Inbox at
    /// first sync stays where it is instead of being moved out of Gmail's Inbox en masse.
    private func seedApprovedInboxSenders(account: Account) async throws {
        if try await store.metadata(Bool.self, key: "inboxSendersSeeded", accountID: account.id) == true { return }
        let threads = try await store.all(MailThread.self, collection: "threads", accountID: account.id)
        let senders = threads.filter { $0.labels.contains("INBOX") }.flatMap(\.messages)
            .filter { !$0.labels.contains("SENT") && !$0.labels.contains("DRAFT") }.map { $0.from.email }
        try await approveUnknown(senders, account: account)
        try await store.setMetadata(true, key: "inboxSendersSeeded", accountID: account.id)
    }

    private func ensureLabels(accountID: String) async throws {
        var labels = try await api.labels()
        for name in Self.specialLabels where !labels.contains(where: { $0.name == name }) {
            do { labels.append(try await api.createLabel(name: name)) }
            catch let error as GoogleAPIError where error.statusCode == 409 { labels = try await api.labels() }
        }
        let map = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        labelMaps[accountID] = map
        try await store.setMetadata(map, key: "mailLabels", accountID: accountID)
    }

    private func refreshDraftMap(accountID: String) async throws {
        var pageToken: String?, map: [String: String] = [:]
        repeat {
            let page = try await api.drafts(pageToken: pageToken)
            for draft in page.items { if let message = draft.message { map[message.id] = draft.id } }
            pageToken = page.nextPageToken
        } while pageToken != nil
        draftMaps[accountID] = map
        try await store.setMetadata(map, key: "draftIDs", accountID: accountID)
    }

    private nonisolated func screeningChange(_ thread: MailThread, rules: SenderRuleIndex, account: Account) -> (adding: Set<String>, removing: Set<String>)? {
        guard !thread.labels.contains("TRASH"), !thread.isSpam,
              let incoming = thread.messages.reversed().first(where: { !$0.labels.contains("SENT") && !$0.labels.contains("DRAFT") && !$0.labels.contains("SPAM") && $0.from.email != account.email.lowercased() }) else { return nil }
        let decision = rules.rule(for: incoming.from.email)?.decision
        if decision == .blocked {
            if thread.labels.contains("INBOX") || thread.labels.contains("HEY/Screener") || !thread.labels.contains("HEY/Screened Out") {
                return (["HEY/Screened Out"], ["INBOX", "HEY/Screener"])
            }
        } else if decision == .approved && (thread.labels.contains("HEY/Screener") || thread.labels.contains("HEY/Screened Out")) {
            return (["INBOX"], ["HEY/Screener", "HEY/Screened Out"])
        } else if decision == nil && thread.labels.contains("INBOX") {
            return (["HEY/Screener"], ["INBOX"])
        }
        return nil
    }

    private func reconcileScreener(account: Account) async throws {
        let threads = try await store.all(MailThread.self, collection: "threads", accountID: account.id)
        let rules = try await currentRuleIndex(accountID: account.id)
        for reference in threads where screeningChange(reference, rules: rules, account: account) != nil {
            try await serialized(accountID: account.id) {
                guard let thread = try await self.store.load(MailThread.self, id: reference.id, collection: "threads", accountID: account.id) else { return }
                let currentRules = try await self.currentRuleIndex(accountID: account.id)
                if let change = self.screeningChange(thread, rules: currentRules, account: account) {
                    _ = try await self.changeLabels(threadID: thread.id, adding: change.adding, removing: change.removing, account: account)
                }
            }
        }
    }

    private func fetchThreadImpl(id: String, account: Account) async throws -> MailThread {
        try await prepare(account: account)
        let thread = try await mapped(try await hydrate(try await api.thread(id: id)), accountID: account.id)
        try await save(thread)
        return thread
    }

    private func archiveImpl(threadID: String, account: Account) async throws -> MailUndoToken {
        try await move(threadID: threadID, adding: [], removing: ["INBOX"], message: "Archived", account: account)
    }

    private func moveToSpamImpl(threadID: String, account: Account) async throws -> MailUndoToken {
        try await prepare(account: account)
        let state = try await capture(threadID: threadID, account: account)
        _ = try await changeLabels(threadID: threadID, adding: ["SPAM"], removing: ["INBOX"], account: account)
        try await store.remove(id: threadID, collection: "bubbles", accountID: account.id)
        _ = try await refresh(threadID: threadID, accountID: account.id)
        return register(message: "Moved to Spam", threads: [state], accountID: account.id)
    }

    /// Rescues the conversation into the Imbox and approves its senders, unless they already have a decision.
    /// Undo restores the labels and removes only the approvals this added.
    private func notSpamImpl(threadID: String, account: Account) async throws -> MailUndoToken {
        try await prepare(account: account)
        let state = try await capture(threadID: threadID, account: account)
        let thread = try await changeLabels(threadID: threadID, adding: ["INBOX"], removing: ["SPAM"], account: account)
        let rules = try await currentRuleIndex(accountID: account.id)
        let senders = Set(thread.messages.filter { !$0.labels.contains("SENT") && !$0.labels.contains("DRAFT") }
            .map { $0.from.email.lowercased() }
            .filter { !$0.isEmpty && $0 != account.email.lowercased() && rules.rule(for: $0) == nil })
        try await approveUnknown(Array(senders), account: account)
        let token = register(message: "Not spam: moved to Imbox", threads: [state], accountID: account.id)
        undoActions[token.id]?.affectedRuleKeys = senders
        return token
    }

    private func trashImpl(threadID: String, account: Account) async throws -> MailUndoToken {
        try await prepare(account: account)
        let state = try await capture(threadID: threadID, account: account)
        _ = try await api.trashThread(id: threadID)
        try await store.remove(id: threadID, collection: "bubbles", accountID: account.id)
        _ = try await refresh(threadID: threadID, accountID: account.id)
        return register(message: "Moved to Trash", threads: [state], accountID: account.id)
    }

    private func markUnreadImpl(threadID: String, unread: Bool, account: Account) async throws -> MailUndoToken {
        try await move(threadID: threadID, adding: unread ? ["UNREAD"] : [], removing: unread ? [] : ["UNREAD"], message: unread ? "Marked unread" : "Marked read", account: account)
    }

    private func toggleSetAsideImpl(threadID: String, account: Account) async throws -> MailUndoToken {
        try await prepare(account: account)
        let state = try await capture(threadID: threadID, account: account)
        let isSetAside = state.messages.contains { $0.labels.contains("HEY/Set Aside") }
        _ = try await changeLabels(threadID: threadID, adding: isSetAside ? ["INBOX"] : ["HEY/Set Aside"],
                                   removing: isSetAside ? ["HEY/Set Aside"] : ["INBOX", "HEY/Bubble Up"], account: account)
        if !isSetAside {
            try await store.remove(id: threadID, collection: "bubbles", accountID: account.id)
            _ = try await refresh(threadID: threadID, accountID: account.id)
        }
        return register(message: isSetAside ? "Returned to Imbox" : "Set aside", threads: [state], accountID: account.id)
    }

    private func bubbleUpImpl(threadID: String, date: Date, account: Account) async throws -> MailUndoToken {
        try await prepare(account: account)
        let state = try await capture(threadID: threadID, account: account)
        let bubble = BubbleRecord(accountID: account.id, threadID: threadID, dueAt: date)
        try await store.save(bubble, id: threadID, collection: "bubbles", accountID: account.id, sortDate: date)
        do {
            _ = try await api.modifyThread(id: threadID,
                addLabelIDs: [try labelID("HEY/Bubble Up", accountID: account.id)],
                removeLabelIDs: ["INBOX", try labelID("HEY/Set Aside", accountID: account.id)])
        } catch {
            try? await restoreBubble(state.bubble, threadID: threadID, accountID: account.id)
            throw error
        }
        // Gmail has committed. Keep the timer and reflect the accepted move even if the next read fails.
        var warning: String?
        do {
            if var thread = try await store.load(MailThread.self, id: threadID, collection: "threads", accountID: account.id) {
                for index in thread.messages.indices {
                    thread.messages[index].labels.insert("HEY/Bubble Up")
                    thread.messages[index].labels.subtract(["INBOX", "HEY/Set Aside"])
                }
                thread.labels = thread.messages.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
                thread.bubbleUpAt = date
                try await save(thread)
            }
            _ = try await refresh(threadID: threadID, accountID: account.id)
        } catch {
            warning = "Bubble Up scheduled. The mail view could not refresh: " + error.localizedDescription
        }
        return register(message: "Will bubble up later", threads: [state], accountID: account.id, warning: warning)
    }

    /// Retain the durable due record until Gmail accepts the return-to-Inbox mutation.
    /// surfacedAt makes launch processing idempotent and keeps the subtle marker across restarts.
    private func processDueBubblesImpl(account: Account, now: Date = .now) async throws -> [MailThread] {
        try await ensureCachedLabels(accountID: account.id)
        let bubbles = try await store.all(BubbleRecord.self, collection: "bubbles", accountID: account.id)
        var surfaced: [MailThread] = []
        for var bubble in bubbles where bubble.surfacedAt == nil && bubble.dueAt <= now {
            do {
                let current = try await refresh(threadID: bubble.threadID, accountID: account.id)
                guard !current.labels.contains("TRASH"), !current.isSpam, current.labels.contains("HEY/Bubble Up") else {
                    try await store.remove(id: bubble.threadID, collection: "bubbles", accountID: account.id)
                    _ = try await refresh(threadID: bubble.threadID, accountID: account.id)
                    continue
                }
                _ = try await api.modifyThread(id: bubble.threadID, addLabelIDs: ["INBOX"], removeLabelIDs: [try labelID("HEY/Bubble Up", accountID: account.id)])
                bubble.surfacedAt = now
                try await store.save(bubble, id: bubble.threadID, collection: "bubbles", accountID: account.id, sortDate: now)
                var thread = try await refresh(threadID: bubble.threadID, accountID: account.id)
                thread.bubbledAt = now; thread.bubbleUpAt = nil
                try await save(thread); surfaced.append(thread)
            } catch let error as GoogleAPIError where error.statusCode == 404 {
                try await store.remove(id: bubble.threadID, collection: "bubbles", accountID: account.id)
                try await store.remove(id: bubble.threadID, collection: "threads", accountID: account.id)
            }
        }
        return surfaced
    }

    private func decideImpl(sender: String, decision: ScreeningDecision, domain: Bool = false, account: Account) async throws -> MailUndoToken {
        try await prepare(account: account)
        let key = try normalizedRuleKey(sender: sender, domain: domain)
        let oldRules = try await store.all(SenderRule.self, collection: "senderRules", accountID: account.id)
        // A domain decision replaces its existing per-address decisions. Later address decisions
        // can make explicit exceptions again; undo restores each former decision and filter.
        let addressDomain = key.lastIndex(of: "@").map { String(key[$0...]) }
        let domainDependency = domain ? nil : oldRules.first { $0.key == addressDomain && $0.decision == .blocked }
        var affected = Set(oldRules.filter { $0.key == key || (domain && !$0.isDomain && $0.key.hasSuffix(key)) }.map(\.key)).union([key])
        if let domainDependency { affected.insert(domainDependency.key) }
        let previous = oldRules.filter { affected.contains($0.key) }
        let ids = try await threadIDs(query: "from:(\(key))")
        var states: [ThreadState] = []
        for id in ids { states.append(try await capture(threadID: id, account: account)) }
        var target = SenderRule(accountID: account.id, key: key, decision: decision,
                                allowsRemoteImages: oldRules.first(where: { $0.key == key })?.allowsRemoteImages ?? false)
        if let existing = oldRules.first(where: { $0.key == key }), existing.decision == decision { target.filterID = existing.filterID }
        let targetRules = [target] + (domainDependency.map { [$0] } ?? [])
        do {
            try await replaceRules(keys: affected, target: targetRules, account: account)
            for state in states {
                _ = try await changeLabels(threadID: state.id,
                    adding: decision == .approved ? ["INBOX"] : ["HEY/Screened Out"],
                    removing: decision == .approved ? ["HEY/Screener", "HEY/Screened Out"] : ["INBOX", "HEY/Screener"], account: account)
            }
        } catch {
            try? await replaceRules(keys: affected, target: previous, account: account)
            for state in states { try? await restoreThread(state, account: account) }
            throw error
        }
        let token = register(message: decision == .approved ? "Sender approved" : "Sender screened out", threads: states, accountID: account.id)
        undoActions[token.id]?.affectedRuleKeys = affected
        undoActions[token.id]?.previousRules = previous
        return token
    }

    private func undoImpl(action: UndoAction, account: Account) async throws {
        try await prepare(account: account)
        if !action.affectedRuleKeys.isEmpty {
            try await replaceRules(keys: action.affectedRuleKeys, target: action.previousRules, account: account)
        }
        for state in action.threads { try await restoreThread(state, account: account) }
    }

    private func setRemoteImagesImpl(sender: String, allowed: Bool, account: Account) async throws {
        let key = try normalizedRuleKey(sender: sender, domain: false)
        if allowed { try await store.save(ImagePreference(sender: key), id: key, collection: "remoteImages", accountID: account.id) }
        else { try await store.remove(id: key, collection: "remoteImages", accountID: account.id) }
        if var rule = try await store.load(SenderRule.self, id: key, collection: "senderRules", accountID: account.id) {
            rule.allowsRemoteImages = allowed
            try await store.save(rule, id: key, collection: "senderRules", accountID: account.id)
        }
    }

    private func saveDraftImpl(_ outgoing: OutgoingMessage, account: Account) async throws -> OutgoingMessage {
        try await prepare(account: account)
        if try await sendAttempt(outgoing, account: account) != nil { throw MailDeliveryUncertainError() }
        let raw = try MIMEComposer.compose(outgoing, from: outgoing.from ?? account.email)
        let draft: GoogleDraft
        if let id = outgoing.draftID { draft = try await api.updateDraft(id: id, raw: raw, threadID: outgoing.threadID) }
        else { draft = try await api.createDraft(raw: raw, threadID: outgoing.threadID) }
        var saved = outgoing; saved.draftID = draft.id
        if let message = draft.message {
            draftMaps[account.id, default: [:]][message.id] = draft.id
            do {
                try await store.setMetadata(draftMaps[account.id] ?? [:], key: "draftIDs", accountID: account.id)
                _ = try await refresh(threadID: message.threadId, accountID: account.id)
            } catch {
                // Google has saved the draft. Return its ID even when refreshing the cache fails,
                // otherwise the next autosave would create a duplicate instead of updating it.
            }
        }
        return saved
    }

    private func sendImpl(_ outgoing: OutgoingMessage, account: Account) async throws -> MailSendReceipt {
        try await prepare(account: account)
        if let attempt = try await sendAttempt(outgoing, account: account) {
            if let receipt = attempt.receipt { return receipt }
            return try await reconcileSend(attempt, outgoing: outgoing, account: account)
        }
        guard !outgoing.to.isEmpty || !outgoing.cc.isEmpty || !outgoing.bcc.isEmpty else { throw MailError.noRecipients }
        var outgoing = outgoing
        if outgoing.rfcMessageID == nil { outgoing.rfcMessageID = "<\(UUID().uuidString.lowercased())@emailcalendar.local>" }
        let raw = try MIMEComposer.compose(outgoing, from: outgoing.from ?? account.email)
        // Draft updates cannot deliver mail. Finish this step before recording an attempt.
        if let draftID = outgoing.draftID { _ = try await api.updateDraft(id: draftID, raw: raw, threadID: outgoing.threadID) }
        let attempt = MailSendAttempt(rfcMessageID: outgoing.rfcMessageID!, startedAt: .now, receipt: nil)
        try await store.setMetadata(attempt, key: sendKey(outgoing), accountID: account.id)
        let sent: GoogleMailMessage
        do {
            if let draftID = outgoing.draftID { sent = try await api.sendDraft(id: draftID) }
            else { sent = try await api.sendMessage(raw: raw, threadID: outgoing.threadID) }
        } catch {
            let status = (error as? GoogleAPIError)?.statusCode
            let neverConnected = (error as? URLError).map {
                [URLError.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains($0.code)
            } ?? false
            if neverConnected || (status.map { (400..<500).contains($0) && $0 != 408 } ?? false) {
                // An explicit rejection is safe to correct and retry.
                try await store.removeMetadata(key: sendKey(outgoing), accountID: account.id)
                throw error
            }
            return try await reconcileSend(attempt, outgoing: outgoing, account: account)
        }
        return await finishSend(sent, outgoing: outgoing, account: account)
    }

    private func sendKey(_ outgoing: OutgoingMessage) -> String {
        "mail.sendAttempt." + (outgoing.draftID ?? outgoing.rfcMessageID ?? "legacy")
    }

    private func sendAttempt(_ outgoing: OutgoingMessage, account: Account) async throws -> MailSendAttempt? {
        try await store.metadata(MailSendAttempt.self, key: sendKey(outgoing), accountID: account.id)
    }

    private func reconcileSend(_ attempt: MailSendAttempt, outgoing: OutgoingMessage, account: Account) async throws -> MailSendReceipt {
        do {
            let matches = try await api.listMessages(query: "in:sent rfc822msgid:\(attempt.rfcMessageID)", maxResults: 10)
            for match in matches.items {
                let message = try await api.message(id: match.id)
                if message.labelIds?.contains("SENT") == true,
                   message.header("Message-ID") == attempt.rfcMessageID {
                    return await finishSend(message, outgoing: outgoing, account: account)
                }
            }
            // Gmail can replace Message-ID when it sends a draft. Our private
            // delivery marker survives that rewrite, so inspect recent Sent mail
            // rather than ever guessing from a matching subject or resending.
            let after = attempt.startedAt.map { " after:\(Int($0.timeIntervalSince1970) - 300)" } ?? ""
            var pageToken: String?
            for _ in 0..<10 {
                let page = try await api.listMessages(query: "in:sent" + after, pageToken: pageToken, maxResults: 100)
                for match in page.items {
                    let message = try await api.message(id: match.id, format: "metadata")
                    if message.labelIds?.contains("SENT") == true,
                       message.header("X-EmailCalendar-Delivery-ID") == attempt.rfcMessageID {
                        return await finishSend(message, outgoing: outgoing, account: account)
                    }
                }
                guard let next = page.nextPageToken else { break }
                pageToken = next
            }
        } catch { /* A failed lookup is not evidence that sending failed. */ }
        throw MailDeliveryUncertainError()
    }

    private func finishSend(_ sent: GoogleMailMessage, outgoing: OutgoingMessage, account: Account) async -> MailSendReceipt {
        let receipt = MailSendReceipt(messageID: sent.id, threadID: sent.threadId, warning: nil)
        do {
            try await store.setMetadata(MailSendAttempt(rfcMessageID: outgoing.rfcMessageID ?? "", receipt: receipt),
                                        key: sendKey(outgoing), accountID: account.id)
            // New correspondents become approved immediately, as the first-run Sent seed does.
            let recipients = MailMapping.addresses((outgoing.to + outgoing.cc + outgoing.bcc).joined(separator: ","))
            try await approveUnknown(recipients.map(\.email), account: account)
            try await refreshDraftMap(accountID: account.id)
            _ = try await refresh(threadID: sent.threadId, accountID: account.id)
            return receipt
        } catch {
            return MailSendReceipt(messageID: sent.id, threadID: sent.threadId,
                warning: "Email sent. The local mail cache could not refresh: " + error.localizedDescription)
        }
    }

    func attachment(messageID: String, attachmentID: String, account: Account) async throws -> Data {
        try await serialized(accountID: account.id) {
            try await self.api.attachment(messageID: messageID, attachmentID: attachmentID)
        }
    }

    private func move(threadID: String, adding: Set<String>, removing: Set<String>, message: String, account: Account) async throws -> MailUndoToken {
        try await prepare(account: account)
        let state = try await capture(threadID: threadID, account: account)
        _ = try await changeLabels(threadID: threadID, adding: adding, removing: removing, account: account)
        return register(message: message, threads: [state], accountID: account.id)
    }

    private func register(message: String, threads: [ThreadState], accountID: String, warning: String? = nil) -> MailUndoToken {
        let token = MailUndoToken(id: UUID(), message: message, expiresAt: .now.addingTimeInterval(undoDuration), warning: warning)
        undoActions[token.id] = UndoAction(token: token, accountID: accountID, threads: threads)
        return token
    }

    private func capture(threadID: String, account: Account) async throws -> ThreadState {
        let thread = try await refresh(threadID: threadID, accountID: account.id)
        return ThreadState(id: threadID, messages: thread.messages.map { MessageState(id: $0.id, labels: $0.labels) },
                           bubble: try await store.load(BubbleRecord.self, id: threadID, collection: "bubbles", accountID: account.id))
    }

    private func restoreThread(_ state: ThreadState, account: Account) async throws {
        // Restore labels per message, preserving mixed read/unread and Inbox/Sent states.
        let current = try await refresh(threadID: state.id, accountID: account.id)
        for original in state.messages {
            guard let message = current.messages.first(where: { $0.id == original.id }) else { continue }
            let additions = original.labels.subtracting(message.labels)
            let removals = message.labels.subtracting(original.labels)
            if !additions.isEmpty || !removals.isEmpty {
                _ = try await api.modifyMessage(id: original.id,
                    addLabelIDs: try additions.map { try labelID($0, accountID: account.id) },
                    removeLabelIDs: try removals.map { try labelID($0, accountID: account.id) })
            }
        }
        try await restoreBubble(state.bubble, threadID: state.id, accountID: account.id)
        _ = try await refresh(threadID: state.id, accountID: account.id)
    }

    private func restoreBubble(_ bubble: BubbleRecord?, threadID: String, accountID: String) async throws {
        if let bubble { try await store.save(bubble, id: threadID, collection: "bubbles", accountID: accountID, sortDate: bubble.surfacedAt ?? bubble.dueAt) }
        else { try await store.remove(id: threadID, collection: "bubbles", accountID: accountID) }
    }

    private func replaceRules(keys: Set<String>, target: [SenderRule], account: Account) async throws {
        let currentRules = try await store.all(SenderRule.self, collection: "senderRules", accountID: account.id)
        let prospectiveRules = currentRules.filter { !keys.contains($0.key) } + target
        for key in keys.sorted() {
            let current = try await store.load(SenderRule.self, id: key, collection: "senderRules", accountID: account.id)
            if let filterID = current?.filterID {
                do { try await api.deleteFilter(id: filterID) }
                catch let error as GoogleAPIError where error.statusCode == 404 { /* Already removed in Gmail. */ }
            }
            if var newRule = target.first(where: { $0.key == key }) {
                newRule.filterID = nil
                if newRule.decision == .blocked {
                    var criteria = GoogleFilter.Criteria(from: key)
                    if newRule.isDomain {
                        let exceptions = prospectiveRules.filter { !$0.isDomain && $0.key.hasSuffix(key) && $0.decision == .approved }.map(\.key).sorted()
                        if !exceptions.isEmpty { criteria.negatedQuery = "{" + exceptions.map { "from:" + $0 }.joined(separator: " ") + "}" }
                    }
                    let filter = try await api.createFilter(GoogleFilter(criteria: criteria,
                        action: .init(addLabelIds: [try labelID("HEY/Screened Out", accountID: account.id)], removeLabelIds: ["INBOX"])))
                    guard let id = filter.id else { throw GoogleAPIError.invalidResponse }
                    newRule.filterID = id
                }
                do { try await store.save(newRule, id: key, collection: "senderRules", accountID: account.id) }
                catch {
                    if let filterID = newRule.filterID { try? await api.deleteFilter(id: filterID) }
                    throw error
                }
            } else { try await store.remove(id: key, collection: "senderRules", accountID: account.id) }
        }
    }

    private func changeLabels(threadID: String, adding: Set<String>, removing: Set<String>, account: Account) async throws -> MailThread {
        _ = try await api.modifyThread(id: threadID,
            addLabelIDs: try adding.map { try labelID($0, accountID: account.id) },
            removeLabelIDs: try removing.map { try labelID($0, accountID: account.id) })
        return try await refresh(threadID: threadID, accountID: account.id)
    }

    private func prepare(account: Account) async throws {
        try await ensureCachedLabels(accountID: account.id)
        if draftMaps[account.id] == nil { draftMaps[account.id] = try await store.metadata([String: String].self, key: "draftIDs", accountID: account.id) ?? [:] }
    }

    private func ensureCachedLabels(accountID: String) async throws {
        if labelMaps[accountID] == nil {
            labelMaps[accountID] = try await store.metadata([String: String].self, key: "mailLabels", accountID: accountID)
            if labelMaps[accountID] == nil { try await ensureLabels(accountID: accountID) }
        }
    }

    private func labelID(_ name: String, accountID: String) throws -> String {
        if Self.specialLabels.contains(name) {
            guard let id = labelMaps[accountID]?.first(where: { $0.value == name })?.key else { throw MailError.missingLabel }
            return id
        }
        return labelMaps[accountID]?.first(where: { $0.value == name })?.key ?? name
    }

    private func mapped(_ source: GoogleMailThread, accountID: String) async throws -> MailThread {
        let previous = try await store.load(MailThread.self, id: source.id, collection: "threads", accountID: accountID)
        let bubble = try await store.load(BubbleRecord.self, id: source.id, collection: "bubbles", accountID: accountID)
        return MailMapping.thread(source, accountID: accountID, labels: labelMaps[accountID] ?? [:], drafts: draftMaps[accountID] ?? [:], previous: previous, bubble: bubble)
    }

    @discardableResult
    private func refresh(threadID: String, accountID: String) async throws -> MailThread {
        let thread = try await mapped(try await api.thread(id: threadID), accountID: accountID)
        try await save(thread)
        return thread
    }

    private func threadVersion(_ id: String, accountID: String) -> UInt64? { threadVersions[accountID]?[id] }

    private func save(_ thread: MailThread, background: Bool = false) async throws {
        if !background { threadVersions[thread.accountID, default: [:]][thread.id, default: 0] &+= 1 }
        try await store.save(thread, id: thread.id, collection: "threads", accountID: thread.accountID, sortDate: max(thread.bubbledAt ?? .distantPast, thread.updatedAt))
    }

    private func currentRuleIndex(accountID: String) async throws -> SenderRuleIndex {
        let cached = ruleIndexes[accountID]
        if let snapshot = try await store.snapshot(SenderRule.self, collection: "senderRules", accountID: accountID,
                                                  ifChangedSince: cached?.revision) {
            let index = SenderRuleIndex(snapshot.values)
            ruleIndexes[accountID] = (snapshot.revision, index)
            return index
        }
        return cached?.index ?? SenderRuleIndex()
    }

    /// Called under the account's write queue, so user decisions win over historical auto-approval.
    private func approveUnknown(_ addresses: [String], account: Account) async throws {
        var index = try await currentRuleIndex(accountID: account.id)
        var additions: [LocalStore.Record<SenderRule>] = []
        for address in addresses {
            let address = address.lowercased()
            guard !address.isEmpty, address != account.email.lowercased(), index.rule(for: address) == nil else { continue }
            let approved = SenderRule(accountID: account.id, key: address, decision: .approved)
            additions.append(.init(id: address, value: approved))
            index.insert(approved)
        }
        guard !additions.isEmpty else { return }
        let revision = try await store.save(additions, collection: "senderRules", accountID: account.id)
        ruleIndexes[account.id] = (revision, index)
    }

    private func normalizedRuleKey(sender: String, domain: Bool) throws -> String {
        let value = sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.contains("\n"), !value.contains("\r"), !value.contains(" ") else { throw MailError.invalidSender }
        if domain {
            let host = value.split(separator: "@").last.map(String.init) ?? ""
            guard host.contains("."), !host.contains(":"), !host.contains("/") else { throw MailError.invalidSender }
            return "@" + host
        }
        guard let address = MailMapping.addresses(value).first, address.email.contains("@"), !address.email.hasPrefix("@") else { throw MailError.invalidSender }
        return address.email
    }

    private func threadIDs(query: String? = nil, labelIDs: [String] = [], includeSpamTrash: Bool = false) async throws -> [String] {
        var pageToken: String?, ids = Set<String>()
        repeat {
            let page = try await api.listThreads(query: query, labelIDs: labelIDs, pageToken: pageToken, maxResults: 500,
                                                 includeSpamTrash: includeSpamTrash)
            ids.formUnion(page.items.map(\.id)); pageToken = page.nextPageToken
        } while pageToken != nil
        return Array(ids)
    }

    private func cacheSources(_ ids: [String], account: Account, isSync: Bool) async throws -> [MailThread] {
        var threads: [MailThread] = []
        for offset in stride(from: 0, to: ids.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(ids[offset..<min(offset + 8, ids.count)])
            let fetched = try await serialized(accountID: account.id) {
                let sources = try await self.fetchSources(batch)
                var results: [MailThread] = []
                for source in sources {
                    let thread = try await self.mapped(source, accountID: account.id)
                    try await self.save(thread, background: isSync)
                    results.append(thread)
                }
                for missing in Set(batch).subtracting(sources.map(\.id)) {
                    try await self.store.remove(id: missing, collection: "threads", accountID: account.id)
                }
                return results
            }
            threads += fetched
        }
        return threads
    }

    private func hydrate(_ source: GoogleMailThread) async throws -> GoogleMailThread {
        var thread = source
        var messages: [GoogleMailMessage] = []
        for var message in source.messages ?? [] {
            if let payload = message.payload { message.payload = try await hydrate(payload, messageID: message.id) }
            messages.append(message)
        }
        thread.messages = messages
        return thread
    }

    private func hydrate(_ source: GoogleMailPart, messageID: String) async throws -> GoogleMailPart {
        var part = source
        if ["text/plain", "text/html"].contains(part.mimeType ?? ""), (part.filename ?? "").isEmpty,
           part.body?.data == nil, let id = part.body?.attachmentId {
            part.body?.data = try await api.attachment(messageID: messageID, attachmentID: id).base64URL
            part.body?.attachmentId = nil
        }
        if let children = part.parts {
            var hydrated: [GoogleMailPart] = []
            for child in children { hydrated.append(try await hydrate(child, messageID: messageID)) }
            part.parts = hydrated
        }
        return part
    }

    private func fetchSources(_ ids: [String]) async throws -> [GoogleMailThread] {
        let api = self.api
        var threads: [GoogleMailThread] = []
        for offset in stride(from: 0, to: ids.count, by: 8) {
            let batch = Array(ids[offset..<min(offset + 8, ids.count)])
            let fetched = try await withThrowingTaskGroup(of: GoogleMailThread?.self, returning: [GoogleMailThread].self) { group in
                for id in batch {
                    group.addTask {
                        do { return try await api.thread(id: id) }
                        catch let error as GoogleAPIError where error.statusCode == 404 { return nil }
                    }
                }
                var results: [GoogleMailThread] = []
                for try await thread in group { if let thread { results.append(thread) } }
                return results
            }
            threads.append(contentsOf: fetched)
        }
        return threads
    }
}
