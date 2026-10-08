#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MailThreadView: View {
    @Environment(AppStore.self) private var store
    var thread: MailThread
    var compose: (MailMessage, MailComposeAction) -> Void
    var bubble: () -> Void
    var act: (MailRootView.ThreadAction) -> Void
    @Binding var showsMore: Bool

    private var messages: [MailMessage] { thread.messages.sorted { $0.date < $1.date } }
    private var replyTarget: MailMessage? {
        thread.messages.filter { !$0.labels.contains("DRAFT") && $0.draftID == nil }.max { $0.date < $1.date }
    }
    private var draft: MailMessage? {
        thread.messages.filter { $0.labels.contains("DRAFT") || $0.draftID != nil }.max { $0.date < $1.date }
    }
    private var participants: [MailAddress] {
        var seen = Set<String>()
        return messages.map(\.from).filter { seen.insert($0.email.lowercased()).inserted }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: -8) {
                        ForEach(participants.prefix(4), id: \.email) { person in
                            Avatar(name: person.displayName, key: person.email, size: 32)
                                .overlay(Circle().stroke(Theme.window, lineWidth: 2))
                        }
                    }.padding(.top, 14)
                    Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                        .font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20)
                    if let due = thread.bubbleUpAt {
                        Label("Bubbles up \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "bubbles.and.sparkles")
                            .font(.callout).foregroundStyle(Theme.unread)
                    } else if thread.isSetAside {
                        Label("Set aside", systemImage: "pin.fill").font(.callout).foregroundStyle(Theme.secondary)
                    }
                    ForEach(messages) { message in
                        MailMessageCard(message: message, isLatest: message.id == thread.latestMessage?.id,
                                        initiallyExpanded: message.id == thread.latestMessage?.id || messages.count <= 2, compose: compose)
                    }
                    if store.poweringThrough {
                        Text("Powering through new mail · \(max(0, store.newForYou.filter { $0.id != thread.id }.count)) more after this")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 110)
                }
                .frame(maxWidth: 790).frame(maxWidth: .infinity).padding(.horizontal, 24)
            }
            .scrollIndicators(.never)
            actionBar.padding(.bottom, 22)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 4) {
            if let draft {
                barButton("Edit Draft", symbol: "square.and.pencil", key: "↩") { compose(draft, .editDraft) }
            } else if let replyTarget {
                barButton("Reply Now", symbol: "arrowshape.turn.up.left", key: "R") { compose(replyTarget, .reply) }
            }
            barButton(thread.isSetAside ? "Take Back" : "Set Aside", symbol: "pin", key: "A") { act(.setAside) }
            barButton("Bubble Up", symbol: "bubbles.and.sparkles", key: "Z", perform: bubble)
            barButton("Archive", symbol: "archivebox", key: "E") { act(.archive) }
            barButton("More", symbol: "ellipsis", key: "M") { showsMore.toggle() }
                .popover(isPresented: $showsMore, arrowEdge: .top) { moreMenu }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.actionBar, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let replyTarget {
                moreItem("Reply all", symbol: "arrowshape.turn.up.left.2") { compose(replyTarget, .replyAll) }
                moreItem("Forward", symbol: "arrowshape.turn.up.right") { compose(replyTarget, .forward) }
                Divider().padding(.vertical, 4)
            }
            moreItem(thread.unread ? "Mark as read" : "Mark as unread", symbol: "envelope.badge") { act(.toggleRead) }
            moreItem("Move to Trash", symbol: "trash") { act(.trash) }
        }
        .padding(8).frame(width: 220)
    }

    private func moreItem(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button { showsMore = false; perform() } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle())
    }

    private func barButton(_ title: String, symbol: String, key: String, perform: @escaping () -> Void) -> some View {
        ActionBarButton(title: title, symbol: symbol, key: key, perform: perform)
    }
}

private struct ActionBarButton: View {
    var title: String
    var symbol: String
    var key: String
    var perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(height: 18)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 84, height: 46)
            .overlay(alignment: .topTrailing) {
                Text(key).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.55)).padding(.top, 3).padding(.trailing, 7)
            }
            .background(.white.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.back.opacity(hovering ? 0.7 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help("\(title) (\(key))")
    }
}

enum MailComposeAction: Equatable { case reply, replyAll, forward, editDraft }

private struct MailMessageCard: View {
    @Environment(AppStore.self) private var store
    var message: MailMessage
    var isLatest = false
    var compose: (MailMessage, MailComposeAction) -> Void
    @State private var expanded: Bool
    @State private var htmlHeight: CGFloat = 180
    @State private var downloading: Set<String> = []
    @State private var inlineImages: [String: Data] = [:]
    @State private var inlineImageError = false

    init(message: MailMessage, isLatest: Bool = false, initiallyExpanded: Bool, compose: @escaping (MailMessage, MailComposeAction) -> Void) {
        self.message = message; self.isLatest = isLatest; self.compose = compose
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 12) {
                    Avatar(name: message.from.displayName, key: message.from.email, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(message.from.displayName).font(.system(size: 15, weight: .semibold))
                            if expanded { Text("<\(message.from.email)>").font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                        }
                        if expanded {
                            Text("to \(message.to.map(\.formatted).joined(separator: ", "))").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            if !message.cc.isEmpty { Text("cc \(message.cc.map(\.formatted).joined(separator: ", "))").font(.system(size: 13)).foregroundStyle(Theme.secondary) }
                        } else { Text(message.snippet).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text(Theme.shortDate(message.date)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .help(message.date.formatted(date: .complete, time: .shortened))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)

            if expanded {
                if let html = resolvedHTML, !html.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                        Text(store.allowsRemoteImages(sender: message.from.email) ? "Images allowed for this sender" : "Remote images are hidden")
                        Spacer()
                        Button(store.allowsRemoteImages(sender: message.from.email) ? "Hide images" : "Load images") {
                            Task { await store.setAllowsRemoteImages(sender: message.from.email, allowed: !store.allowsRemoteImages(sender: message.from.email)) }
                        }.buttonStyle(.borderless)
                    }.font(.caption).foregroundStyle(Theme.secondary).padding(8).background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    MailHTMLView(html: html, allowsRemoteImages: store.allowsRemoteImages(sender: message.from.email), height: $htmlHeight)
                        .frame(height: htmlHeight)
                        .padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    if inlineImageError { Text("Some inline images could not be loaded.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(message.plainText.isEmpty ? message.snippet : message.plainText)
                        .font(.system(size: 15)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 50)
                }
                if !message.attachments.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading) {
                        ForEach(message.attachments) { attachment in
                            HStack {
                                Button { Task { await saveAttachment(attachment, open: true) } } label: {
                                    HStack(spacing: 7) {
                                        if downloading.contains(attachment.id) { ProgressView().controlSize(.small) } else { Image(systemName: "doc") }
                                        VStack(alignment: .leading) {
                                            Text(attachment.name).lineLimit(1)
                                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }.buttonStyle(.plain).help("Open attachment")
                                Spacer(minLength: 2)
                                Button { Task { await saveAttachment(attachment, open: false) } } label: { Image(systemName: "arrow.down.to.line") }
                                    .buttonStyle(.borderless).help("Save attachment")
                            }.padding(10).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                                .disabled(downloading.contains(attachment.id))
                        }
                    }
                }
                if !isLatest {
                    HStack(spacing: 16) {
                        if message.draftID != nil || message.labels.contains("DRAFT") {
                            Button("Edit draft") { compose(message, .editDraft) }
                        } else {
                            Button("Reply to this") { compose(message, .reply) }
                            Button("Forward") { compose(message, .forward) }
                        }
                        Spacer()
                    }.buttonStyle(QuietButtonStyle()).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                        .padding(.leading, 50)
                }
            }
        }
        .padding(22)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(isLatest ? Color(hex: 0xC9895B).opacity(0.7) : Theme.line, lineWidth: 1))
        .task(id: expanded) {
            guard expanded else { return }
            for attachment in message.attachments {
                guard let contentID = attachment.contentID, attachment.mimeType.lowercased().hasPrefix("image/"),
                      inlineImages[contentID] == nil else { continue }
                do { inlineImages[contentID] = try await store.attachmentData(attachment, message: message) }
                catch { inlineImageError = true }
            }
        }
    }

    private var resolvedHTML: String? {
        guard var html = message.html else { return nil }
        for attachment in message.attachments {
            guard let contentID = attachment.contentID, let data = attachment.inlineData ?? inlineImages[contentID],
                  attachment.mimeType.range(of: #"^image/[a-zA-Z0-9.+-]+$"#, options: .regularExpression) != nil else { continue }
            let source = "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
            html = html.replacingOccurrences(of: "cid:\(contentID)", with: source, options: .caseInsensitive)
            if let encoded = contentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                html = html.replacingOccurrences(of: "cid:\(encoded)", with: source, options: .caseInsensitive)
            }
        }
        return html
    }

    private func saveAttachment(_ attachment: MailAttachment, open: Bool) async {
        downloading.insert(attachment.id)
        defer { downloading.remove(attachment.id) }
        do {
            var destination: URL
            if open {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmailCalendar-Attachments", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Gmail filenames may include paths; retain only the last component.
                destination = folder.appendingPathComponent(URL(fileURLWithPath: attachment.name).lastPathComponent)
            } else {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = URL(fileURLWithPath: attachment.name).lastPathComponent
                if let type = UTType(mimeType: attachment.mimeType) { panel.allowedContentTypes = [type] }
                let result = await panel.begin()
                guard result == .OK, let url = panel.url else { return }
                destination = url
            }
            let data = try await store.attachmentData(attachment, message: message)
            try data.write(to: destination, options: .atomic)
            if open { NSWorkspace.shared.open(destination) }
        } catch { store.reportError(error) }
    }
}
#endif
