#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MailComposition: Identifiable {
    let id = UUID()
    var title: String
    let session: DraftSession
    var message: OutgoingMessage {
        get { session.message }
        set { session.message = newValue }
    }
    init(title: String, message: OutgoingMessage) {
        self.title = title
        session = DraftSession(message: message)
    }

    static var newMessage: MailComposition { MailComposition(title: "New message", message: OutgoingMessage()) }

    static func reply(to original: MailMessage, accountEmail: String, all: Bool) -> MailComposition {
        let own = accountEmail.lowercased()
        let primary = original.from.email.lowercased() == own ? original.to.map(\.email) : (original.replyTo.isEmpty ? [original.from.email] : original.replyTo.map(\.email))
        let recipients = all ? primary + original.to.map(\.email) : primary
        var to = unique(recipients.filter { $0.lowercased() != own })
        if to.isEmpty { to = unique(primary) }
        let cc = all ? unique(original.cc.map(\.email).filter { $0.lowercased() != own && !to.map { $0.lowercased() }.contains($0.lowercased()) }) : []
        var references = original.references
        if let messageID = original.rfcMessageID, !references.contains(messageID) { references.append(messageID) }
        return MailComposition(title: all ? "Reply all" : "Reply", message: OutgoingMessage(
            to: to, cc: cc, subject: prefixed(original.subject, prefix: "Re:"), body: "\n\n" + quote(original),
            threadID: original.threadID, inReplyTo: original.rfcMessageID, references: references))
    }

    static func forward(_ original: MailMessage) -> MailComposition {
        MailComposition(title: "Forward", message: OutgoingMessage(subject: prefixed(original.subject, prefix: "Fwd:"), body: "\n\n" + quote(original)))
    }

    static func draft(_ original: MailMessage) -> MailComposition {
        MailComposition(title: "Draft", message: OutgoingMessage(to: original.to.map(\.email), cc: original.cc.map(\.email),
            bcc: original.bcc.map(\.email), subject: original.subject, body: original.plainText.isEmpty ? (original.html.map(plainText(from:)) ?? "") : original.plainText,
            draftID: original.draftID, threadID: original.threadID,
            inReplyTo: original.inReplyTo, references: original.references))
    }

    private static func unique(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func prefixed(_ subject: String, prefix: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    private static func quote(_ original: MailMessage) -> String {
        let text = original.plainText.isEmpty ? (original.html.map(plainText(from:)) ?? original.snippet) : original.plainText
        return "On \(original.date.formatted(date: .abbreviated, time: .shortened)), \(original.from.formatted) wrote:\n" +
            text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
    }

    /// Convert HTML-only mail for quoting without starting an HTML importer that
    /// could fetch tracking resources while the user writes their reply.
    private static func plainText(from html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|tr|h[1-6]|li)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MailComposerView: View {
    @Environment(AppStore.self) private var store
    let composition: MailComposition
    /// Called instead of dismissing a sheet: the composer is a page in the main window.
    var onClose: () -> Void = {}
    private var draft: DraftSession { composition.session }
    private var message: OutgoingMessage { draft.message }
    private var to: String { draft.to }
    private var cc: String { draft.cc }
    private var bcc: String { draft.bcc }
    private var isSaving: Bool { draft.isSaving }
    private var isSending: Bool { draft.isSending }
    private var savedAt: Date? { draft.savedAt }
    @State private var showsMoreRecipients: Bool
    @State private var showsImporter = false
    @State private var isClosing = false
    @State private var errorText: String?
    @FocusState private var focus: Field?
    private enum Field { case to, cc, bcc, body }

    init(composition: MailComposition, onClose: @escaping () -> Void = {}) {
        self.composition = composition
        self.onClose = onClose
        _showsMoreRecipients = State(initialValue: !composition.message.cc.isEmpty || !composition.message.bcc.isEmpty)
    }

    private var outgoing: OutgoingMessage { draft.outgoing }

    private var canSend: Bool {
        let recipients = outgoing.to + outgoing.cc + outgoing.bcc
        return !recipients.isEmpty && recipients.allSatisfy { address in
            let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
            return pieces.count == 2 && !pieces[0].isEmpty && pieces[1].contains(".") && !address.contains(where: { $0.isWhitespace })
        }
    }

    var body: some View {
        @Bindable var draft = draft
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(composition.title.uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondary)
                        Spacer()
                        if isSaving { ProgressView().controlSize(.small); Text("Saving…").font(.caption).foregroundStyle(Theme.secondary) }
                        else if let savedAt { Text("Draft saved \(savedAt, style: .time)").font(.caption).foregroundStyle(Theme.secondary) }
                    }.padding(.bottom, 18)
                    TextField("", text: $draft.message.subject, prompt: Text("Subject").foregroundStyle(Theme.secondary.opacity(0.6)), axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 30, weight: .bold)).padding(.bottom, 16)
                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            recipientRow("To", value: $draft.to, field: .to)
                            Button(showsMoreRecipients ? "Hide Cc/Bcc" : "Cc/Bcc") { showsMoreRecipients.toggle() }
                                .buttonStyle(QuietButtonStyle()).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        }
                        if showsMoreRecipients {
                            recipientRow("Cc", value: $draft.cc, field: .cc)
                            recipientRow("Bcc", value: $draft.bcc, field: .bcc)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
                    TextEditor(text: $draft.message.body)
                        .font(.system(size: 15)).lineSpacing(3).scrollContentBackground(.hidden).focused($focus, equals: .body)
                        .scrollDisabled(true)
                        .frame(minHeight: 320).padding(.top, 18)
                    if !message.attachments.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(message.attachments) { attachment in
                                HStack(spacing: 8) {
                                    Image(systemName: "doc").foregroundStyle(Theme.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(attachment.name).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                            .font(.caption2).foregroundStyle(Theme.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Button { draft.message.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(QuietButtonStyle()).foregroundStyle(Theme.secondary).help("Remove attachment")
                                }.font(.system(size: 13)).padding(10).background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }.padding(.top, 10)
                    }
                    if let errorText = errorText ?? draft.errorText {
                        Text(errorText).font(.callout).foregroundStyle(Theme.no).padding(.top, 10)
                    }
                    Spacer(minLength: 120)
                }
                .padding(.horizontal, 48).padding(.top, 34)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: 790)
            .background(Theme.card, in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Button { Task { await send() } } label: {
                    HStack(spacing: 6) {
                        if isSending { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane.fill") }
                        Text("Send")
                        Text("⌘↩").font(.system(size: 11, weight: .semibold)).opacity(0.7)
                    }
                }
                .buttonStyle(PillButtonStyle(fill: canSend ? Theme.accent : Theme.accent.opacity(0.4)))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend || isSending || isSaving)
                Button { showsImporter = true } label: { Label("Attach", systemImage: "paperclip") }
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1)))
                Button { Task { await save(close: true) } } label: { Label("Save & close", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1)))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving || isSending)
                    .help("Saves a draft and closes (Esc)")
            }
            .padding(8)
            .background(Theme.actionBar, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .padding(.bottom, 22)
        }
        .disabled(isSending || isClosing)
        .interactiveDismissDisabled()
        .onAppear {
            focus = to.isEmpty ? .to : .body
            let accountID = store.account?.id
            draft.configure(save: { outgoing in
                guard store.account?.id == accountID else { throw CancellationError() }
                return try await store.saveDraft(outgoing)
            }, send: { outgoing in
                guard store.account?.id == accountID else { throw CancellationError() }
                try await store.send(outgoing)
            })
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                var additions: [OutgoingAttachment] = []
                var totalBytes = message.attachments.reduce(0) { $0 + $1.data.count }
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 25_000_000 - totalBytes else { errorText = "Attachments must total less than 25 MB."; return }
                    let data = try Data(contentsOf: url)
                    totalBytes += data.count
                    guard totalBytes <= 25_000_000 else { errorText = "Attachments must total less than 25 MB."; return }
                    additions.append(OutgoingAttachment(name: url.lastPathComponent,
                        mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data))
                }
                draft.message.attachments += additions
            } catch { errorText = error.localizedDescription }
        }
    }

    private func recipientRow(_ title: String, value: Binding<String>, field: Field) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary).frame(width: 34, alignment: .leading)
            ForEach(addresses(value.wrappedValue).prefix(4), id: \.self) { address in
                Avatar(name: address, key: address.lowercased(), size: 20)
            }
            TextField("", text: value, prompt: Text("Email addresses, separated by commas").foregroundStyle(Theme.secondary.opacity(0.6)))
                .textFieldStyle(.plain).font(.system(size: 14)).focused($focus, equals: field)
        }
    }

    private func addresses(_ field: String) -> [String] {
        DraftSession.addresses(field)
    }

    private func save(close: Bool) async {
        guard !isSending else { return }
        isClosing = close; errorText = nil
        do {
            try await draft.flush()
            if close { onClose() }
        } catch {
            isClosing = false; errorText = "Draft could not be saved: \(error.localizedDescription)"
            if close { store.reportError(error) }
        }
    }

    private func send() async {
        guard canSend, !isSaving, !isSending else { return }
        errorText = nil
        do { try await draft.send(); onClose() }
        catch { errorText = error.localizedDescription; store.reportError(error) }
    }
}
#endif
