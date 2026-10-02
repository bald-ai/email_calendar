#if os(macOS)
import AppKit
import SwiftUI

struct MailWorkspaceView: View {
    @Environment(AppStore.self) private var store
    var mailbox: Mailbox
    @State private var query = ""
    @State private var composition: MailComposition?
    @State private var bubbleThread: MailThread?
    @State private var showsScreenedSenders = false
    @State private var showsPalette = false
    @State private var pendingCommand: MailPaletteCommand?
    @State private var loadingComposition = false
    @FocusState private var searchFocused: Bool

    private var threads: [MailThread] { store.visibleThreads(mailbox: mailbox) }
    private var selected: MailThread? { threads.first { $0.id == store.selectedThreadID } }
    private var replyMessage: MailMessage? {
        selected?.messages.filter { !$0.labels.contains("DRAFT") && $0.draftID == nil }.max { $0.date < $1.date }
    }
    private var draftMessage: MailMessage? {
        selected?.messages.filter { $0.labels.contains("DRAFT") || $0.draftID != nil }.max { $0.date < $1.date }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(mailbox.title).font(.title2.weight(.semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Gmail", text: $query).textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit { searchFocused = false; Task { await store.search(query) } }
                        .onKeyPress(.escape) { searchFocused = false; return .handled }
                    if !query.isEmpty {
                        Button { query = ""; Task { await store.search("") } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).help("Clear search")
                    }
                }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7)).frame(width: 230)
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { showsScreenedSenders = true } label: { Image(systemName: "person.crop.circle.badge.checkmark") }.help("Screened senders")
                Button { composition = .newMessage } label: { Image(systemName: "square.and.pencil") }.help("Compose (c)").disabled(loadingComposition)
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if !store.searchQuery.isEmpty {
                HStack {
                    Text("Gmail search: \(store.searchQuery)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { query = ""; Task { await store.search("") } }.buttonStyle(.borderless).font(.caption)
                }.padding(.horizontal, 18).padding(.vertical, 8)
                Divider()
            }
            HSplitView {
                Group {
                    if mailbox == .screener && store.searchQuery.isEmpty {
                        MailScreenerView(threads: threads) { store.selectedThreadID = $0.id }
                    } else if threads.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: mailbox.symbol, description: Text(emptyDescription))
                    } else {
                        List(selection: $store.selectedThreadID) {
                            ForEach(threads) { thread in
                                MailThreadRow(thread: thread, mailbox: mailbox).tag(thread.id)
                                    .contextMenu {
                                        Button("Archive") { Task { await store.archive(thread) } }
                                        Button(thread.unread ? "Mark read" : "Mark unread") { Task { await store.setRead(thread, thread.unread) } }
                                        Button(thread.isSetAside ? "Return to Imbox" : "Set Aside") { Task { await store.toggleSetAside(thread) } }
                                        Button("Bubble Up…") { bubbleThread = thread }
                                        Divider()
                                        Button("Move to Trash", role: .destructive) { Task { await store.trash(thread) } }
                                    }
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden)
                    }
                }.frame(minWidth: 260, idealWidth: 330, maxWidth: 430)
                Group {
                    if let selected {
                        MailThreadView(thread: selected, compose: compose, bubble: { bubbleThread = selected })
                            .id(selected.id)
                    } else {
                        ContentUnavailableView("A little breathing room", systemImage: "envelope.open",
                            description: Text("Select a thread to read it. Press c to write, or ⌘K for actions."))
                    }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .overlay(alignment: .bottom) {
            if let text = store.undoMessage {
                HStack(spacing: 16) {
                    Text(text)
                    Button("Undo") { Task { await store.undo() } }.buttonStyle(.borderless).fontWeight(.semibold)
                }.padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule()).shadow(radius: 8, y: 3).padding(20)
                    .transition(.opacity)
            }
        }
        .overlay {
            if loadingComposition { ProgressView("Preparing message…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .background(MailKeyboardMonitor(enabled: composition == nil && bubbleThread == nil && !showsScreenedSenders && !showsPalette && !loadingComposition, handle: handleKey).frame(width: 0, height: 0))
        .sheet(item: $composition) { MailComposerView(composition: $0).environment(store) }
        .sheet(item: $bubbleThread) { thread in
            BubbleUpPicker { date in Task { await store.bubbleUp(thread, date) } }
        }
        .sheet(isPresented: $showsScreenedSenders) { ScreenedSendersView().environment(store) }
        .sheet(isPresented: $showsPalette, onDismiss: {
            let command = pendingCommand; pendingCommand = nil; command?.perform()
        }) {
            MailCommandPalette(commands: commands) { pendingCommand = $0 }.environment(store)
        }
        .onAppear { query = store.searchQuery }
        .onChange(of: mailbox) { _, _ in
            store.selectedThreadID = nil
            if !store.searchQuery.isEmpty { query = ""; Task { await store.search("") } }
        }
        .onChange(of: store.selectedThreadID) { _, _ in
            if let selected, selected.unread { Task { await store.setRead(selected, true) } }
        }
        .onChange(of: threads.map(\.id)) { oldIDs, newIDs in
            guard let current = store.selectedThreadID, !newIDs.contains(current) else { return }
            let oldIndex = oldIDs.firstIndex(of: current) ?? 0
            store.selectedThreadID = newIDs.isEmpty ? nil : newIDs[min(oldIndex, newIDs.count - 1)]
        }
    }

    private var emptyTitle: String { !store.searchQuery.isEmpty ? "No matching mail" : "\(mailbox.title) is clear" }
    private var emptyDescription: String {
        if !store.searchQuery.isEmpty { return "Try a different Gmail search, such as from:person@example.com or has:attachment." }
        switch mailbox {
        case .imbox: return "Approved senders reach you here. New senders wait in the Screener."
        case .setAside: return "Keep useful threads handy. Press s on a thread to set it aside."
        case .bubbleUp: return "Bring mail back when you need it. Press b on a thread to choose a time."
        case .drafts: return "Messages you write are saved to Gmail as drafts."
        case .sent: return "Your sent messages appear here."
        default: return "Refresh to check for new mail."
        }
    }

    private func compose(_ message: MailMessage, _ action: MailComposeAction) {
        guard !loadingComposition else { return }
        switch action {
        case .reply: composition = .reply(to: message, accountEmail: store.accountEmail, all: false)
        case .replyAll: composition = .reply(to: message, accountEmail: store.accountEmail, all: true)
        case .forward, .editDraft:
            loadingComposition = true
            Task {
                do {
                    var request = action == .forward ? MailComposition.forward(message) : MailComposition.draft(message)
                    for attachment in message.attachments {
                        let data = try await store.attachmentData(attachment, message: message)
                        request.message.attachments.append(OutgoingAttachment(name: attachment.name, mimeType: attachment.mimeType, data: data))
                    }
                    composition = request
                } catch { store.reportError(error) }
                loadingComposition = false
            }
        }
    }

    private func moveSelection(_ offset: Int) {
        guard !threads.isEmpty else { return }
        let current = threads.firstIndex { $0.id == store.selectedThreadID }
        let target = current.map { min(max($0 + offset, 0), threads.count - 1) } ?? (offset > 0 ? 0 : threads.count - 1)
        store.selectedThreadID = threads[target].id
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command && character == "k" { showsPalette = true; return true }
        if modifiers == .command && character == "z", store.undoMessage != nil { Task { await store.undo() }; return true }
        guard modifiers.isEmpty else { return false }
        switch character {
        case "j": moveSelection(1)
        case "k": moveSelection(-1)
        case "c": composition = .newMessage
        case "/": searchFocused = true
        case "\r":
            if selected == nil { moveSelection(1) }
            if mailbox == .drafts, let message = draftMessage { compose(message, .editDraft) }
        case "e": if let selected { Task { await store.archive(selected) } }
        case "s": if let selected { Task { await store.toggleSetAside(selected) } }
        case "b": if let selected { bubbleThread = selected }
        case "r": if let message = replyMessage { compose(message, .reply) }
        case "a": if let message = replyMessage { compose(message, .replyAll) }
        case "f": if let message = replyMessage { compose(message, .forward) }
        default: return false
        }
        return true
    }

    private var commands: [MailPaletteCommand] {
        var result = [
            MailPaletteCommand(title: "Compose a message", symbol: "square.and.pencil", shortcut: "c") { composition = .newMessage },
            MailPaletteCommand(title: "Search Gmail", symbol: "magnifyingglass", shortcut: "/") { searchFocused = true },
            MailPaletteCommand(title: "Refresh mail and calendar", symbol: "arrow.clockwise", shortcut: "") { Task { await store.refresh() } },
            MailPaletteCommand(title: "Manage screened senders", symbol: "person.crop.circle", shortcut: "") { showsScreenedSenders = true }
        ]
        for mailbox in Mailbox.allCases {
            result.append(MailPaletteCommand(title: "Go to \(mailbox.title)", symbol: mailbox.symbol, shortcut: "") { store.navigation = mailbox })
        }
        if let selected {
            result += [
                MailPaletteCommand(title: "Archive thread", symbol: "archivebox", shortcut: "e") { Task { await store.archive(selected) } },
                MailPaletteCommand(title: "Move thread to Trash", symbol: "trash", shortcut: "") { Task { await store.trash(selected) } },
                MailPaletteCommand(title: selected.isSetAside ? "Return thread to Imbox" : "Set thread aside", symbol: "bookmark", shortcut: "s") { Task { await store.toggleSetAside(selected) } },
                MailPaletteCommand(title: "Bubble Up thread", symbol: "clock.arrow.circlepath", shortcut: "b") { bubbleThread = selected },
                MailPaletteCommand(title: selected.unread ? "Mark thread read" : "Mark thread unread", symbol: "envelope", shortcut: "") { Task { await store.setRead(selected, selected.unread) } }
            ]
            if let message = replyMessage {
                result += [
                    MailPaletteCommand(title: "Reply", symbol: "arrowshape.turn.up.left", shortcut: "r") { compose(message, .reply) },
                    MailPaletteCommand(title: "Reply all", symbol: "arrowshape.turn.up.left.2", shortcut: "a") { compose(message, .replyAll) },
                    MailPaletteCommand(title: "Forward", symbol: "arrowshape.turn.up.right", shortcut: "f") { compose(message, .forward) }
                ]
            }
            if let message = draftMessage { result.append(MailPaletteCommand(title: "Edit draft", symbol: "square.and.pencil", shortcut: "↩") { compose(message, .editDraft) }) }
        }
        if store.undoMessage != nil { result.append(MailPaletteCommand(title: "Undo last action", symbol: "arrow.uturn.backward", shortcut: "⌘Z") { Task { await store.undo() } }) }
        return result
    }
}

private struct MailThreadRow: View {
    var thread: MailThread
    var mailbox: Mailbox

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                if thread.unread { Circle().fill(.secondary).frame(width: 5, height: 5).accessibilityLabel("Unread") }
                Text(senderName).font(.callout.weight(thread.unread ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text(thread.updatedAt, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary)
            }
            Text(thread.subject).font(.callout.weight(thread.unread ? .medium : .regular)).lineLimit(1)
            Text(thread.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let due = thread.bubbleUpAt {
                Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
            } else if thread.bubbledAt != nil {
                Label("Bubbled up", systemImage: "arrow.up.circle").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 7).accessibilityElement(children: .combine)
    }

    private var senderName: String {
        if mailbox == .sent || mailbox == .drafts {
            let names = thread.latestMessage?.to.map(\.displayName).joined(separator: ", ") ?? ""
            return names.isEmpty ? "No recipients" : "To: \(names)"
        }
        return thread.sender.displayName
    }
}
#endif
