#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MailThreadView: View {
    @Environment(AppStore.self) private var store
    var thread: MailThread
    var compose: (MailMessage, MailComposeAction) -> Void
    var bubble: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(thread.subject).font(.title3.weight(.semibold)).lineLimit(2)
                Spacer()
                action("Archive", symbol: "archivebox", key: "e") { Task { await store.archive(thread) } }
                action(thread.isSetAside ? "Return to Imbox" : "Set Aside", symbol: thread.isSetAside ? "bookmark.fill" : "bookmark", key: "s") {
                    Task { await store.toggleSetAside(thread) }
                }
                action("Bubble Up", symbol: "clock.arrow.circlepath", key: "b", perform: bubble)
                Menu {
                    Button(thread.unread ? "Mark read" : "Mark unread") { Task { await store.setRead(thread, thread.unread) } }
                    Button("Move to Trash", role: .destructive) { Task { await store.trash(thread) } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("More actions")
            }.padding(18)
            Divider()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if let due = thread.bubbleUpAt {
                        Label("Returns \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(thread.messages.sorted { $0.date < $1.date }) { message in
                        MailMessageCard(message: message, initiallyExpanded: message.id == thread.latestMessage?.id, compose: compose)
                    }
                }.padding(20)
            }
        }
        .background(.background)
    }

    private func action(_ title: String, symbol: String, key: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).font(.system(size: 15)) }
            .buttonStyle(.borderless).help("\(title) (\(key))").accessibilityLabel(title)
    }
}

enum MailComposeAction: Equatable { case reply, replyAll, forward, editDraft }

private struct MailMessageCard: View {
    @Environment(AppStore.self) private var store
    var message: MailMessage
    var compose: (MailMessage, MailComposeAction) -> Void
    @State private var expanded: Bool
    @State private var htmlHeight: CGFloat = 180
    @State private var downloading: Set<String> = []
    @State private var inlineImages: [String: Data] = [:]
    @State private var inlineImageError = false

    init(message: MailMessage, initiallyExpanded: Bool, compose: @escaping (MailMessage, MailComposeAction) -> Void) {
        self.message = message; self.compose = compose
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top) {
                    Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.from.displayName).font(.headline)
                        if expanded {
                            Text(message.from.email).font(.caption).foregroundStyle(.secondary)
                            Text("To: \(message.to.map(\.formatted).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            if !message.cc.isEmpty { Text("Cc: \(message.cc.map(\.formatted).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                        } else { Text(message.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
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
                    }.font(.caption).foregroundStyle(.secondary).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    MailHTMLView(html: html, allowsRemoteImages: store.allowsRemoteImages(sender: message.from.email), height: $htmlHeight)
                        .frame(height: htmlHeight)
                    if inlineImageError { Text("Some inline images could not be loaded.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(message.plainText.isEmpty ? message.snippet : message.plainText)
                        .font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                .disabled(downloading.contains(attachment.id))
                        }
                    }
                }
                HStack {
                    if message.draftID != nil || message.labels.contains("DRAFT") {
                        Button("Edit draft") { compose(message, .editDraft) }
                    } else {
                        Button { compose(message, .reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        Button("Reply all") { compose(message, .replyAll) }
                        Button("Forward") { compose(message, .forward) }
                    }
                    Spacer()
                }.padding(.top, 4)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
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
