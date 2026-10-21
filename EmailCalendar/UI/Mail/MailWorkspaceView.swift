#if os(macOS)
import AppKit
import SwiftUI

/// Mail is a list page, the Power Through stack, or one thread as a full page. Sheets and keys for all live here.
struct MailRootView: View {
    @Environment(AppStore.self) private var store
    var searchFocus: () -> Void
    private var composition: MailComposition? {
        get { store.composition }
        nonmutating set {
            if let newValue { store.replaceComposition(with: newValue) }
            else { store.composition = nil }
        }
    }
    @State private var bubbleThread: MailThread?
    @State private var showsScreenedSenders = false
    @State private var showsPalette = false
    @State private var showsMore = false
    @State private var pendingCommand: MailPaletteCommand?
    @State private var loadingComposition = false
    @State private var powerFocusID: String?
    @State private var powerScrollRequest: String?

    private var mailbox: Mailbox { store.navigation }
    private var threads: [MailThread] { store.visibleThreads(mailbox: mailbox) }
    private var openThread: MailThread? { store.openThread }
    private var isPowerStack: Bool { store.poweringThrough && openThread == nil }
    private var powerThreads: [MailThread] { store.newForYou }
    /// The list row the keyboard points at, the Power Through card in view, or the open thread.
    private var focused: MailThread? {
        if let openThread { return openThread }
        if isPowerStack { return powerThreads.first { $0.id == powerFocusID } ?? powerThreads.first }
        return threads.first { $0.id == store.selectedThreadID }
    }
    private func replyMessage(_ thread: MailThread?) -> MailMessage? {
        thread?.messages.filter { !$0.labels.contains("DRAFT") && $0.draftID == nil }.max { $0.date < $1.date }
    }
    private func draftMessage(_ thread: MailThread?) -> MailMessage? {
        thread?.messages.filter { $0.labels.contains("DRAFT") || $0.draftID != nil }.max { $0.date < $1.date }
    }

    var body: some View {
        Group {
            if let composition {
                MailComposerView(composition: composition) {
                    if self.composition?.id == composition.id { self.composition = nil }
                }
                    .id(composition.id)
            } else if let openThread {
                MailThreadView(thread: openThread, compose: compose, bubble: { bubbleThread = openThread },
                               act: { action in perform(action, on: openThread) }, showsMore: $showsMore)
                    .id(openThread.id)
            } else if store.poweringThrough {
                PowerThroughPage(threads: powerThreads, focusedID: $powerFocusID, scrollRequest: $powerScrollRequest,
                                 compose: compose, bubble: { bubbleThread = $0 }, act: { thread, action in perform(action, on: thread) })
            } else {
                MailboxPage(mailbox: mailbox, threads: threads, compose: { composition = .newMessage },
                            bubble: { bubbleThread = $0 }, showsScreenedSenders: $showsScreenedSenders)
            }
        }
        .overlay(alignment: .bottom) {
            if let text = store.undoMessage {
                HStack(spacing: 16) {
                    Text(text).foregroundStyle(.white)
                    Button("Undo") { Task { await store.undo() } }.buttonStyle(QuietButtonStyle()).fontWeight(.semibold)
                        .foregroundStyle(Theme.back)
                }
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Theme.actionBar, in: Capsule()).shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .padding(.bottom, openThread == nil ? 86 : 96)
                .transition(.opacity)
            }
        }
        .overlay {
            if loadingComposition {
                ProgressView("Preparing message…").padding(24).background(Theme.raised, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .background(MailKeyboardMonitor(enabled: composition == nil && bubbleThread == nil && !showsScreenedSenders && !showsPalette && !loadingComposition,
                                        handle: handleKey).frame(width: 0, height: 0))
        .sheet(item: $bubbleThread) { thread in
            BubbleUpPicker { date in
                Task {
                    await store.bubbleUp(thread, date)
                    store.advanceAfterAction(from: thread.id)
                }
            }
        }
        .sheet(isPresented: $showsScreenedSenders) { ScreenedSendersView().environment(store) }
        .sheet(isPresented: $showsPalette, onDismiss: {
            let command = pendingCommand; pendingCommand = nil; command?.perform()
        }) {
            MailCommandPalette(commands: commands) { pendingCommand = $0 }.environment(store)
        }
        .onChange(of: store.composeRequest, initial: true) { _, request in
            if request != nil { composition = .newMessage; store.composeRequest = nil }
        }
        .onChange(of: threads.map(\.id)) { oldIDs, newIDs in
            guard let current = store.selectedThreadID, !newIDs.contains(current) else { return }
            let oldIndex = oldIDs.firstIndex(of: current) ?? 0
            store.selectedThreadID = newIDs.isEmpty ? nil : newIDs[min(oldIndex, newIDs.count - 1)]
        }
    }

    enum ThreadAction { case archive, setAside, trash, toggleRead, seen, moveToTodo, link }

    private func perform(_ action: ThreadAction, on thread: MailThread) {
        Task {
            switch action {
            case .archive: await store.archive(thread)
            case .setAside: await store.toggleSetAside(thread)
            case .trash: await store.trash(thread)
            case .toggleRead: await store.setRead(thread, thread.unread); return
            case .seen: await store.setRead(thread, true)
            case .moveToTodo: await store.moveToTodo(thread); return
            case .link: store.startLinking(thread); return
            }
            store.advanceAfterAction(from: thread.id)
        }
    }

    private func compose(_ message: MailMessage, _ action: MailComposeAction) {
        guard !loadingComposition else { return }
        loadingComposition = true
        let accountID = store.account?.id
        Task {
            defer { loadingComposition = false }
            do {
                let message = try await store.fullMessage(message)
                guard store.account?.id == accountID, message.accountID == accountID else { return }
                switch action {
                case .reply: composition = .reply(to: message, accountEmail: store.accountEmail, all: false)
                case .replyAll: composition = .reply(to: message, accountEmail: store.accountEmail, all: true)
                case .forward, .editDraft:
                    var request = action == .forward ? MailComposition.forward(message) : MailComposition.draft(message)
                    for attachment in message.attachments {
                        let data = try await store.attachmentData(attachment, message: message)
                        request.message.attachments.append(OutgoingAttachment(name: attachment.name, mimeType: attachment.mimeType, data: data))
                    }
                    guard store.account?.id == accountID else { return }
                    composition = request
                }
            } catch { store.reportError(error) }
        }
    }

    private func moveSelection(_ offset: Int) {
        if isPowerStack {
            guard !powerThreads.isEmpty else { return }
            let current = powerThreads.firstIndex { $0.id == focused?.id } ?? 0
            let target = powerThreads[min(max(current + offset, 0), powerThreads.count - 1)].id
            powerFocusID = target; powerScrollRequest = target
            return
        }
        guard !threads.isEmpty else { return }
        let current = threads.firstIndex { $0.id == (store.openThreadID ?? store.selectedThreadID) }
        let target = current.map { min(max($0 + offset, 0), threads.count - 1) } ?? (offset > 0 ? 0 : threads.count - 1)
        if store.openThreadID != nil { store.open(threads[target]) } else { store.selectedThreadID = threads[target].id }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command && character == "k" { showsPalette = true; return true }
        if modifiers == .command && character == "z", store.undoMessage != nil { Task { await store.undo() }; return true }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53 {
            if store.linkingThreadID != nil { store.cancelLinking(); return true }
            if store.openThreadID != nil { store.closeThread(); return true }
            if store.poweringThrough { store.endPowerThrough(); return true }
            if mailbox != .imbox { store.navigation = .imbox; return true }
            return false
        }
        // ← / → slide the drawers: Days on the left, To-do on the right.
        if event.keyCode == 123 || event.keyCode == 124 {
            withAnimation(MailWorkspace.settle) { store.slideDrawers(event.keyCode == 123 ? 1 : -1) }
            return true
        }
        switch character {
        case "t": if let focused { perform(.moveToTodo, on: focused) }
        case "l": if let focused { perform(.link, on: focused) }
        case "+", "=": store.focusTodoField()
        case "j": moveSelection(1)
        case "k": moveSelection(-1)
        case "c": composition = .newMessage
        case "/": searchFocus()
        case "\r", "o":
            if isPowerStack { if let focused { store.open(focused) } }
            else if store.openThreadID == nil {
                if let focused { mailbox == .drafts && draftMessage(focused) != nil ? compose(draftMessage(focused)!, .editDraft) : store.open(focused) }
                else { moveSelection(1) }
            }
        case "e": if let focused { perform(.archive, on: focused) }
        case "s" where isPowerStack: if let focused { perform(.seen, on: focused) }
        case "a", "s": if let focused { perform(.setAside, on: focused) }
        case "z", "b": if let focused { bubbleThread = focused }
        case "r": if let message = replyMessage(focused) { compose(message, .reply) }
        case "f": if let message = replyMessage(focused) { compose(message, .forward) }
        case "m": if store.openThreadID != nil { showsMore.toggle() } else { return false }
        case "p": if store.openThreadID == nil, mailbox == .imbox, !store.poweringThrough { store.powerThroughNew() } else { return false }
        default: return false
        }
        return true
    }

    private var commands: [MailPaletteCommand] {
        var result = [
            MailPaletteCommand(title: "Write a new email", symbol: "square.and.pencil", shortcut: "c") { composition = .newMessage },
            MailPaletteCommand(title: "Search mail", symbol: "magnifyingglass", shortcut: "/") { searchFocus() },
            MailPaletteCommand(title: "Power through new mail", symbol: "bolt", shortcut: "p") { store.navigation = .imbox; store.powerThroughNew() },
            MailPaletteCommand(title: "Refresh mail and calendar", symbol: "arrow.clockwise", shortcut: "") { Task { await store.refresh() } },
            MailPaletteCommand(title: "Show the next seven days", symbol: "calendar", shortcut: "←") { store.drawerPosition = 1 },
            MailPaletteCommand(title: "Show to-dos", symbol: "checklist", shortcut: "→") { store.drawerPosition = -1 },
            MailPaletteCommand(title: "Add a to-do", symbol: "plus", shortcut: "+") { store.focusTodoField() },
            MailPaletteCommand(title: "Manage screened senders", symbol: "person.crop.circle", shortcut: "") { showsScreenedSenders = true }
        ]
        for mailbox in Mailbox.allCases {
            result.append(MailPaletteCommand(title: "Go to \(mailbox.title)", symbol: mailbox.symbol, shortcut: "") { store.navigation = mailbox })
        }
        if let selected = focused {
            result += [
                MailPaletteCommand(title: "Archive thread", symbol: "archivebox", shortcut: "e") { perform(.archive, on: selected) },
                MailPaletteCommand(title: "Move thread to Trash", symbol: "trash", shortcut: "") { perform(.trash, on: selected) },
                MailPaletteCommand(title: selected.isSetAside ? "Return thread to Imbox" : "Set thread aside", symbol: "pin", shortcut: "a") { perform(.setAside, on: selected) },
                MailPaletteCommand(title: "Bubble Up thread", symbol: "bubbles.and.sparkles", shortcut: "z") { bubbleThread = selected },
                MailPaletteCommand(title: "Move to To-do", symbol: "checklist", shortcut: "t") { perform(.moveToTodo, on: selected) },
                MailPaletteCommand(title: "Link to an event or to-do", symbol: "link", shortcut: "l") { perform(.link, on: selected) },
                MailPaletteCommand(title: selected.unread ? "Mark thread read" : "Mark thread unread", symbol: "envelope", shortcut: "") { perform(.toggleRead, on: selected) }
            ]
            if let message = replyMessage(selected) {
                result += [
                    MailPaletteCommand(title: "Reply", symbol: "arrowshape.turn.up.left", shortcut: "r") { compose(message, .reply) },
                    MailPaletteCommand(title: "Reply all", symbol: "arrowshape.turn.up.left.2", shortcut: "") { compose(message, .replyAll) },
                    MailPaletteCommand(title: "Forward", symbol: "arrowshape.turn.up.right", shortcut: "f") { compose(message, .forward) }
                ]
            }
            if let message = draftMessage(selected) { result.append(MailPaletteCommand(title: "Edit draft", symbol: "square.and.pencil", shortcut: "↩") { compose(message, .editDraft) }) }
        }
        if isPowerStack, !powerThreads.isEmpty {
            let stack = powerThreads
            result.append(MailPaletteCommand(title: "Mark all as seen", symbol: "eye", shortcut: "") { Task { await store.markAllSeen(stack) } })
        }
        if store.undoMessage != nil { result.append(MailPaletteCommand(title: "Undo last action", symbol: "arrow.uturn.backward", shortcut: "⌘Z") { Task { await store.undo() } }) }
        return result
    }
}

/// A mailbox as a centered card: big title, then rows. The Imbox splits new from seen.
private struct MailboxPage: View {
    @Environment(AppStore.self) private var store
    var mailbox: Mailbox
    var threads: [MailThread]
    var compose: () -> Void
    var bubble: (MailThread) -> Void
    @Binding var showsScreenedSenders: Bool

    private var isSearch: Bool { !store.searchQuery.isEmpty }
    private var setAside: [MailThread] {
        store.visibleThreads(mailbox: .setAside).sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    header.padding(.top, 28).padding(.bottom, 18)
                    content
                    if isSearch {
                        if store.isSearching { ProgressView("Searching…").padding() }
                        else if store.searchNextPageToken != nil {
                            Button("Load more results") { Task { await store.loadMoreSearch() } }
                                .buttonStyle(QuietButtonStyle()).padding()
                        }
                    }
                    Spacer(minLength: 110)
                }
                .padding(.horizontal, 40)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: 790)
            .background(Theme.card, in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            if mailbox == .imbox && !isSearch, let latest = setAside.first {
                SetAsidePile(latest: latest, count: setAside.count) { store.navigation = .setAside }.padding(.bottom, 22)
            }
        }
    }

    @ViewBuilder private var header: some View {
        if isSearch {
            PageTitle(title: "Search", subtitle: "Results for “\(store.searchQuery)”", ruled: true)
        } else {
            switch mailbox {
            case .imbox:
                ZStack(alignment: .topTrailing) {
                    PageTitle(title: "Imbox").frame(maxWidth: .infinity)
                    Button(action: compose) { Label("Write", systemImage: "plus") }
                        .buttonStyle(PillButtonStyle(fill: Theme.accent)).help("Write a new email (c)")
                        .offset(x: 16, y: -12)
                }
            case .screener:
                PageTitle(title: "The Screener", subtitle: "These people want to email you for the first time. Do you want to hear from them?", ruled: true)
            default:
                PageTitle(title: mailbox.title, subtitle: subtitle, ruled: true)
            }
        }
    }

    private var subtitle: String? {
        switch mailbox {
        case .setAside: "Everything you’ve marked as Set Aside."
        case .bubbleUp: "Mail that will bubble back up to the top of your Imbox."
        case .screenedOut: "Mail from senders you said no to. They never reach your Imbox."
        case .sent: "Everything you’ve sent."
        case .drafts: "Emails you started but haven’t sent yet."
        case .allMail: "Every email, in one place."
        default: nil
        }
    }

    @ViewBuilder private var content: some View {
        if mailbox == .screener && !isSearch {
            MailScreenerView(threads: threads) { store.open($0) }
            Button("Manage screened senders…") { showsScreenedSenders = true }
                .buttonStyle(QuietButtonStyle()).font(.callout).foregroundStyle(Theme.secondary).padding(.top, 18)
        } else if threads.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: isSearch ? "magnifyingglass" : mailbox.symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.secondary)
                Text(emptyText).font(.callout).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }.padding(.top, 40)
        } else if mailbox == .imbox && !isSearch {
            let fresh = threads.filter(\.unread)
            let seen = threads.filter { !$0.unread }
            if !fresh.isEmpty {
                SectionRule(title: "NEW FOR YOU") {
                    Button { store.powerThroughNew() } label: { Label("Power Through New", systemImage: "bolt.fill") }
                        .buttonStyle(OutlinePillStyle()).help("Read all new mail on one page (p)")
                }
                rows(fresh)
            }
            if !seen.isEmpty {
                SectionRule(title: "PREVIOUSLY SEEN").padding(.top, fresh.isEmpty ? 0 : 26)
                rows(seen)
            }
        } else {
            rows(threads)
        }
    }

    private var emptyText: String {
        if isSearch { return "Nothing matches. Try a name, a word, or from:person@example.com." }
        switch mailbox {
        case .imbox: return "You’re all caught up.\nNew senders wait in the Screener until you say yes."
        case .setAside: return "Nothing set aside. Press a on an email to keep it handy here."
        case .bubbleUp: return "Nothing scheduled. Press z on an email to bring it back later."
        case .drafts: return "No drafts."
        case .screenedOut: return "Nobody screened out yet."
        default: return "Nothing here."
        }
    }

    private func rows(_ threads: [MailThread]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(threads) { thread in
                MailThreadRow(thread: thread, mailbox: mailbox, isFocused: store.selectedThreadID == thread.id,
                              isLinked: store.isLinked(thread.id))
                    .onTapGesture { store.open(thread) }
                    .draggableThread(thread)
                    .contextMenu {
                        Button("Move to To-do") { Task { await store.moveToTodo(thread) } }
                        Button("Link to an Event or To-do…") { store.startLinking(thread) }
                        Divider()
                        Button("Archive") { Task { await store.archive(thread) } }
                        Button(thread.unread ? "Mark read" : "Mark unread") { Task { await store.setRead(thread, thread.unread) } }
                        Button(thread.isSetAside ? "Return to Imbox" : "Set Aside") { Task { await store.toggleSetAside(thread) } }
                        Button("Bubble Up…") { bubble(thread) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { Task { await store.trash(thread) } }
                    }
            }
        }
    }
}

private struct SectionRule<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text.opacity(0.9)).fixedSize()
            Rectangle().fill(Theme.rule).frame(height: 1)
            accessory
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }
}

private struct OutlinePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.rule)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .overlay(Capsule().stroke(Theme.rule, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1).contentShape(Capsule())
    }
}

struct MailThreadRow: View {
    var thread: MailThread
    var mailbox: Mailbox
    var isFocused = false
    /// Attached to an event or to-do.
    var isLinked = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(thread.unread ? Theme.unread : .clear).frame(width: 6, height: 6)
            Avatar(name: personName, key: personKey)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if thread.bubbledAt != nil && mailbox == .imbox {
                        Image(systemName: "bubbles.and.sparkles.fill").font(.system(size: 11)).foregroundStyle(Theme.unread)
                    }
                    Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                        .font(.system(size: 15, weight: thread.unread ? .semibold : .regular)).lineLimit(1)
                    if thread.messages.count > 2 { Text("(\(thread.messages.count))").font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                    if thread.messages.contains(where: { !$0.attachments.isEmpty }) {
                        Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    if isLinked {
                        Image(systemName: "link").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .help("Linked to an event or to-do")
                    }
                }
                Text("\(personLabel) – \(thread.snippet)").font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(trailing).font(.system(size: 12.5)).foregroundStyle(thread.bubbleUpAt != nil ? Theme.unread : Theme.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 9)
        .background(hovering || isFocused ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var isOutgoing: Bool { mailbox == .sent || mailbox == .drafts }
    private var recipient: MailAddress? { thread.latestMessage?.to.first }
    private var personName: String { isOutgoing ? (recipient?.displayName ?? "?") : thread.sender.displayName }
    private var personKey: String { isOutgoing ? (recipient?.email ?? "") : thread.sender.email }
    private var personLabel: String {
        if isOutgoing { return "To \(thread.latestMessage?.to.map(\.displayName).joined(separator: ", ") ?? "nobody")" }
        return thread.sender.displayName
    }
    private var trailing: String {
        if let due = thread.bubbleUpAt { return "Back \(Theme.shortDate(due))" }
        return Theme.shortDate(thread.updatedAt)
    }
}

/// The Set Aside stack pinned to the bottom of the Imbox.
private struct SetAsidePile: View {
    var latest: MailThread
    var count: Int
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill").rotationEffect(.degrees(45)).foregroundStyle(Theme.secondary)
                HStack(spacing: 8) {
                    Avatar(name: latest.sender.displayName, key: latest.sender.email, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(latest.subject).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(latest.sender.displayName).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }.frame(maxWidth: 170, alignment: .leading)
                    if count > 1 {
                        Text("+\(count - 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10).offset(x: 3, y: -3))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Set Aside (\(count))")
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}
#endif
