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
        didSet { if navigation != oldValue { poweringThrough = false } }
    }
    var selectedThreadID: String?
    /// The thread shown as a full page; nil shows the mailbox list.
    var openThreadID: String?
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
    var isSearching = false
    var searchNextPageToken: String?
    var isSigningIn = false
    var errorMessage: String?
    var undoMessage: String?
    var lastSyncedAt: Date?
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
    /// Demo mode runs the real services against an in-process fake Google. It is on until a
    /// Google client ID is configured, or can be forced with the EC_MOCK=1/0 environment variable.
    let isDemoMode: Bool
    @ObservationIgnored private let mockBackend: MockGoogleBackend?
    @ObservationIgnored private let database: LocalStore?
    @ObservationIgnored private let mail: MailService?
    @ObservationIgnored private let calendarService: CalendarService?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isResettingDemo = false
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var undoID: UUID?
    private var cachedThreads: [MailThread] = []
    @ObservationIgnored private var replacingComposition = false
    @ObservationIgnored private var mailSnapshotOrder = MailSnapshotOrder()
    private var senderRuleIndex = SenderRuleIndex()
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
        let forced = ProcessInfo.processInfo.environment["EC_MOCK"]
        isDemoMode = forced.map { $0 == "1" } ?? ((try? GoogleOAuthConfiguration.fromBundle()) == nil)
        do {
            let local: LocalStore
            let api: GoogleAPI
            if isDemoMode {
                // EC_DEMO_DIR keeps throwaway renders and experiments away from the real demo data.
                let mockFile = ProcessInfo.processInfo.environment["EC_DEMO_DIR"]
                    .map { URL(fileURLWithPath: $0).appendingPathComponent("google.json") } ?? MockGoogleBackend.defaultFileURL()
                let cacheFile = mockFile?.deletingLastPathComponent().appendingPathComponent("cache.sqlite")
                if defaults.bool(forKey: "resetDemoDataOnLaunch"), let mockFile, let cacheFile {
                    defaults.removeObject(forKey: "resetDemoDataOnLaunch")
                    for file in [mockFile, cacheFile] {
                        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
                    }
                }
                let backend = MockGoogleBackend(fileURL: mockFile)
                mockBackend = backend
                local = try LocalStore(url: cacheFile)
                api = GoogleAPI(auth: MockTokenProvider(), session: MockGoogleURLProtocol.session(backend: backend))
            } else {
                mockBackend = nil
                local = try LocalStore()
                api = GoogleAPI(auth: auth)
            }
            database = local
            mail = MailService(api: api, store: local)
            calendarService = CalendarService(api: api, store: local)
        } catch {
            database = nil; mail = nil; calendarService = nil
            errorMessage = error.localizedDescription
        }
    }

    static let demoAccount = Account(id: MockGoogleBackend.accountEmail, email: MockGoogleBackend.accountEmail,
                                     displayName: MockGoogleBackend.accountName)

    /// Demo mode: drop a new email into the fake inbox, as if it just arrived.
    func simulateIncomingMail() async {
        guard let mockBackend else { return }
        mockBackend.simulateIncomingMail()
        await refresh()
    }

    /// Demo mode: start over with fresh seed data, relative to today.
    func resetDemoData() {
        guard isDemoMode, !isResettingDemo else { return }
        isResettingDemo = true
        let previousAccount = account
        account = nil
        composition?.session.cancel()
        UserDefaults.standard.set(true, forKey: "resetDemoDataOnLaunch")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let bundle = Bundle.main.bundleURL
        Task {
            defer { isResettingDemo = false }
            await mail?.cancelAllOperations()
            await calendarService?.cancelAllOperations()
            do {
                try await ApplicationRestart.perform(launch: {
                    _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
                }, terminate: { NSApp.terminate(nil) })
            } catch {
                UserDefaults.standard.removeObject(forKey: "resetDemoDataOnLaunch")
                account = previousAccount
                composition?.session.resume()
                await loadCache()
                reportError(error)
            }
        }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        account = isDemoMode ? Self.demoAccount : auth.account
        if !isDemoMode, let error = auth.restorationError { errorMessage = error }
        if !isDemoMode, account == nil, auth.isSignedIn, let database {
            do { account = try await database.metadata(Account.self, key: "activeAccount", accountID: "app") }
            catch { reportError(error) }
        }
        await loadCache()
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
        guard !isSigningIn, !isDemoMode else { return }
        isSigningIn = true
        do {
            account = try await auth.signIn()
            if let account, let database {
                try await database.setMetadata(account, key: "activeAccount", accountID: "app")
            }
        } catch { isSigningIn = false; reportError(error); return }
        isSigningIn = false
        await loadCache()
        if bubbleNotifications { await requestNotificationPermission() }
        await refresh()
    }

    func signOut() async {
        guard !isSigningIn, !isDemoMode else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        // Stop new UI and polling work before draining operations tied to these credentials.
        composition?.session.cancel(); composition = nil
        account = nil; threads = []; cachedThreads = []; senderRules = []; remoteImageSenders = []
        calendars = []; events = []; selectedThreadID = nil; selectedEventID = nil; openThreadID = nil; poweringThrough = false
        searchTask?.cancel(); searchTask = nil; searchGeneration += 1; searchNextPageToken = nil; isSearching = false
        searchQuery = ""; undoMessage = nil; undoID = nil; undoTask?.cancel()
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

    func refresh() async {
        guard !isRefreshing, let account, let mail, let calendarService else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Independent services let the calendar appear while sent-history seeding is still running.
        let progress: @Sendable (MailSnapshot) async -> Void = { [weak self] snapshot in
            await self?.publishMailProgress(snapshot, accountID: account.id)
        }
        let mailTask = Task { try await mail.sync(account: account, progress: progress) }
        let calendarTask = Task { try await calendarService.sync(accountID: account.id) }
        do {
            try await calendarTask.value
            if self.account?.id == account.id { try await loadCalendarCache(accountID: account.id) }
        } catch { reportError(error) }
        do {
            let snapshot = try await mailTask.value
            guard self.account?.id == account.id else { return }
            apply(snapshot)
            let surfaced = try await mail.processDueBubbles(account: account)
            if !surfaced.isEmpty {
                try await loadMailCache(accountID: account.id)
                await notifyBubbles(surfaced)
            }
            lastSyncedAt = .now
        } catch { reportError(error) }
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
        let generation = searchGeneration
        searchTask?.cancel(); searchTask = nil
        searchNextPageToken = nil; isSearching = false
        searchQuery = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchQuery = ""; threads = cachedThreads; return
        }
        guard let account, let mail else { return }
        do {
            isSearching = true
            defer { if generation == searchGeneration { isSearching = false; searchTask = nil } }
            let task = Task { try await mail.searchPage(query: query, account: account) }
            searchTask = task
            let result = try await task.value
            guard generation == searchGeneration, self.account?.id == account.id else { return }
            threads = acceptSearchPage(result, accountID: account.id); searchNextPageToken = result.nextPageToken
        } catch { if generation == searchGeneration { reportError(error) } }
    }

    func loadMoreSearch() async {
        guard !isSearching, let token = searchNextPageToken, let mail, let account else { return }
        let generation = searchGeneration, query = searchQuery
        isSearching = true
        defer { if generation == searchGeneration { isSearching = false; searchTask = nil } }
        do {
            let task = Task { try await mail.searchPage(query: query, pageToken: token, account: account) }
            searchTask = task
            let page = try await task.value
            guard generation == searchGeneration, self.account?.id == account.id else { return }
            let existing = Set(threads.map(\.id))
            threads += acceptSearchPage(page, accountID: account.id).filter { !existing.contains($0.id) }
            searchNextPageToken = page.nextPageToken
        } catch { if generation == searchGeneration { reportError(error) } }
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

    /// Search membership can change while reading a thread; the open page still follows its cache.
    var openThread: MailThread? {
        guard let openThreadID else { return nil }
        return threads.first { $0.id == openThreadID } ?? cachedThreads.first { $0.id == openThreadID }
    }

    func replaceComposition(with next: MailComposition) {
        guard !replacingComposition, composition?.session.isSending != true else { return }
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
            if labels.contains("TRASH") || labels.contains("SPAM") { return false }
            switch mailbox {
            case .imbox:
                let sender = thread.messages.filter { $0.from.email.lowercased() != accountEmail.lowercased() }.max { $0.date < $1.date }?.from.email ?? thread.sender.email
                return labels.contains("INBOX") && decision(for: sender) == .approved
            case .setAside: return labels.contains("HEY/Set Aside")
            case .bubbleUp: return labels.contains("HEY/Bubble Up")
            case .screener: return labels.contains("HEY/Screener")
            case .screenedOut: return labels.contains("HEY/Screened Out")
            case .sent: return labels.contains("SENT")
            case .drafts: return labels.contains("DRAFT")
            case .allMail: return true
            case .calendar: return false
            }
        }
        return result.sorted {
            if mailbox == .imbox {
                return max($0.bubbledAt ?? .distantPast, $0.updatedAt) > max($1.bubbledAt ?? .distantPast, $1.updatedAt)
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func open(_ thread: MailThread) {
        selectedThreadID = thread.id
        openThreadID = thread.id
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
        do {
            for thread in threads where thread.unread && thread.accountID == account.id {
                _ = try await mail.markUnread(threadID: thread.id, unread: false, account: account)
            }
            if self.account?.id == account.id { try await loadMailCache(accountID: account.id) }
        } catch { reportError(error) }
        endPowerThrough()
    }

    func decision(for sender: String) -> ScreeningDecision? {
        let address = sender.lowercased()
        if address == accountEmail.lowercased() { return .approved }
        return senderRuleIndex.rule(for: address)?.decision
    }

    func archive(_ thread: MailThread) async {
        guard account?.id == thread.accountID else { return }
        await performMailAction { mail, account in try await mail.archive(threadID: thread.id, account: account) }
    }
    func trash(_ thread: MailThread) async {
        guard account?.id == thread.accountID else { return }
        await performMailAction { mail, account in try await mail.trash(threadID: thread.id, account: account) }
    }
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
    func decideSender(key: String, decision: ScreeningDecision) async {
        await performMailAction { mail, account in
            try await mail.decide(sender: key, decision: decision, domain: key.hasPrefix("@"), account: account)
        }
    }
    func undo() async {
        guard let undoID, let account, let mail else { return }
        do {
            try await mail.undo(tokenID: undoID, account: account)
            self.undoID = nil; undoMessage = nil; undoTask?.cancel()
            try await loadMailCache(accountID: account.id)
        } catch { reportError(error) }
    }
    func saveDraft(_ outgoing: OutgoingMessage) async throws -> OutgoingMessage {
        guard let account, let mail else { throw AppError.signInRequired }
        let result = try await mail.saveDraft(outgoing, account: account)
        do { try await loadMailCache(accountID: account.id) }
        catch { errorMessage = "Draft saved to Gmail, but the local view could not refresh: \(error.localizedDescription)" }
        return result
    }
    func send(_ outgoing: OutgoingMessage) async throws {
        guard let account, let mail else { throw AppError.signInRequired }
        let receipt = try await mail.send(outgoing, account: account)
        if let warning = receipt.warning { errorMessage = warning }
        do { try await loadMailCache(accountID: account.id) }
        catch { errorMessage = "Message sent, but the local view could not refresh: \(error.localizedDescription)" }
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
    func respondToEvent(_ event: CalendarEvent, response: AttendanceStatus) async -> Bool {
        guard let calendarService, account?.id == event.accountID else { return false }
        do { _ = try await calendarService.respond(to: event, status: response); await reloadCalendarAfterWrite(accountID: event.accountID); return true }
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
    func reportError(_ error: any Error) {
        if error is CancellationError { return }
        errorMessage = error.localizedDescription
        if !isDemoMode && account != nil && !auth.isSignedIn {
            account = nil; threads = []; cachedThreads = []; calendars = []; events = []
            senderRules = []; remoteImageSenders = []; selectedThreadID = nil
        }
    }

    private func performMailAction(_ action: (MailService, Account) async throws -> MailUndoToken) async {
        guard let mail, let account else { return }
        do {
            let token = try await action(mail, account)
            guard self.account?.id == account.id else { return }
            undoID = token.id; undoMessage = token.message
            undoTask?.cancel()
            undoTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.undoMessage = nil; self?.undoID = nil
            }
            try await loadMailCache(accountID: account.id)
        } catch { reportError(error) }
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
        } catch { reportError(error) }
    }
    private func loadMailCache(accountID: String) async throws {
        guard account?.id == accountID else { return }
        if let mail {
            let before = Dictionary(threads.map { ($0.id, $0.labels) }, uniquingKeysWith: { _, latest in latest })
            let snapshot = try await mail.cached(accountID: accountID)
            if account?.id == accountID { apply(snapshot) }
            let query = searchQuery, generation = searchGeneration
            if !query.isEmpty, let account, account.id == accountID {
                let changed = threads.filter { before[$0.id] != $0.labels }
                for thread in changed {
                    let matches = try await mail.matchesSearch(thread, query: query, account: account)
                    guard generation == searchGeneration, self.account?.id == accountID else { return }
                    if !matches { threads.removeAll { $0.id == thread.id } }
                }
            }
        }
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
    case signInRequired, messageNoLongerAvailable
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in with Google to continue."
        case .messageNoLongerAvailable: "This message is no longer available. Reopen the thread before composing a reply or draft."
        }
    }
}
#endif
