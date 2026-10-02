import Foundation

struct MailSnapshot: Sendable {
    var account: Account?
    var threads: [MailThread]
    var rules: [SenderRule]
    var bubbles: [BubbleRecord]
    var remoteImageSenders: Set<String>
}

struct MailSendReceipt: Sendable {
    var messageID: String
    var threadID: String
    var warning: String?
}

struct MailUndoToken: Identifiable, Sendable {
    var id: UUID
    var message: String
    var expiresAt: Date
}

/// Gmail owns labels and message content. SQLite owns sender decisions, timers and the cache.
actor MailService {
    private static let specialLabels = ["HEY/Set Aside", "HEY/Bubble Up", "HEY/Screener", "HEY/Screened Out"]
    private let api: GoogleAPI
    private let store: LocalStore
    private var labelMaps: [String: [String: String]] = [:] // Gmail ID -> stable label name.
    private var draftMaps: [String: [String: String]] = [:] // Message ID -> Gmail draft ID.
    private struct ActiveSync: Sendable { var id: UUID; var task: Task<MailSnapshot, Error> }
    private var syncTasks: [String: ActiveSync] = [:]
    private var isDraining = false
    private var operationTails: [String: Task<Void, Never>] = [:]
    private var operationCancellers: [UUID: @Sendable () -> Void] = [:]
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
    private struct ImagePreference: Codable, Sendable { var sender: String }

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

    init(api: GoogleAPI, store: LocalStore) { self.api = api; self.store = store }

    func cached(accountID: String) async throws -> MailSnapshot {
        let threads = try await store.all(MailThread.self, collection: "threads", accountID: accountID)
        let rules = try await store.all(SenderRule.self, collection: "senderRules", accountID: accountID)
        let bubbles = try await store.all(BubbleRecord.self, collection: "bubbles", accountID: accountID)
        let images = try await store.all(ImagePreference.self, collection: "remoteImages", accountID: accountID)
        return MailSnapshot(account: try await store.metadata(Account.self, key: "account", accountID: accountID),
                            threads: threads.sorted { max($0.bubbledAt ?? .distantPast, $0.updatedAt) > max($1.bubbledAt ?? .distantPast, $1.updatedAt) },
                            rules: rules.sorted { $0.key < $1.key }, bubbles: bubbles,
                            remoteImageSenders: Set(images.map(\.sender)))
    }

    func sync(account: Account) async throws -> MailSnapshot {
        guard !isDraining else { throw CancellationError() }
        if let syncTask = syncTasks[account.id] { return try await syncTask.task.value }
        let task = Task {
            try await self.serialized(accountID: account.id) { try await self.performSync(account: account) }
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
        let tails = Array(operationTails.values)
        for tail in tails { await tail.value }
        for sync in syncs { _ = try? await sync.task.value }
        undoActions.removeAll()
    }

    func search(query: String, account: Account) async throws -> [MailThread] {
        try await serialized(accountID: account.id) { try await self.searchImpl(query: query, account: account) }
    }
    func fetchThread(id: String, account: Account) async throws -> MailThread {
        try await serialized(accountID: account.id) { try await self.fetchThreadImpl(id: id, account: account) }
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
        try await serialized(accountID: account.id) { try await self.undoImpl(tokenID: tokenID, account: account) }
    }
    func setRemoteImages(sender: String, allowed: Bool, account: Account) async throws {
        try await serialized(accountID: account.id) { try await self.setRemoteImagesImpl(sender: sender, allowed: allowed, account: account) }
    }
    func saveDraft(_ outgoing: OutgoingMessage, account: Account) async throws -> OutgoingMessage {
        try await serialized(accountID: account.id) { try await self.saveDraftImpl(outgoing, account: account) }
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
        defer { operationCancellers.removeValue(forKey: operationID) }
        operationTails[accountID] = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performSync(account: Account) async throws -> MailSnapshot {
        try await store.setMetadata(account, key: "account", accountID: account.id)
        try await ensureLabels(accountID: account.id)
        try await seedApprovedRecipients(account: account)
        try await refreshDraftMap(accountID: account.id)
        let cursor = try await store.metadata(String.self, key: "mailHistoryID", accountID: account.id)
        if let cursor {
            do { try await incrementalSync(account: account, cursor: cursor) }
            catch let error as GoogleAPIError where error.statusCode == 404 {
                // History cursors expire. Rebuild the cache; app metadata and timers survive.
                try await fullSync(account: account)
            }
        } else { try await fullSync(account: account) }
        try await seedApprovedInboxSenders(account: account)
        try await reconcileScreener(account: account)
        undoActions = undoActions.filter { $0.value.token.expiresAt > .now }
        return try await cached(accountID: account.id)
    }

    private func fullSync(account: Account) async throws {
        // Anchor before enumeration so changes made during this sync appear in the next history poll.
        let anchor = try await api.profile().historyId
        var ids = Set(try await threadIDs(query: "newer_than:90d"))
        for label in ["INBOX", "DRAFT"] + Self.specialLabels {
            ids.formUnion(try await threadIDs(labelIDs: [try labelID(label, accountID: account.id)]))
        }
        let sources = try await fetchSources(Array(ids))
        var records: [LocalStore.Record<MailThread>] = []
        for source in sources {
            let thread = try await mapped(source, accountID: account.id)
            records.append(.init(id: thread.id, value: thread, sortDate: max(thread.bubbledAt ?? .distantPast, thread.updatedAt)))
        }
        try await store.save(records, collection: "threads", accountID: account.id, replacing: true)
        try await store.setMetadata(anchor, key: "mailHistoryID", accountID: account.id)
    }

    private func incrementalSync(account: Account, cursor: String) async throws {
        var pageToken: String?, ids = Set<String>(), nextCursor = cursor
        repeat {
            let page = try await api.history(startHistoryID: cursor, pageToken: pageToken)
            for history in page.history ?? [] { ids.formUnion(history.changedThreadIDs) }
            nextCursor = page.historyId
            pageToken = page.nextPageToken
        } while pageToken != nil
        let sources = try await fetchSources(Array(ids))
        let present = Set(sources.map(\.id))
        for missing in ids.subtracting(present) { try await store.remove(id: missing, collection: "threads", accountID: account.id) }
        for source in sources { try await save(try await mapped(source, accountID: account.id)) }
        // Commit the cursor only after every changed thread has been persisted.
        try await store.setMetadata(nextCursor, key: "mailHistoryID", accountID: account.id)
    }

    private func seedApprovedRecipients(account: Account) async throws {
        if try await store.metadata(Bool.self, key: "sentRecipientsSeeded", accountID: account.id) == true { return }
        // Page through the entire Sent mailbox, not just the recent-mail cache window.
        var pageToken: String?
        var currentRules = try await store.all(SenderRule.self, collection: "senderRules", accountID: account.id)
        repeat {
            let page = try await api.listMessages(labelIDs: ["SENT"], pageToken: pageToken, maxResults: 500)
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
                for message in messages {
                    let recipients = MailMapping.addresses(message.header("To")) + MailMapping.addresses(message.header("Cc")) + MailMapping.addresses(message.header("Bcc"))
                    for recipient in recipients where recipient.email != account.email.lowercased() {
                        if rule(for: recipient.email, rules: currentRules) == nil {
                            let approved = SenderRule(accountID: account.id, key: recipient.email, decision: .approved)
                            try await store.save(approved, id: approved.key, collection: "senderRules", accountID: account.id)
                            currentRules.append(approved)
                        }
                    }
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        // Incomplete seeds safely resume; existing user decisions are never overwritten.
        try await store.setMetadata(true, key: "sentRecipientsSeeded", accountID: account.id)
    }

    /// The Screener applies to senders who appear after setup. Mail already in the Inbox at
    /// first sync stays where it is instead of being moved out of Gmail's Inbox en masse.
    private func seedApprovedInboxSenders(account: Account) async throws {
        if try await store.metadata(Bool.self, key: "inboxSendersSeeded", accountID: account.id) == true { return }
        var rules = try await store.all(SenderRule.self, collection: "senderRules", accountID: account.id)
        let threads = try await store.all(MailThread.self, collection: "threads", accountID: account.id)
        for thread in threads where thread.labels.contains("INBOX") {
            for message in thread.messages where !message.labels.contains("SENT") && !message.labels.contains("DRAFT") {
                let sender = message.from.email.lowercased()
                guard !sender.isEmpty, sender != account.email.lowercased(), rule(for: sender, rules: rules) == nil else { continue }
                let approved = SenderRule(accountID: account.id, key: sender, decision: .approved)
                try await store.save(approved, id: approved.key, collection: "senderRules", accountID: account.id)
                rules.append(approved)
            }
        }
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

    private func reconcileScreener(account: Account) async throws {
        let rules = try await store.all(SenderRule.self, collection: "senderRules", accountID: account.id)
        let threads = try await store.all(MailThread.self, collection: "threads", accountID: account.id)
        for thread in threads {
            guard !thread.labels.contains("TRASH"), !thread.labels.contains("SPAM"),
                  let incoming = thread.messages.reversed().first(where: { !$0.labels.contains("SENT") && !$0.labels.contains("DRAFT") && $0.from.email != account.email.lowercased() }) else { continue }
            let decision = rule(for: incoming.from.email, rules: rules)?.decision
            if decision == .blocked {
                if thread.labels.contains("INBOX") || thread.labels.contains("HEY/Screener") || !thread.labels.contains("HEY/Screened Out") {
                    _ = try await changeLabels(threadID: thread.id, adding: ["HEY/Screened Out"], removing: ["INBOX", "HEY/Screener"], account: account)
                }
            } else if decision == .approved && (thread.labels.contains("HEY/Screener") || thread.labels.contains("HEY/Screened Out")) {
                _ = try await changeLabels(threadID: thread.id, adding: ["INBOX"], removing: ["HEY/Screener", "HEY/Screened Out"], account: account)
            } else if decision == nil && thread.labels.contains("INBOX") {
                _ = try await changeLabels(threadID: thread.id, adding: ["HEY/Screener"], removing: ["INBOX"], account: account)
            }
        }
    }

    private func searchImpl(query: String, account: Account) async throws -> [MailThread] {
        try await prepare(account: account)
        let sources = try await fetchSources(try await threadIDs(query: query))
        var threads: [MailThread] = []
        for source in sources {
            let thread = try await mapped(source, accountID: account.id)
            try await save(thread); threads.append(thread)
        }
        return threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func fetchThreadImpl(id: String, account: Account) async throws -> MailThread {
        try await prepare(account: account)
        let thread = try await mapped(try await api.thread(id: id), accountID: account.id)
        try await save(thread)
        return thread
    }

    private func archiveImpl(threadID: String, account: Account) async throws -> MailUndoToken {
        try await move(threadID: threadID, adding: [], removing: ["INBOX"], message: "Archived", account: account)
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
            _ = try await changeLabels(threadID: threadID, adding: ["HEY/Bubble Up"], removing: ["INBOX", "HEY/Set Aside"], account: account)
        } catch {
            try? await restoreBubble(state.bubble, threadID: threadID, accountID: account.id)
            throw error
        }
        return register(message: "Will bubble up later", threads: [state], accountID: account.id)
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
                guard !current.labels.contains("TRASH"), !current.labels.contains("SPAM"), current.labels.contains("HEY/Bubble Up") else {
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

    private func undoImpl(tokenID: UUID, account: Account) async throws {
        guard let action = undoActions[tokenID], action.accountID == account.id, action.token.expiresAt > .now else { throw MailError.expiredUndo }
        try await prepare(account: account)
        if !action.affectedRuleKeys.isEmpty {
            try await replaceRules(keys: action.affectedRuleKeys, target: action.previousRules, account: account)
        }
        for state in action.threads { try await restoreThread(state, account: account) }
        undoActions.removeValue(forKey: tokenID)
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
        let raw = try MIMEComposer.compose(outgoing, from: account.email)
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
        guard !outgoing.to.isEmpty || !outgoing.cc.isEmpty || !outgoing.bcc.isEmpty else { throw MailError.noRecipients }
        let raw = try MIMEComposer.compose(outgoing, from: account.email)
        let sent: GoogleMailMessage
        if let draftID = outgoing.draftID {
            _ = try await api.updateDraft(id: draftID, raw: raw, threadID: outgoing.threadID)
            sent = try await api.sendDraft(id: draftID)
        } else { sent = try await api.sendMessage(raw: raw, threadID: outgoing.threadID) }
        do {
            // New correspondents become approved immediately, as the first-run Sent seed does.
            var rules = try await store.all(SenderRule.self, collection: "senderRules", accountID: account.id)
            for recipient in MailMapping.addresses((outgoing.to + outgoing.cc + outgoing.bcc).joined(separator: ",")) where rule(for: recipient.email, rules: rules) == nil {
                let approved = SenderRule(accountID: account.id, key: recipient.email, decision: .approved)
                try await store.save(approved, id: approved.key, collection: "senderRules", accountID: account.id)
                rules.append(approved)
            }
            try await refreshDraftMap(accountID: account.id)
            _ = try await refresh(threadID: sent.threadId, accountID: account.id)
            return MailSendReceipt(messageID: sent.id, threadID: sent.threadId, warning: nil)
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

    private func register(message: String, threads: [ThreadState], accountID: String) -> MailUndoToken {
        let token = MailUndoToken(id: UUID(), message: message, expiresAt: .now.addingTimeInterval(5))
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

    private func save(_ thread: MailThread) async throws {
        try await store.save(thread, id: thread.id, collection: "threads", accountID: thread.accountID, sortDate: max(thread.bubbledAt ?? .distantPast, thread.updatedAt))
    }

    private func rule(for sender: String, rules: [SenderRule]) -> SenderRule? {
        let sender = sender.lowercased()
        if let exact = rules.first(where: { $0.key == sender }) { return exact }
        guard let at = sender.lastIndex(of: "@") else { return nil }
        return rules.first { $0.key == String(sender[at...]) }
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

    private func threadIDs(query: String? = nil, labelIDs: [String] = []) async throws -> [String] {
        var pageToken: String?, ids = Set<String>()
        repeat {
            let page = try await api.listThreads(query: query, labelIDs: labelIDs, pageToken: pageToken, maxResults: 500)
            ids.formUnion(page.items.map(\.id)); pageToken = page.nextPageToken
        } while pageToken != nil
        return Array(ids)
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
