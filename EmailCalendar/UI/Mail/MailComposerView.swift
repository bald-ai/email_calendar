#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MailComposition: Identifiable {
    let id = UUID()
    var title: String
    var accountID: String?
    /// Shown above the editor, e.g. when a draft's formatting had to be simplified.
    var notice: String?
    let session: DraftSession
    var message: OutgoingMessage {
        get { session.message }
        set { session.message = newValue }
    }
    init(title: String, message: OutgoingMessage) {
        self.title = title
        session = DraftSession(message: message)
    }

    init(recovery: DraftRecovery, accountID: String) {
        title = recovery.title
        self.accountID = accountID
        session = DraftSession(recovering: recovery.buffer)
    }

    static var newMessage: MailComposition { MailComposition(title: "New message", message: OutgoingMessage(isHTML: true)) }

    /// `sendAddresses` are the account's verified send-as addresses: none of them gets a copy of the reply,
    /// and the reply goes out from the one the original involved (mail forwarded from another address included).
    /// `data` holds the original's downloaded attachments by attachment ID, for the images its quote shows.
    static func reply(to original: MailMessage, accountEmail: String, sendAddresses: [String], all: Bool, data: [String: Data] = [:]) -> MailComposition {
        let own = Set(([accountEmail] + sendAddresses).map { $0.lowercased() })
        let primary = own.contains(original.from.email.lowercased()) ? original.to.map(\.email) : (original.replyTo.isEmpty ? [original.from.email] : original.replyTo.map(\.email))
        let recipients = all ? primary + original.to.map(\.email) : primary
        var to = unique(recipients.filter { !own.contains($0.lowercased()) })
        if to.isEmpty { to = unique(primary) }
        let cc = all ? unique(original.cc.map(\.email).filter { !own.contains($0.lowercased()) && !to.map { $0.lowercased() }.contains($0.lowercased()) }) : []
        var references = original.references
        if let messageID = original.rfcMessageID, !references.contains(messageID) { references.append(messageID) }
        let header = "On \(original.date.formatted(date: .abbreviated, time: .shortened)), \(original.from.formatted) wrote:"
        let quote = RichBody.replyQuote(header: header, originalHTML: original.html, originalText: text(of: original),
                                        images: quotedImages(original, data: data))
        return MailComposition(title: all ? "Reply all" : "Reply", message: OutgoingMessage(
            to: to, cc: cc, subject: prefixed(original.subject, prefix: "Re:"),
            threadID: original.threadID, inReplyTo: original.rfcMessageID, references: references,
            from: SendIdentity.address(for: original, addresses: sendAddresses, accountEmail: accountEmail),
            isHTML: true, quote: quote))
    }

    static func forward(_ original: MailMessage, accountEmail: String, sendAddresses: [String], data: [String: Data] = [:]) -> MailComposition {
        var header = ["---------- Forwarded message ---------", "From: \(original.from.formatted)",
                      "Date: \(original.date.formatted(date: .abbreviated, time: .shortened))", "Subject: \(original.subject)",
                      "To: \(original.to.map(\.formatted).joined(separator: ", "))"]
        if !original.cc.isEmpty { header.append("Cc: \(original.cc.map(\.formatted).joined(separator: ", "))") }
        let quote = RichBody.forwardQuote(headerLines: header, originalHTML: original.html, originalText: text(of: original),
                                          images: quotedImages(original, data: data))
        let inline = Set(quote.images.compactMap(\.contentID))
        return MailComposition(title: "Forward", message: OutgoingMessage(subject: prefixed(original.subject, prefix: "Fwd:"),
            attachments: OutgoingAttachment.files(of: original, data: data, excluding: inline),
            from: SendIdentity.address(for: original, addresses: sendAddresses, accountEmail: accountEmail),
            isHTML: true, quote: quote))
    }

    /// Reopens a draft: its text and images become editable again, and a quoted original is kept as it was.
    static func draft(_ original: MailMessage, accountEmail: String, data: [String: Data] = [:]) -> MailComposition {
        let reopened = OutgoingMessage.reopening(original, accountEmail: accountEmail, data: data)
        var composition = MailComposition(title: "Draft", message: reopened.message)
        if reopened.simplified { composition.notice = "Some formatting in this draft can’t be shown here, so it was simplified to plain text." }
        return composition
    }

    /// Attachment IDs whose bytes a reply, forward or reopened draft needs.
    static func neededAttachments(_ original: MailMessage, action: MailComposeAction) -> [MailAttachment] {
        let referenced = Set(original.html.map(RichBody.contentIDs(in:)) ?? [])
        switch action {
        case .reply, .replyAll: return original.attachments.filter { $0.contentID.map(referenced.contains) ?? false }
        case .forward, .editDraft: return original.attachments
        }
    }

    private static func text(of original: MailMessage) -> String {
        original.plainText.isEmpty ? (original.html.map(plainText(from:)) ?? original.snippet) : original.plainText
    }

    private static func quotedImages(_ original: MailMessage, data: [String: Data]) -> [OutgoingAttachment] {
        (original.html.map(RichBody.contentIDs(in:)) ?? []).compactMap { OutgoingAttachment.inlineImage($0, of: original, data: data) }
    }

    private static func unique(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func prefixed(_ subject: String, prefix: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
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
    /// The file picker adds attachments, or images placed in the text at the cursor.
    @State private var importsImages = false
    @State private var showsQuote = false
    @State private var editor = RichTextController()
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

    private var canSend: Bool { draft.canSend }

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
                    if let notice = composition.notice {
                        Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.secondary).padding(.bottom, 12)
                    }
                    TextField("", text: $draft.message.subject, prompt: Text("Subject").foregroundStyle(Theme.secondary.opacity(0.6)), axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 30, weight: .bold)).padding(.bottom, 16)
                    VStack(spacing: 10) {
                        if fromChoices.count > 1 { fromRow }
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
                    RichTextEditor(text: $draft.message.body, images: $draft.message.inlineImages, controller: editor,
                                   initialFocus: !to.isEmpty, onFiles: { addAttachments($0) })
                        .padding(.top, 18)
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
                    if let quote = message.quote {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 14) {
                                Button { showsQuote.toggle() } label: {
                                    Label(showsQuote ? "Hide quoted message" : "Show quoted message", systemImage: "text.quote")
                                }
                                Button("Remove") { draft.message.quote = nil }.help("Send without the quoted message")
                            }.buttonStyle(QuietButtonStyle()).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                            // Plain text only: the original's HTML (and its remote images) is never loaded while writing.
                            if showsQuote {
                                Text(quote.text).font(.system(size: 13)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 14)
                    }
                    if message.totalAttachmentBytes > 0 {
                        let total = message.totalAttachmentBytes
                        Text(total > Self.sizeLimit
                             ? "\(Self.size(total)) of images and attachments, over Gmail’s 25 MB limit. Remove an image or attachment to send."
                             : "\(Self.size(total)) of 25 MB")
                            .font(.caption).foregroundStyle(total > Self.sizeLimit ? Theme.no : Theme.secondary).padding(.top, 10)
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
            .disabled(draft.sendNeedsVerification || isSending)

            HStack(spacing: 10) {
                Button { Task { await send() } } label: {
                    HStack(spacing: 6) {
                        if isSending { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane.fill") }
                        Text(draft.sendNeedsVerification ? "Check send status" : "Send")
                        Text("⌘↩").font(.system(size: 11, weight: .semibold)).opacity(0.7)
                    }
                }
                .buttonStyle(PillButtonStyle(fill: canSend ? Theme.accent : Theme.accent.opacity(0.4)))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend || isSending || isSaving)
                Button { importsImages = true; showsImporter = true } label: { Label("Image", systemImage: "photo") }
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1)))
                    .disabled(draft.sendNeedsVerification)
                    .help("Put an image in the text at the cursor. You can also paste (⌘V) or drop one.")
                Button { importsImages = false; showsImporter = true } label: { Label("Attach", systemImage: "paperclip") }
                    .buttonStyle(PillButtonStyle(fill: .white.opacity(0.1)))
                    .disabled(draft.sendNeedsVerification)
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
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: importsImages ? [.image] : [.data], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                if importsImages { editor.insertImages(from: urls); editor.focus() } else { addAttachments(urls) }
            } catch { errorText = error.localizedDescription }
        }
    }

    private static let sizeLimit = 25_000_000
    private static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    private func addAttachments(_ urls: [URL]) {
        do {
            var additions: [OutgoingAttachment] = []
            var totalBytes = message.totalAttachmentBytes
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.sizeLimit - totalBytes else { errorText = "Images and attachments must total less than 25 MB."; return }
                let data = try Data(contentsOf: url)
                totalBytes += data.count
                guard totalBytes <= Self.sizeLimit else { errorText = "Images and attachments must total less than 25 MB."; return }
                additions.append(OutgoingAttachment(name: url.lastPathComponent,
                    mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data))
            }
            draft.message.attachments += additions
        } catch { errorText = error.localizedDescription }
    }

    /// The account's send-as addresses, plus a draft's own From if Gmail no longer lists it.
    private var fromChoices: [String] {
        var choices = store.sendAddresses.isEmpty ? [store.accountEmail] : store.sendAddresses
        if let from = message.from, !choices.contains(where: { $0.lowercased() == from.lowercased() }) { choices.append(from) }
        return choices
    }

    private var fromRow: some View {
        HStack(spacing: 10) {
            Text("From").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary).frame(width: 34, alignment: .leading)
            Menu {
                ForEach(fromChoices, id: \.self) { address in
                    Button(address) { draft.message.from = address.lowercased() == store.accountEmail.lowercased() ? nil : address }
                }
            } label: { Text(message.from ?? store.accountEmail).font(.system(size: 14)) }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer()
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
