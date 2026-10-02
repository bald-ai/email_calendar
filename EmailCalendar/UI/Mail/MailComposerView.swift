#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MailComposition: Identifiable {
    let id = UUID()
    var title: String
    var message: OutgoingMessage

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
    @Environment(\.dismiss) private var dismiss
    let composition: MailComposition
    @State private var message: OutgoingMessage
    @State private var to: String
    @State private var cc: String
    @State private var bcc: String
    @State private var showsMoreRecipients: Bool
    @State private var showsImporter = false
    @State private var isSaving = false
    @State private var isSending = false
    @State private var isClosing = false
    @State private var lastSaved: OutgoingMessage?
    @State private var saveTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var savedAt: Date?
    @FocusState private var focus: Field?
    private enum Field { case to, cc, bcc, body }

    init(composition: MailComposition) {
        self.composition = composition
        _message = State(initialValue: composition.message)
        _to = State(initialValue: composition.message.to.joined(separator: ", "))
        _cc = State(initialValue: composition.message.cc.joined(separator: ", "))
        _bcc = State(initialValue: composition.message.bcc.joined(separator: ", "))
        _showsMoreRecipients = State(initialValue: !composition.message.cc.isEmpty || !composition.message.bcc.isEmpty)
    }

    private var outgoing: OutgoingMessage {
        var result = message
        result.to = addresses(to); result.cc = addresses(cc); result.bcc = addresses(bcc)
        return result
    }

    private var canSend: Bool {
        let recipients = outgoing.to + outgoing.cc + outgoing.bcc
        return !recipients.isEmpty && recipients.allSatisfy { address in
            let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
            return pieces.count == 2 && !pieces[0].isEmpty && pieces[1].contains(".") && !address.contains(where: { $0.isWhitespace })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(composition.title).font(.title3.weight(.semibold))
                Spacer()
                if isSaving { ProgressView().controlSize(.small); Text("Saving…").foregroundStyle(.secondary) }
                else if let savedAt { Text("Saved \(savedAt, style: .time)").font(.caption).foregroundStyle(.secondary) }
                Button("Save & close") { Task { await save(close: true) } }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving || isSending)
            }.padding()
            Divider()
            VStack(spacing: 8) {
                HStack {
                    recipientRow("To", value: $to, field: .to)
                    Button(showsMoreRecipients ? "Hide Cc/Bcc" : "Cc/Bcc") { showsMoreRecipients.toggle() }.buttonStyle(.borderless)
                }
                if showsMoreRecipients {
                    recipientRow("Cc", value: $cc, field: .cc)
                    recipientRow("Bcc", value: $bcc, field: .bcc)
                }
                HStack {
                    Text("Subject").foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                    TextField("Subject", text: $message.subject).textFieldStyle(.plain)
                }
            }.padding()
            Divider()
            TextEditor(text: $message.body)
                .font(.body).scrollContentBackground(.hidden).focused($focus, equals: .body)
                .padding(12).frame(minHeight: 260)
            if !message.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(message.attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                Text(attachment.name).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).foregroundStyle(.secondary)
                                Button { message.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).help("Remove attachment")
                            }.font(.caption).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.padding(.horizontal)
                }.padding(.bottom, 10)
            }
            if let errorText { Text(errorText).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8) }
            Divider()
            HStack {
                Button { showsImporter = true } label: { Label("Attach", systemImage: "paperclip") }
                Text("From \(store.accountEmail)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save draft") { Task { await save(close: false) } }.disabled(isSaving || isSending)
                Button { Task { await send() } } label: {
                    if isSending { ProgressView().controlSize(.small) } else { Label("Send", systemImage: "paperplane.fill") }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend || isSending || isSaving)
            }.padding()
        }
        .frame(width: 720, height: 580)
        .disabled(isSending || isClosing)
        .interactiveDismissDisabled()
        .onAppear { focus = to.isEmpty ? .to : .body }
        .onChange(of: outgoing) { _, value in if value != lastSaved { scheduleSave() } }
        .onDisappear { saveTask?.cancel() }
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
                message.attachments += additions
            } catch { errorText = error.localizedDescription }
        }
    }

    private func recipientRow(_ title: String, value: Binding<String>, field: Field) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
            TextField("Email addresses, separated by commas", text: value).textFieldStyle(.plain).focused($focus, equals: field)
        }
    }

    private func addresses(_ field: String) -> [String] {
        field.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !isSending, !isSaving else { return }
            saveTask = nil
            await save(close: false)
        }
    }

    private func save(close: Bool) async {
        guard !isSaving, !isSending else { return }
        saveTask?.cancel()
        let snapshot = outgoing
        if snapshot.to.isEmpty && snapshot.cc.isEmpty && snapshot.bcc.isEmpty && snapshot.subject.isEmpty && snapshot.body.isEmpty && snapshot.attachments.isEmpty {
            if close { dismiss() }; return
        }
        isSaving = true; isClosing = close; errorText = nil
        do {
            let saved = try await store.saveDraft(snapshot)
            message.draftID = saved.draftID
            var savedSnapshot = snapshot; savedSnapshot.draftID = saved.draftID
            lastSaved = savedSnapshot; savedAt = .now; isSaving = false
            if close { dismiss() }
            else if outgoing != savedSnapshot { scheduleSave() }
        } catch {
            isSaving = false; isClosing = false; errorText = "Draft could not be saved: \(error.localizedDescription)"
            if close { store.reportError(error) }
        }
    }

    private func send() async {
        guard canSend, !isSaving, !isSending else { return }
        saveTask?.cancel(); isSending = true; errorText = nil
        do { try await store.send(outgoing); dismiss() }
        catch { isSending = false; errorText = error.localizedDescription; store.reportError(error) }
    }
}
#endif
