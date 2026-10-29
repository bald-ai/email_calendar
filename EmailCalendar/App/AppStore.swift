#if os(macOS)
import AppKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class AppStore {
    var account: Account?
    var threads: [MailThread] = []
    var senderRules: [SenderRule] = [] { didSet { senderRuleIndex = SenderRuleIndex(senderRules) } }
    var remoteImageSenders: Set<String> = []
    var calendars: [CalendarRecord] = []
    var events: [CalendarEvent] = []
    var navigation: Mailbox = .imbox {
        didSet { if navigation != oldValue { poweringThrough = false; clearSelection() } }
    }
    /// The row the keyboard points at.
    var selectedThreadID: String?
    /// Rows picked with ⌘-click, ⇧-click or x. While any are picked, actions apply to all of them.
    var selection: Set<String> = []
    /// Where a ⇧-click range starts: the last row picked.
    @ObservationIgnored var selectionAnchor: String?
    /// A change to several emails or senders is running.
    var isApplyingBatch = false
    /// The thread shown as a full page; nil shows the mailbox list.
    var openThreadID: String?
    /// The open thread was new when opened: the Imbox keeps it with new mail, so j and focus after an action stay there.
    var openedUnreadID: String?
    /// "Power Through New": new Imbox mail as one scrolling stack of cards, instead of the list.
    var poweringThrough = false
    /// Set to ask the mail view to open a blank composer (from menus outside it).
    var composeRequest: UUID? {
        didSet { if composeRequest != nil && navigation == .calendar { navigation = .imbox } }
    }
    var composition: MailComposition?
    var isComposing: Bool { composition != nil && navigation != .calendar }
    var selectedEventID: String?
    var searchQuery = ""
    var isRefreshing = false
    /// ⌘R or a Refresh button: shown in the top bar from the press until its pass ends. Background syncs stay quiet.
    var refreshProgress: RefreshProgress?
    var isSearching = false
    var searchNextPageToken: String?
    var isSigningIn = false
    var isQuitting = false
    var errorMessage: String?
    var undoMessage: String?
    var lastSyncedAt: Date?
    /// The current search was started from Spam and is limited to it.
    @ObservationIgnored private var searchIncludesSpam = false
    /// Emails counting down to send (Undo Send), and ones that need review after a failure or crash.
    var pendingSends: [PendingSend] = []
    /// Interrupted sends being looked up in Gmail's Sent mail right now.
    var checkingPendingSends: Set<String> = []
    /// Shown briefly once Gmail confirms a pending email.
    var sentConfirmation: SentConfirmation?
    static let undoSendDelay: TimeInterval = 30
    /// Mail due longer ago than this (the Mac slept, the app was closed) waits for review instead of going out late.
    private static let overdueGrace: TimeInterval = 60
    @ObservationIgnored private var pendingTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?
    /// Verified Gmail "Send mail as" addresses, the account's own first; the composer offers them as From.
    var sendAddresses: [String] = []
    /// The banner text a failed refresh showed, cleared by the next successful one.
    @ObservationIgnored private var refreshError: String?
    /// ⌘R pressed while another refresh runs: that refresh goes around once more when it ends.
    @ObservationIgnored private var manualRefreshQueued = false
    @ObservationIgnored private var refreshProgressTask: Task<Void, Never>?
    /// Emails closed while Gmail couldn't be reached. Each refresh tries to save them to Gmail.
    @ObservationIgnored private let parkedDrafts: ParkedDrafts?
    @ObservationIgnored private var sendAddressesCheckedAt: Date?
    /// To-dos and the links between email threads and events or to-dos.
    var planner = PlannerSnapshot()
    /// The drawer beside mail: 1 shows Days, -1 shows To-do, 0 shows mail alone.
    var drawerPosition: Int {
        didSet { UserDefaults.standard.set(drawerPosition, forKey: "drawer.position") }
    }
    /// The thread waiting to be linked: the next event or to-do clicked gets it.
    var linkingThreadID: String?
    /// Asks a drawer to scroll to one event or to-do and highlight it.
    var plannerReveal: PlannerReveal?
    /// Asks the To-do drawer to focus its add field.
    var todoFieldRequest: UUID?
    var overlayHeight: Double {
        didSet { UserDefaults.standard.set(overlayHeight, forKey: "overlayHeight") }
    }
    var bubbleNotifications: Bool {
        didSet {
            UserDefaults.standard.set(bubbleNotifications, forKey: "bubbleNotifications")
            if bubbleNotifications { Task { await requestNotificationPermission() } }
        }
    }
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            Task { await configureLoginItem() }
        }
    }
    var accountEmail: String { account?.email ?? "" }
    var isSignedIn: Bool { account != nil }

    @ObservationIgnored let auth: GoogleAuth
    @ObservationIgnored private let database: LocalStore?
    @ObservationIgnored private let mail: MailService?
    @ObservationIgnored private let calendarService: CalendarService?
    @ObservationIgnored let plannerService: PlannerService?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var undoID: UUID?
    /// Runs after a mail undo succeeds, for actions that also changed local data (Move to To-do).
    @ObservationIgnored var undoFollowUp: (@MainActor () async -> Void)?
    /// An undo that is purely local (a deleted to-do, a removed link); used when there is no mail token.
    @ObservationIgnored private var localUndo: (@MainActor () async -> Void)?
    private var cachedThreads: [MailThread] = []
    @ObservationIgnored private var replacingComposition = false
    @ObservationIgnored private var mailSnapshotOrder = MailSnapshotOrder()
    private var senderRuleIndex = SenderRuleIndex()
    @ObservationIgnored private var searchRecovery = SearchResultRecovery()
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var searchTask: Task<MailSearchPage, Error>?
    @ObservationIgnored var openWindow: (() -> Void)?
    @ObservationIgnored var showOverlay: (() -> Void)?
    /// Quick alarms set from the overlay; they ring app-wide.
    @ObservationIgnored let alarms = AlarmCenter()

    init() {
        auth = GoogleAuth()
        let defaults = UserDefaults.standard
        // The overlay grew from 25% to 37.5% of the screen; old untouched defaults move up once.
        if !defaults.bool(forKey: "overlay.taller") {
            defaults.set(true, forKey: "overlay.taller")
            if (defaults.object(forKey: "overlayHeight") as? Double ?? 0.25) <= 0.25 { defaults.removeObject(forKey: "overlayHeight") }
        }
        overlayHeight = defaults.object(forKey: "overlayHeight") as? Double ?? 0.375
        bubbleNotifications = defaults.object(forKey: "bubbleNotifications") as? Bool ?? true
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        // First launch shows mail alone; after that the drawers come back the way they were left.
        drawerPosition = max(-1, min(1, defaults.object(forKey: "drawer.position") as? Int ?? 0))
        do {
            let local = try LocalStore()
            let api = GoogleAPI(auth: auth)
            database = local
            mail = MailService(api: api, store: local)
            calendarService = CalendarService(api: api, store: local)
            plannerService = PlannerService(store: local)
            parkedDrafts = ParkedDrafts(store: local)
        } catch {
            database = nil; mail = nil; calendarService = nil; plannerService = nil; parkedDrafts = nil
            errorMessage = error.localizedDescription
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        account = auth.account
        if errorMessage == nil { errorMessage = auth.restorationError }
        if errorMessage == nil {
            do { _ = try GoogleOAuthConfiguration.fromBundle() }
            catch { reportError(error) }
        }
        if account == nil, auth.isSignedIn, let database {
            do { account = try await database.metadata(Account.self, key: "activeAccount", accountID: "app") }
            catch { reportError(error) }
        }
        await loadCache()
        await restoreDraft()
        await restoreParkedDrafts()
        await configureLoginItem()
        if bubbleNotifications && account != nil { await requestNotificationPermission() }
        if let account, let mail {
            do { await notifyBubbles(try await mail.processDueBubbles(account: account)); try await loadMailCache(accountID: account.id) }
            catch { reportError(error) }
        }
        await refresh()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await self?.refresh()
            }
        }
    }

    func signIn() async {
        guard !isSigningIn, !isQuitting else { return }
        isSigningIn = true
        do {
            account = try await auth.signIn()
            if let account, let database {
                try await database.setMetadata(account, key: "activeAccount", accountID: "app")
            }
        } catch { isSigningIn = false; reportError(error); return }
        isSigningIn = false
        // A composer left open by an expired session belongs to the old account: keep it there, not here.
        if let composition, let owner = composition.accountID, owner != account?.id {
            await checkpointDraft(composition)
            composition.session.cancel(); self.composition = nil
        }
        sendAddresses = []; sendAddressesCheckedAt = nil
        await loadCache()
        await restoreDraft()
        await restoreParkedDrafts()
        if bubbleNotifications { await requestNotificationPermission() }
        await refresh()
    }

    func signOut() async {
        guard !isSigningIn, !isQuitting else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        // Save the open email to Gmail, or keep a local copy that reopens at the next sign-in, before it closes.
        if let composition, let database, let accountID = composition.accountID ?? account?.id {
            try? await DraftTermination.preserve(composition.session, title: composition.title, accountID: accountID, store: database)
        }
        // As at quit, emails counting down are sent (or undone) first instead of silently dropped.
        await finishPendingSends()
        if let accountID = account?.id { await saveParkedDrafts(accountID: accountID) }
        parkedDrafts?.drop()
        // Stop new UI and polling work before draining operations tied to these credentials.
        composition?.session.cancel(); composition = nil; openedUnreadID = nil
        account = nil; threads = []; cachedThreads = []; senderRules = []; remoteImageSenders = []
        calendars = []; events = []; selectedThreadID = nil; selectedEventID = nil; openThreadID = nil; poweringThrough = false
        planner = PlannerSnapshot(); linkingThreadID = nil; plannerReveal = nil
        sendAddresses = []; sendAddressesCheckedAt = nil
        for timer in pendingTimers.values { timer.cancel() }
        pendingTimers = [:]; pendingSends = []; checkingPendingSends = []; sentConfirmation = nil
        searchTask?.cancel(); searchTask = nil; searchGeneration += 1; searchNextPageToken = nil; isSearching = false
        searchQuery = ""; clearSelection(); undoMessage = nil; undoID = nil; undoFollowUp = nil; localUndo = nil; undoTask?.cancel()
        await mail?.cancelAllOperations()
        await calendarService?.cancelAllOperations()
        do {
            try await auth.signOut()
            try await database?.removeMetadata(key: "activeAccount", accountID: "app")
        } catch {
            account = auth.account
            await loadCache()
            reportError(error)
        }
    }

    /// ⌘R and the Refresh buttons. Never dropped: pressed during another refresh, it runs right after that one.
    /// Its errors show even when the same banner was closed, and it asks Gmail again for the open search.
    func refreshNow() async {
        guard account != nil else { return }
        manualRefreshQueued = true
        refreshProgressTask?.cancel()
        refreshProgress = .running
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            let manual = manualRefreshQueued
            manualRefreshQueued = false
            let synced = await syncOnce(manual: manual)
            if manual { finishManualRefresh(synced: synced) }
        } while manualRefreshQueued
    }

    /// One pass over mail and calendar. True when both synced for the account that is still signed in.
    private func syncOnce(manual: Bool) async -> Bool {
        guard let account, let mail, let calendarService else { return false }
        var failure: String?
        // Independent services let the calendar appear while sent-history seeding is still running.
        let progress: @Sendable (MailSnapshot) async -> Void = { [weak self] snapshot in
            await self?.publishMailProgress(snapshot, accountID: account.id)
        }
        let mailTask = Task { try await mail.sync(account: account, progress: progress) }
        let calendarTask = Task { try await calendarService.sync(accountID: account.id) }
        do {
            try await calendarTask.value
            if self.account?.id == account.id { try await loadCalendarCache(accountID: account.id) }
        } catch { reportRefreshError(error, failure: &failure, manual: manual) }
        do {
            let snapshot = try await mailTask.value
            guard self.account?.id == account.id else { return false }
            apply(snapshot)
            let surfaced = try await mail.processDueBubbles(account: account)
            if !surfaced.isEmpty {
                try await loadMailCache(accountID: account.id)
                await notifyBubbles(surfaced)
            }
            lastSyncedAt = .now
        } catch { reportRefreshError(error, failure: &failure, manual: manual) }
        // An "offline" banner from an earlier refresh goes away once syncing works again.
        if failure == nil, let shown = refreshError, errorMessage == shown { errorMessage = nil }
        refreshError = failure
        await saveParkedDrafts(accountID: account.id)
        await refreshSendAddresses(account: account)
        // Syncing only updates results already shown; asking again brings in new matches.
        if manual, !searchQuery.isEmpty, self.account?.id == account.id { await search(searchQuery) }
        return failure == nil && self.account?.id == account.id
    }

    /// "Updated" for a moment, unless the pass ended in a banner or another ⌘R is waiting its turn.
    private func finishManualRefresh(synced: Bool) {
        guard !manualRefreshQueued else { return }
        guard synced, errorMessage == nil else { refreshProgress = nil; return }
        refreshProgress = .updated
        refreshProgressTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.refreshProgress = nil
        }
    }

    /// Checked every few minutes, so an alias added in Gmail appears without a relaunch.
    private func refreshSendAddresses(account: Account) async {
        guard let mail, self.account?.id == account.id,
              sendAddressesCheckedAt.map({ Date.now.timeIntervalSince($0) > 300 }) ?? true else { return }
        sendAddressesCheckedAt = .now
        // Optional: without the list, mail still sends from the account's own address.
        guard let addresses = try? await mail.sendAddresses(account: account), self.account?.id == account.id else { return }
        sendAddresses = addresses
    }

    func refreshCalendar(range: DateInterval) async {
        guard let account, let calendarService else { return }
        do {
            try await calendarService.ensureEvents(accountID: account.id, interval: range)
            guard self.account?.id == account.id else { return }
            try await loadCalendarCache(accountID: account.id)
        } catch { reportError(error) }
    }

    private func publishMailProgress(_ snapshot: MailSnapshot, accountID: String) {
        if account?.id == accountID { apply(snapshot) }
    }

    func search(_ query: String) async {
        searchGeneration += 1
        searchRecovery.reset()
        let generation = searchGeneration
        searchTask?.cancel(); searchTask = nil
        searchNextPageToken = nil; isSearching = false
        searchQuery = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchQuery = ""; threads = cachedThreads; return
        }
        guard let account, let mail else { return }
        searchIncludesSpam = navigation == .spam
        let scoped = searchScoped(query)
        do {
            isSearching = true
            defer { if generation == searchGeneration { isSearching = false; searchTask = nil } }
            let task = Task { [searchIncludesSpam] in try await mail.searchPage(query: scoped, includeSpamTrash: searchIncludesSpam, account: account) }
            searchTask = task
            let result = try await task.value
            guard generation == searchGeneration, self.account?.id == account.id else { return }
            threads = acceptSearchPage(result, accountID: account.id); searchNextPageToken = result.nextPageToken
        } catch { if generation == searchGeneration { reportError(error) } }
    }

    /// Searching from the Spam folder looks only inside Spam, so a missing email can be found there.
    private func searchScoped(_ query: String) -> String { searchIncludesSpam ? "in:spam (\(query))" : query }

    func loadMoreSearch() async {
        guard !isSearching, let token = searchNextPageToken, let mail, let account else { return }
        let generation = searchGeneration, query = searchScoped(searchQuery), spam = searchIncludesSpam
        isSearching = true
        defer { if generation == searchGeneration { isSearching = false; searchTask = nil } }
        do {
            let task = Task { try await mail.searchPage(query: query, pageToken: token, includeSpamTrash: spam, account: account) }
            searchTask = task
            let page = try await task.value
            guard generation == searchGeneration, self.account?.id == account.id else { return }
            let existing = Set(threads.map(\.id))
            threads += acceptSearchPage(page, accountID: account.id).filter { !existing.contains($0.id) }
            searchNextPageToken = page.nextPageToken
        } catch { if generation == searchGeneration { reportError(error) } }
    }

    /// A reply, forward or reopened draft, with the attachments and images it carries over downloaded.
    func composition(for message: MailMessage, action: MailComposeAction) async throws -> MailComposition {
        let full = try await fullMessage(message)
        var data: [String: Data] = [:]
        for attachment in MailComposition.neededAttachments(full, action: action) where attachment.inlineData == nil {
            data[attachment.id] = try await attachmentData(attachment, message: full)
        }
        switch action {
        case .reply, .replyAll:
            return .reply(to: full, accountEmail: accountEmail, sendAddresses: sendAddresses, all: action == .replyAll, data: data)
        case .forward: return .forward(full, accountEmail: accountEmail, sendAddresses: sendAddresses, data: data)
        case .editDraft: return .draft(full, accountEmail: accountEmail, data: data)
        }
    }

    func fullMessage(_ message: MailMessage) async throws -> MailMessage {
        guard message.needsBodyHydration else { return message }
        guard let mail, let account else { throw AppError.signInRequired }
        guard account.id == message.accountID else { throw CancellationError() }
        let thread = try await mail.fetchThread(id: message.threadID, account: account)
        try await loadMailCache(accountID: account.id)
        guard let hydrated = thread.messages.first(where: { $0.id == message.id }) else {
            throw AppError.messageNoLongerAvailable
        }
        return hydrated
    }

    /// Body downloads in flight, so a Power Through card and the prefetch ahead of it share one.
    @ObservationIgnored private var bodyFetches: [String: Task<Void, Error>] = [:]

    /// Downloads the full bodies of these threads, then re-reads the cache once for all of them, not once each:
    /// every re-read redraws the whole mail page.
    func hydrateBodies(of threads: [MailThread]) async throws {
        guard let mail, let account else { throw AppError.signInRequired }
        let pending = threads.filter { $0.accountID == account.id && $0.messages.contains(where: \.needsBodyHydration) }
        guard !pending.isEmpty else { return }
        var started: [String] = []
        let fetches = pending.map { thread in
            if let fetch = bodyFetches[thread.id] { return fetch }
            let fetch = Task { _ = try await mail.fetchThread(id: thread.id, account: account) }
            bodyFetches[thread.id] = fetch
            started.append(thread.id)
            return fetch
        }
        defer { for id in started { bodyFetches[id] = nil } }
        var failure: Error?
        for fetch in fetches {
            do { try await fetch.value } catch { failure = failure ?? error }
        }
        // Whoever started a download re-reads the cache; a caller that only joined one waits for that.
        if !started.isEmpty { try await loadMailCache(accountID: account.id) }
        if let failure { throw failure }
    }

    /// Search membership can change while reading a thread; the open page still follows its cache.
    var openThread: MailThread? {
        guard let openThreadID else { return nil }
        return threads.first { $0.id == openThreadID } ?? cachedThreads.first { $0.id == openThreadID }
    }

    func replaceComposition(with next: MailComposition) {
        guard !isQuitting, !replacingComposition, composition?.session.isSending != true else { return }
        var next = next
        next.accountID = account?.id
        let previous = composition, accountID = account?.id
        replacingComposition = true
        Task {
            defer { replacingComposition = false }
            do {
                try await previous?.session.flush()
                guard account?.id == accountID, composition?.id == previous?.id,
                      previous?.session.isSending != true else { return }
                previous?.session.cancel()
                composition = next
            } catch { reportError(error) }
        }
    }

    func visibleThreads(mailbox: Mailbox) -> [MailThread] {
        let result = threads.filter { thread in
            if !searchQuery.isEmpty { return true }
            let labels = thread.labels
            if labels.contains("TRASH") { return false }
            if mailbox == .spam { return thread.hasSpam }
            if thread.isSpam { return false }
            switch mailbox {
            case .imbox:
                let sender = thread.messages.filter { !isOwnAddress($0.from.email) && !$0.labels.contains("SPAM") }
                    .max { $0.date < $1.date }?.from.email ?? thread.sender.email
                return labels.contains("INBOX") && decision(for: sender) == .approved
            case .setAside: return labels.contains("HEY/Set Aside")
            case .bubbleUp: return labels.contains("HEY/Bubble Up")
            case .screener: return labels.contains("HEY/Screener")
            case .screenedOut: return labels.contains("HEY/Screened Out")
            case .spam: return thread.hasSpam
            case .sent: return labels.contains("SENT")
            case .drafts: return labels.contains("DRAFT") && !thread.messages.contains { isPendingDraft($0.draftID) }
            case .allMail: return true
            case .calendar: return false
            }
        }
        return result.sorted {
            if mailbox == .imbox && searchQuery.isEmpty {
                return MailThread.imboxPrecedes($0, $1, openedUnreadID: openedUnreadID)
            }
            if mailbox == .imbox {
                return max($0.bubbledAt ?? .distantPast, $0.updatedAt) > max($1.bubbledAt ?? .distantPast, $1.updatedAt)
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func open(_ thread: MailThread) {
        selectedThreadID = thread.id
        openThreadID = thread.id
        openedUnreadID = thread.unread ? thread.id : nil
        Task {
            if let message = thread.messages.first(where: \.needsBodyHydration) {
                do { _ = try await fullMessage(message) } catch { reportError(error) }
            }
            if thread.unread { await setRead(thread, true) }
        }
    }

    /// Back to the page under the thread: the mailbox list, or the Power Through stack.
    func closeThread() {
        openThreadID = nil
        openedUnreadID = nil
    }

    /// New Imbox mail, oldest first, so Power Through works through it in arrival order.
    var newForYou: [MailThread] {
        visibleThreads(mailbox: .imbox).filter(\.unread).sorted { $0.updatedAt < $1.updatedAt }
    }

    func powerThroughNew() {
        guard !newForYou.isEmpty else { return }
        openThreadID = nil
        poweringThrough = true
    }

    func endPowerThrough() {
        poweringThrough = false
    }

    /// After acting on the open thread, go back to the page under it; the thread has left the list or stack.
    func advanceAfterAction(from threadID: String) {
        guard openThreadID == threadID else { return }
        closeThread()
    }

    /// Power Through's "Mark all as seen": the given threads move to Previously Seen, then back to the Imbox.
    func markAllSeen(_ threads: [MailThread]) async {
        guard let mail, let account else { return }
        let seenAt = Date.now
        do {
            for thread in threads where thread.unread && thread.accountID == account.id {
                _ = try await mail.markUnread(threadID: thread.id, unread: false, seenAt: seenAt, account: account)
            }
            if self.account?.id == account.id { try await loadMailCache(accountID: account.id) }
        } catch { reportError(error) }
        endPowerThrough()
    }

    func decision(for sender: String) -> ScreeningDecision? {
        if isOwnAddress(sender) { return .approved }
        return senderRuleIndex.rule(for: sender.lowercased())?.decision
    }

    /// The account's address or one of its send-as addresses, so replies sent as an alias count as ours.
    func isOwnAddress(_ address: String) -> Bool {
        let address = address.lowercased()
        return address == accountEmail.lowercased() || sendAddresses.contains { $0.lowercased() == address }
    }

    @discardableResult
    func archive(_ thread: MailThread) async -> Bool {
        guard account?.id == thread.accountID else { return false }
        return await performMailAction { mail, account in try await mail.archive(threadID: thread.id, account: account) }
    }
    func trash(_ thread: MailThread) async {
        guard account?.id == thread.accountID else { return }
        await performMailAction { mail, account in try await mail.trash(threadID: thread.id, account: account) }
    }
    func moveToSpam(_ thread: MailThread) async {
        guard account?.id == thread.accountID else { return }
        await performMailAction { mail, account in try await mail.moveToSpam(threadID: thread.id, account: account) }
    }
    func notSpam(_ thread: MailThread) async {
        guard account?.id == thread.accountID else { return }
        await performMailAction { mail, account in try await mail.notSpam(threadID: thread.id, account: account) }
    }
    var unreadSpamCount: Int { cachedThreads.filter { $0.hasSpam && $0.unread && !$0.labels.contains("TRASH") }.count }
    func setRead(_ thread: MailThread, _ read: Bool) async {
        guard let mail, let account, account.id == thread.accountID else { return }
        do {
            _ = try await mail.markUnread(threadID: thread.id, unread: !read, account: account)
            if self.account?.id == account.id { try await loadMailCache(accountID: account.id) }
        } catch { reportError(error) }
    }
    func toggleSetAside(_ thread: MailThread) async {
        guard account?.id == thread.accountID else { return }
        await performMailAction { mail, account in try await mail.toggleSetAside(threadID: thread.id, account: account) }
    }
    func bubbleUp(_ thread: MailThread, _ date: Date) async {
        guard account?.id == thread.accountID else { return }
        await performMailAction { mail, account in try await mail.bubbleUp(threadID: thread.id, date: date, account: account) }
    }
    // MARK: Selection

    func toggleSelection(_ id: String) {
        if selection.remove(id) == nil { selection.insert(id) }
        selectionAnchor = id
    }

    /// ⇧-click: picks every row from the anchor to this one, in the order the list shows them.
    func extendSelection(to id: String, in order: [String]) {
        guard let anchor = selectionAnchor ?? selectedThreadID, let start = order.firstIndex(of: anchor),
              let end = order.firstIndex(of: id) else { return toggleSelection(id) }
        selection.formUnion(order[min(start, end)...max(start, end)])
        selectedThreadID = id
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// One change to several threads, with a single Undo.
    @discardableResult
    func change(_ change: MailThreadChange, threads: [MailThread]) async -> Bool {
        let ids = threads.filter { $0.accountID == account?.id }.map(\.id)
        guard !ids.isEmpty, !isApplyingBatch else { return false }
        isApplyingBatch = true
        defer { isApplyingBatch = false }
        return await performMailAction { mail, account in try await mail.change(change, threadIDs: ids, account: account) }
    }

    /// The Screener's Yes or No for several senders, with a single Undo.
    func decideSenders(keys: [String], decision: ScreeningDecision) async {
        guard !keys.isEmpty, !isApplyingBatch else { return }
        isApplyingBatch = true
        defer { isApplyingBatch = false }
        await performMailAction { mail, account in try await mail.decide(senders: keys, decision: decision, account: account) }
    }

    @discardableResult
    func decideSender(key: String, decision: ScreeningDecision) async -> Bool {
        await performMailAction { mail, account in
            try await mail.decide(sender: key, decision: decision, domain: key.hasPrefix("@"), account: account)
        }
    }
    func undo() async {
        if undoID == nil, let localUndo {
            self.localUndo = nil; undoMessage = nil; undoTask?.cancel()
            await localUndo()
            return
        }
        guard let undoID, let account, let mail else { return }
        do {
            try await mail.undo(tokenID: undoID, account: account)
            self.undoID = nil; undoMessage = nil; undoTask?.cancel()
            if let followUp = undoFollowUp { undoFollowUp = nil; await followUp() }
            try await loadMailCache(accountID: account.id)
        } catch { reportError(error) }
    }

    /// Shows the undo bar for a change that only touched local data.
    func offerUndo(_ message: String, _ undo: @escaping @MainActor () async -> Void) {
        undoID = nil; undoFollowUp = nil; localUndo = undo; undoMessage = message
        scheduleUndoExpiry()
    }

    private func scheduleUndoExpiry() {
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.undoMessage = nil; self?.undoID = nil; self?.undoFollowUp = nil; self?.localUndo = nil
        }
    }

    /// A thread from the current list or the full cache, for links to mail that left the list.
    func thread(id: String) -> MailThread? {
        threads.first { $0.id == id } ?? cachedThreads.first { $0.id == id }
    }

    func openLinkedThread(id: String) async {
        if let thread = thread(id: id) { open(thread); return }
        guard let account, let mail else { return }
        do {
            let thread = try await mail.fetchThread(id: id, account: account)
            guard self.account?.id == account.id else { return }
            try await loadMailCache(accountID: account.id)
            open(thread)
        } catch { reportError(error) }
    }
    /// A local copy of the open email, written while Gmail can't save it, so a crash or power loss doesn't lose it.
    func checkpointDraft(_ composition: MailComposition) async {
        guard parkedDrafts?.contains(composition.session) != true, let database, let accountID = composition.accountID ?? account?.id,
              let buffer = composition.session.recoveryBuffer else { return }
        try? await database.setMetadata(DraftRecovery(title: composition.title, buffer: buffer),
                                        key: DraftRecovery.metadataKey, accountID: accountID)
    }

    /// Save & close while Gmail can't be reached: the email is kept on this Mac and the composer closes.
    func park(_ composition: MailComposition) async throws {
        guard let database, let parkedDrafts, let accountID = composition.accountID ?? account?.id else { throw AppError.draftStorageUnavailable }
        try await parkedDrafts.park(composition.session, id: composition.id.uuidString, title: composition.title,
                                    accountID: accountID, save: parkedSaver(accountID: accountID))
        // The parked record replaces its crash checkpoint.
        try? await database.removeDraftRecovery(ifMatching: composition.session.outgoing, accountID: accountID)
        if self.composition?.id == composition.id { self.composition = nil }
        errorMessage = "Gmail can't be reached, so “\(composition.title)” is kept on this Mac. It goes to Drafts when you're back online."
    }

    private func parkedSaver(accountID: String) -> ParkedDrafts.Saver {
        { [weak self] outgoing in
            guard let self, self.account?.id == accountID else { throw CancellationError() }
            return try await self.saveDraft(outgoing)
        }
    }

    private func saveParkedDrafts(accountID: String) async {
        guard let refused = await parkedDrafts?.saveAll(accountID: accountID).first else { return }
        errorMessage = "“\(refused.title)” is kept on this Mac, but Gmail won't save it: \(refused.error.localizedDescription)"
    }

    /// After a relaunch or sign-in, emails kept on this Mac go back to waiting for Gmail.
    private func restoreParkedDrafts() async {
        guard let account, let parkedDrafts else { return }
        do { try await parkedDrafts.restore(accountID: account.id, save: parkedSaver(accountID: account.id)) }
        catch { reportError(error) }
    }

    func saveDraft(_ outgoing: OutgoingMessage) async throws -> OutgoingMessage {
        guard let account, let mail else { throw AppError.signInRequired }
        let result = try await mail.saveDraft(outgoing, account: account)
        do {
            if !isQuitting { try await database?.removeDraftRecovery(ifMatching: result, accountID: account.id) }
            try await loadMailCache(accountID: account.id)
        }
        catch { errorMessage = "Draft saved to Gmail, but the local view could not refresh: \(error.localizedDescription)" }
        return result
    }
    /// Closes the composer without keeping the email: its Gmail draft and local copy are removed.
    func discard(_ composition: MailComposition) async throws {
        guard let account, let mail else { throw AppError.signInRequired }
        let outgoing = await composition.session.stopSaving()
        do { try await mail.discardDraft(outgoing, account: account) }
        catch { composition.session.resume(); throw error }
        composition.session.cancel()
        try? await database?.removeDraftRecovery(ifMatching: outgoing, accountID: account.id)
        if self.composition?.id == composition.id { self.composition = nil }
        try? await loadMailCache(accountID: account.id)
    }

    func send(_ outgoing: OutgoingMessage) async throws {
        guard let account, let mail else { throw AppError.signInRequired }
        // Keep the composer buffer until the email is safely queued: a crash while saving reopens it.
        if let composition, let buffer = composition.session.recoveryBuffer, let database {
            try await database.setMetadata(DraftRecovery(title: composition.title, buffer: buffer),
                                           key: DraftRecovery.metadataKey, accountID: account.id)
        }
        let pending: PendingSend
        do { pending = try await mail.queueSend(outgoing, delay: Self.undoSendDelay, account: account) }
        catch is MailDeliveryUncertainError {
            // An earlier send of this draft was interrupted: look it up in Gmail, never send it again.
            let receipt = try await mail.send(outgoing, account: account)
            if let warning = receipt.warning { errorMessage = warning }
            try? await database?.removeDraftRecovery(ifMatching: outgoing, accountID: account.id)
            try? await loadMailCache(accountID: account.id)
            return
        }
        guard self.account?.id == account.id else { return }
        try? await database?.removeDraftRecovery(ifMatching: outgoing, accountID: account.id)
        pendingSends.removeAll { $0.draftID == pending.draftID }
        pendingSends.append(pending)
        schedulePendingSend(pending, accountID: account.id)
        do { try await loadMailCache(accountID: account.id) }
        catch { errorMessage = "Email queued, but the local view could not refresh: \(error.localizedDescription)" }
    }

    // MARK: Undo Send

    func isPendingDraft(_ draftID: String?) -> Bool {
        guard let draftID else { return false }
        return pendingSends.contains { $0.draftID == draftID }
    }
    /// Counting down, or being handed to Gmail.
    var activePendingSends: [PendingSend] { pendingSends.filter { $0.status == .waiting || $0.status == .sending } }
    /// Not sent, or not known to be sent: these need a decision.
    var unresolvedPendingSends: [PendingSend] { pendingSends.filter { $0.status == .failed || $0.status == .uncertain } }

    func undoPendingSend(_ draftID: String) async {
        guard let mail, let account else { return }
        pendingTimers[draftID]?.cancel(); pendingTimers[draftID] = nil
        do {
            let undone = try await mail.cancelPendingSend(draftID: draftID, account: account)
            await reloadPendingSends(accountID: account.id)
            guard undone != nil else { errorMessage = "Too late to undo: this email is already being sent."; return }
            // While quitting, the email just stays in Drafts.
            if !isQuitting { await openDraft(draftID: draftID) }
        } catch {
            reportError(error)
            // Its timer is gone: hold it for review rather than leave it counting down forever.
            try? await mail.holdPendingSend(draftID: draftID, reason: "Undo failed. Review before sending.", account: account)
            await reloadPendingSends(accountID: account.id)
        }
    }
    func sendPendingNow(_ draftID: String) async {
        guard let account else { return }
        pendingTimers[draftID]?.cancel()
        await deliverPendingSend(draftID: draftID, accountID: account.id, now: true)
    }
    /// After a definite failure: a fresh countdown, so it can still be undone.
    func retryPendingSend(_ draftID: String) async {
        guard let mail, let account else { return }
        do {
            if let pending = try await mail.reschedulePendingSend(draftID: draftID, delay: Self.undoSendDelay, account: account) {
                schedulePendingSend(pending, accountID: account.id)
            }
        } catch { reportError(error) }
        await reloadPendingSends(accountID: account.id)
    }
    /// Looks in Gmail's Sent mail again for an email whose confirmation was lost.
    func checkPendingSend(_ draftID: String) async {
        guard let account, !checkingPendingSends.contains(draftID) else { return }
        checkingPendingSends.insert(draftID)
        defer { checkingPendingSends.remove(draftID) }
        await deliverPendingSend(draftID: draftID, accountID: account.id)
    }
    /// Stops tracking it; the email stays in Drafts. For an uncertain send, only after the person has checked.
    func dismissPendingSend(_ draftID: String) async {
        guard let mail, let account else { return }
        pendingTimers[draftID]?.cancel(); pendingTimers[draftID] = nil
        do { _ = try await mail.cancelPendingSend(draftID: draftID, includingUncertain: true, account: account) }
        catch { reportError(error) }
        await reloadPendingSends(accountID: account.id)
    }

    /// Opens a Gmail draft in the composer with its attachments, as Edit Draft does.
    func openDraft(draftID: String) async {
        guard let account else { return }
        try? await loadMailCache(accountID: account.id)
        guard let message = cachedThreads.lazy.flatMap(\.messages).first(where: { $0.draftID == draftID }) else {
            navigation = .drafts; errorMessage = "The email is in Drafts."; return
        }
        do {
            let request = try await composition(for: message, action: .editDraft)
            guard self.account?.id == account.id else { return }
            if navigation == .calendar { navigation = .imbox }
            replaceComposition(with: request)
        } catch { reportError(error) }
    }

    /// The draft message behind a pending email, for its read-only preview.
    func pendingDraftMessage(_ draftID: String) -> MailMessage? {
        cachedThreads.lazy.flatMap(\.messages).first { $0.draftID == draftID }
    }

    private func reloadPendingSends(accountID: String) async {
        guard let mail, account?.id == accountID else { return }
        do {
            let loaded = try await mail.pendingSends(accountID: accountID)
            if account?.id == accountID { pendingSends = loaded }
        } catch { reportError(error) }
    }

    /// At launch and sign-in: resume countdowns, hold overdue mail, and look up sends a crash interrupted.
    private func resumePendingSends(accountID: String) async {
        await reloadPendingSends(accountID: accountID)
        for pending in pendingSends {
            switch pending.status {
            case .waiting: schedulePendingSend(pending, accountID: accountID)
            case .sending, .uncertain: Task { await checkPendingSend(pending.draftID) }
            case .failed: break
            }
        }
    }

    private func schedulePendingSend(_ pending: PendingSend, accountID: String) {
        pendingTimers[pending.draftID]?.cancel()
        pendingTimers[pending.draftID] = Task { [weak self] in
            let wait = pending.sendAt.timeIntervalSinceNow
            if wait > 0 { do { try await Task.sleep(for: .seconds(wait)) } catch { return } }
            await self?.deliverPendingSend(draftID: pending.draftID, accountID: accountID)
        }
    }

    private func deliverPendingSend(draftID: String, accountID: String, now: Bool = false) async {
        pendingTimers[draftID] = nil
        guard let mail, let account, account.id == accountID,
              let index = pendingSends.firstIndex(where: { $0.draftID == draftID }) else { return }
        let pending = pendingSends[index]
        if pending.status == .waiting, !now, Date.now.timeIntervalSince(pending.sendAt) > Self.overdueGrace {
            do {
                try await mail.holdPendingSend(draftID: draftID,
                    reason: "It was due while the Mac was asleep or the app was closed, so it wasn't sent.", account: account)
            } catch { reportError(error) }
            await reloadPendingSends(accountID: accountID)
            return
        }
        if pending.status == .waiting { pendingSends[index].status = .sending }
        do {
            if let receipt = try await mail.deliverPendingSend(draftID: draftID, account: account) {
                if let warning = receipt.warning { errorMessage = warning }
                confirmSent(subject: pending.subject, threadID: receipt.threadID)
                try? await loadMailCache(accountID: accountID)
            }
        } catch { reportError(error) }
        await reloadPendingSends(accountID: accountID)
        if pending.status == .waiting, let after = pendingSends.first(where: { $0.draftID == draftID }), after.status == .failed || after.status == .uncertain {
            errorMessage = "“\(pending.subject.isEmpty ? "(no subject)" : pending.subject)” wasn’t sent. It’s waiting for you at the top of the Imbox."
        }
    }

    private func confirmSent(subject: String, threadID: String) {
        sentConfirmation = SentConfirmation(subject: subject, threadID: threadID)
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.sentConfirmation = nil
        }
    }

    /// Quit waits for countdowns to end (or Send now / Undo) and for Gmail to confirm; failures stay saved.
    private func finishPendingSends() async {
        let deadline = (activePendingSends.map(\.sendAt).max() ?? .now).addingTimeInterval(90)
        while !activePendingSends.isEmpty, Date.now < deadline {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    func attachmentData(_ attachment: MailAttachment, message: MailMessage) async throws -> Data {
        guard account?.id == message.accountID else { throw CancellationError() }
        if let data = attachment.inlineData { return data }
        guard let mail, let account else { throw AppError.signInRequired }
        return try await mail.attachment(messageID: message.id, attachmentID: attachment.id, account: account)
    }
    func allowsRemoteImages(sender: String) -> Bool { remoteImageSenders.contains(sender.lowercased()) }
    func setAllowsRemoteImages(sender: String, allowed: Bool) async {
        guard let mail, let account else { return }
        do {
            try await mail.setRemoteImages(sender: sender, allowed: allowed, account: account)
            try await loadMailCache(accountID: account.id)
        } catch { reportError(error) }
    }

    @discardableResult
    func saveEvent(_ event: CalendarEvent, scope: EventEditScope = .thisEvent, originalCalendarID: String? = nil, originalEvent: CalendarEvent? = nil, creationID: UUID? = nil,
                   recoverMovedEdit: ((CalendarEvent) -> Void)? = nil) async -> Bool {
        guard let calendarService, account?.id == event.accountID else { return false }
        do {
            if event.id.isEmpty { _ = try await calendarService.create(event, requestID: creationID) }
            else {
                let oldCalendar = originalCalendarID ?? events.first { $0.cacheID == event.cacheID }?.calendarID
                _ = try await calendarService.update(event, originalCalendarID: oldCalendar, scope: scope, originalEvent: originalEvent)
            }
            await reloadCalendarAfterWrite(accountID: event.accountID)
            return true
        } catch let error as CalendarMoveIncompleteError {
            recoverMovedEdit?(error.pendingEvent)
            try? await loadCalendarCache(accountID: event.accountID)
            reportError(error); return false
        } catch let error as CalendarWriteCommittedError {
            try? await loadCalendarCache(accountID: event.accountID)
            reportError(error); return true
        } catch {
            try? await loadCalendarCache(accountID: event.accountID)
            reportError(error); return false
        }
    }
    @discardableResult
    func deleteEvent(_ event: CalendarEvent, scope: EventEditScope = .thisEvent) async -> Bool {
        guard let calendarService, account?.id == event.accountID else { return false }
        do { try await calendarService.delete(event, scope: scope); await reloadCalendarAfterWrite(accountID: event.accountID); return true }
        catch let error as CalendarWriteCommittedError { reportError(error); return true }
        catch { reportError(error); return false }
    }
    @discardableResult
    func respondToEvent(_ event: CalendarEvent, response: AttendanceStatus, scope: EventEditScope = .thisEvent) async -> Bool {
        guard let calendarService, account?.id == event.accountID else { return false }
        do {
            _ = try await calendarService.respond(to: event, status: response, scope: scope)
            if scope == .allEvents { try? await calendarService.sync(accountID: event.accountID) }
            await reloadCalendarAfterWrite(accountID: event.accountID); return true
        }
        catch let error as CalendarWriteCommittedError { reportError(error); return true }
        catch { reportError(error); return false }
    }
    func setCalendarVisible(_ calendar: CalendarRecord, _ visible: Bool) async {
        guard let calendarService, account?.id == calendar.accountID else { return }
        do {
            try await calendarService.setVisibility(calendarID: calendar.id, accountID: calendar.accountID, isVisible: visible)
            try await loadCalendarCache(accountID: calendar.accountID)
        } catch { reportError(error) }
    }
    @discardableResult
    func quickAdd(title: String, start: Date) async -> Bool {
        guard let calendar = calendars.first(where: { $0.isPrimary && $0.canEdit }) ?? calendars.first(where: \.canEdit),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return await saveEvent(CalendarEvent(id: "", calendarID: calendar.id, accountID: calendar.accountID,
                                            title: title, start: start, end: start.addingTimeInterval(1800)))
    }
    /// Saves an event found by AI add: on the calendar it names (or the primary one), repeating if it repeats.
    func quickAdd(_ found: ExtractedEvent) async -> Bool {
        let named = found.calendar.flatMap { name in calendars.first { $0.canEdit && $0.title == name } }
        guard let calendar = named ?? calendars.first(where: { $0.isPrimary && $0.canEdit }) ?? calendars.first(where: \.canEdit) else { return false }
        return await saveEvent(found.calendarEvent(in: calendar), creationID: found.id)
    }
    func openMainWindow(event: CalendarEvent? = nil) {
        if let event { navigation = .calendar; selectedEventID = event.cacheID }
        openWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Offline, every poll fails the same way: once dismissed, that banner stays away until something else goes wrong.
    /// A refresh asked for with ⌘R or Refresh brings it back, so pressing it never looks like nothing happened.
    private func reportRefreshError(_ error: any Error, failure: inout String?, manual: Bool) {
        guard !(error is CancellationError) else { return }
        let text = error.localizedDescription, shown = errorMessage
        let dismissed = !manual && text == refreshError && shown != text
        failure = text
        reportError(error)
        if dismissed, account != nil { errorMessage = shown }
    }

    func reportError(_ error: any Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
        if account != nil && !auth.isSignedIn {
            account = nil; threads = []; cachedThreads = []; calendars = []; events = []
            senderRules = []; remoteImageSenders = []; selectedThreadID = nil; planner = PlannerSnapshot()
        }
    }

    func prepareToQuit() async -> Bool {
        isQuitting = true
        if let composition {
            do {
                guard let database, let accountID = composition.accountID ?? account?.id else { throw AppError.draftStorageUnavailable }
                try await DraftTermination.preserve(composition.session, title: composition.title, accountID: accountID, store: database)
                composition.session.cancel()
            } catch {
                isQuitting = false
                reportError(error)
                return false
            }
        }
        await finishPendingSends()
        return true
    }

    private func restoreDraft() async {
        guard composition == nil, let account, let database else { return }
        do {
            if let recovery = try await database.metadata(DraftRecovery.self, key: DraftRecovery.metadataKey, accountID: account.id),
               self.account?.id == account.id {
                composition = MailComposition(recovery: recovery, accountID: account.id)
                navigation = .imbox
            }
        } catch { reportError(error) }
    }

    @discardableResult
    func performMailAction(_ action: (MailService, Account) async throws -> MailUndoToken) async -> Bool {
        guard let mail, let account else { return false }
        do {
            let token = try await action(mail, account)
            guard self.account?.id == account.id else { return false }
            undoID = token.id; undoMessage = token.message; undoFollowUp = nil; localUndo = nil
            if let warning = token.warning { errorMessage = warning }
            scheduleUndoExpiry()
            try await loadMailCache(accountID: account.id)
            return true
        } catch { reportError(error); return false }
    }
    private func apply(_ snapshot: MailSnapshot) {
        guard let account, mailSnapshotOrder.accept(revision: snapshot.revision, accountID: account.id) else { return }
        cachedThreads = snapshot.threads
        if searchQuery.isEmpty { threads = snapshot.threads }
        else {
            let updated = Dictionary(snapshot.threads.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            threads = threads.compactMap { updated[$0.id] }
        }
        senderRules = snapshot.rules; remoteImageSenders = snapshot.remoteImageSenders
    }

    private func acceptSearchPage(_ page: MailSearchPage, accountID: String) -> [MailThread] {
        var latest = Dictionary(cachedThreads.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        if mailSnapshotOrder.accept(revision: page.revision, accountID: accountID) {
            for thread in page.threads { latest[thread.id] = thread }
            cachedThreads = Array(latest.values)
        }
        return page.threads.compactMap { latest[$0.id] }
    }
    private func loadCache() async {
        guard let account else { return }
        do {
            try await loadMailCache(accountID: account.id)
            try await loadCalendarCache(accountID: account.id)
            try await loadPlanner(accountID: account.id)
            if let cached = try await mail?.cachedSendAddresses(accountID: account.id), self.account?.id == account.id {
                sendAddresses = cached
            }
        } catch { reportError(error) }
        await resumePendingSends(accountID: account.id)
    }
    private func loadMailCache(accountID: String) async throws {
        guard account?.id == accountID else { return }
        if let mail {
            let before = Dictionary(cachedThreads.map { ($0.id, $0.labels) }, uniquingKeysWith: { _, latest in latest })
            let snapshot = try await mail.cached(accountID: accountID)
            if account?.id == accountID { apply(snapshot) }
            let query = searchQuery, generation = searchGeneration
            if !query.isEmpty, let account, account.id == accountID {
                let changed = searchRecovery.candidates(visible: threads, cached: cachedThreads, previous: before)
                for thread in changed {
                    let matches = try await mail.matchesSearch(thread, query: searchScoped(query), includeSpamTrash: searchIncludesSpam, account: account)
                    guard generation == searchGeneration, self.account?.id == accountID else { return }
                    if matches {
                        if searchRecovery.removedIDs.contains(thread.id), !threads.contains(where: { $0.id == thread.id }) {
                            threads.append(thread)
                        }
                        searchRecovery.restored(thread.id)
                    } else {
                        if threads.contains(where: { $0.id == thread.id }) { searchRecovery.removed(thread.id) }
                        threads.removeAll { $0.id == thread.id }
                    }
                }
            }
        }
    }
    /// Re-reads cached events, so they are placed again after the time zone changed, even offline.
    func reloadCalendarCache() async {
        guard let account else { return }
        do { try await loadCalendarCache(accountID: account.id) } catch { reportError(error) }
    }

    private func loadCalendarCache(accountID: String) async throws {
        guard account?.id == accountID else { return }
        if let calendarService {
            let cachedCalendars = try await calendarService.cachedCalendars(accountID: accountID)
            let cachedEvents = try await calendarService.cachedEvents(accountID: accountID, visibleOnly: true)
            if account?.id == accountID { calendars = cachedCalendars; events = cachedEvents }
        }
    }
    private func reloadCalendarAfterWrite(accountID: String) async {
        do { try await loadCalendarCache(accountID: accountID) }
        catch { errorMessage = "Calendar change saved, but the local view could not refresh: \(error.localizedDescription)" }
    }
    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }
    private func notifyBubbles(_ threads: [MailThread]) async {
        guard bubbleNotifications else { return }
        for thread in threads where thread.accountID == account?.id {
            let content = UNMutableNotificationContent()
            content.title = "Bubbled up"; content.body = thread.subject
            let request = UNNotificationRequest(identifier: "bubble-\(thread.id)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
    private func configureLoginItem() async {
        do {
            // Debug builds in DerivedData would otherwise register themselves as login items.
            let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
            if launchAtLogin && installed && SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
            else if !launchAtLogin && SMAppService.mainApp.status != .notRegistered { try await SMAppService.mainApp.unregister() }
        } catch { reportError(error) }
    }
}

enum AppError: LocalizedError {
    case signInRequired, messageNoLongerAvailable, draftStorageUnavailable
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in with Google to continue."
        case .messageNoLongerAvailable: "This message is no longer available. Reopen the thread before composing a reply or draft."
        case .draftStorageUnavailable: "The draft could not be saved locally. Keep the app open and try again."
        }
    }
}
/// "Sent" with a link to the sent copy, shown briefly after Gmail confirms a pending email.
struct SentConfirmation: Equatable {
    var subject: String
    var threadID: String
    var id = UUID()
}

enum RefreshProgress {
    case running, updated
}
#endif
