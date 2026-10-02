#if os(macOS)
import AppKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class AppStore {
    var account: Account?
    var threads: [MailThread] = []
    var senderRules: [SenderRule] = []
    var remoteImageSenders: Set<String> = []
    var calendars: [CalendarRecord] = []
    var events: [CalendarEvent] = []
    var navigation: Mailbox = .imbox
    var selectedThreadID: String?
    var selectedEventID: String?
    var searchQuery = ""
    var isRefreshing = false
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
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    @ObservationIgnored private var undoID: UUID?
    @ObservationIgnored private var cachedThreads: [MailThread] = []
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored var openWindow: (() -> Void)?
    @ObservationIgnored var showOverlay: (() -> Void)?

    init() {
        auth = GoogleAuth()
        let defaults = UserDefaults.standard
        overlayHeight = defaults.object(forKey: "overlayHeight") as? Double ?? 0.25
        bubbleNotifications = defaults.object(forKey: "bubbleNotifications") as? Bool ?? true
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        let forced = ProcessInfo.processInfo.environment["EC_MOCK"]
        isDemoMode = forced.map { $0 == "1" } ?? ((try? GoogleOAuthConfiguration.fromBundle()) == nil)
        do {
            let local: LocalStore
            let api: GoogleAPI
            if isDemoMode {
                let mockFile = MockGoogleBackend.defaultFileURL()
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
        guard isDemoMode else { return }
        UserDefaults.standard.set(true, forKey: "resetDemoDataOnLaunch")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let bundle = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
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
        account = nil; threads = []; cachedThreads = []; senderRules = []; remoteImageSenders = []
        calendars = []; events = []; selectedThreadID = nil; selectedEventID = nil
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
        let mailTask = Task { try await mail.sync(account: account) }
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

    func search(_ query: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        searchQuery = query
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            threads = cachedThreads; return
        }
        guard let account, let mail else { return }
        do {
            let result = try await mail.search(query: query, account: account)
            guard generation == searchGeneration, self.account?.id == account.id else { return }
            threads = result
        } catch { reportError(error) }
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

    func decision(for sender: String) -> ScreeningDecision? {
        let address = sender.lowercased()
        if address == accountEmail.lowercased() { return .approved }
        if let exact = senderRules.first(where: { !$0.isDomain && $0.key == address }) { return exact.decision }
        guard let domain = address.split(separator: "@").last else { return nil }
        return senderRules.first { $0.key == "@\(domain)" }?.decision
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
            if self.account?.id == account.id && !searchQuery.isEmpty { await search(searchQuery) }
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
            if self.account?.id == account.id && !searchQuery.isEmpty { await search(searchQuery) }
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
    func saveEvent(_ event: CalendarEvent, scope: EventEditScope = .thisEvent, originalCalendarID: String? = nil) async -> Bool {
        guard let calendarService, account?.id == event.accountID else { return false }
        do {
            if event.id.isEmpty { _ = try await calendarService.create(event) }
            else {
                let oldCalendar = originalCalendarID ?? events.first { $0.cacheID == event.cacheID }?.calendarID
                _ = try await calendarService.update(event, originalCalendarID: oldCalendar, scope: scope)
            }
            await reloadCalendarAfterWrite(accountID: event.accountID)
            return true
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
            if self.account?.id == account.id && !searchQuery.isEmpty { await search(searchQuery) }
        } catch { reportError(error) }
    }
    private func apply(_ snapshot: MailSnapshot) {
        cachedThreads = snapshot.threads
        if searchQuery.isEmpty { threads = snapshot.threads }
        else {
            let updated = Dictionary(snapshot.threads.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            threads = threads.compactMap { updated[$0.id] }
        }
        senderRules = snapshot.rules; remoteImageSenders = snapshot.remoteImageSenders
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
            let snapshot = try await mail.cached(accountID: accountID)
            if account?.id == accountID { apply(snapshot) }
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
    case signInRequired
    var errorDescription: String? { "Sign in with Google to continue." }
}
#endif
