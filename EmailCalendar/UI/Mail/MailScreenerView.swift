#if os(macOS)
import AppKit
import SwiftUI

struct MailScreenerView: View {
    @Environment(AppStore.self) private var store
    var threads: [MailThread]
    var select: (MailThread) -> Void

    private var senders: [MailThread] { Self.senders(threads) }

    /// One row per sender: their latest email, newest first.
    static func senders(_ threads: [MailThread]) -> [MailThread] {
        Dictionary(grouping: threads, by: { $0.sender.email.lowercased() }).values
            .compactMap { $0.max { $0.updatedAt < $1.updatedAt } }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        if senders.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.secondary)
                Text("Nobody waiting. New senders show up here first.").font(.callout).foregroundStyle(Theme.secondary)
            }.padding(.top, 40)
        } else {
            LazyVStack(spacing: 4) {
                let rows = senders
                ForEach(rows) { thread in
                    ScreenerSenderRow(thread: thread, isPicked: store.selection.contains(thread.id)) {
                        // Same as mail rows: ⇧ picks a range, ⌘ (or any click while some are picked) picks one.
                        let modifiers = NSEvent.modifierFlags
                        if modifiers.contains(.shift) { store.extendSelection(to: thread.id, in: rows.map(\.id)) }
                        else if modifiers.contains(.command) || !store.selection.isEmpty { store.toggleSelection(thread.id) }
                        else { select(thread) }
                    }
                }
            }
        }
    }
}

private struct ScreenerSenderRow: View {
    @Environment(AppStore.self) private var store
    var thread: MailThread
    var isPicked = false
    var select: () -> Void
    @State private var entireDomain = false
    @State private var isDeciding = false
    @State private var hovering = false

    private var domain: String { thread.sender.email.split(separator: "@").last.map(String.init) ?? "" }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    if isPicked || hovering {
                        PickCircle(isPicked: isPicked, size: 38) { store.toggleSelection(thread.id) }
                    } else {
                        Avatar(name: thread.sender.displayName, key: thread.sender.email, size: 38)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(thread.sender.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(entireDomain ? "everyone @\(domain)" : thread.sender.email)
                                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Text("\(thread.subject) – \(thread.snippet)").font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Preview this email")
            if isDeciding { ProgressView().controlSize(.small) }
            Button { decide(.approved) } label: { Label("Yes", systemImage: "hand.thumbsup.fill") }
                .buttonStyle(PillButtonStyle(fill: Theme.yes)).help("Let them into your Imbox")
            Button { decide(.blocked) } label: { Label("No", systemImage: "hand.thumbsdown.fill") }
                .buttonStyle(PillButtonStyle(fill: Theme.no)).help("Screen them out, also in Gmail")
        }
        .disabled(isDeciding || store.isApplyingBatch)
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(isPicked ? Theme.accent.opacity(0.16) : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .contextMenu {
            Toggle("Decide for everyone @\(domain)", isOn: $entireDomain)
            Button(isPicked ? "Unselect" : "Select") { store.toggleSelection(thread.id) }
        }
    }

    private func decide(_ decision: ScreeningDecision) {
        isDeciding = true
        let key = entireDomain ? "@\(domain)" : thread.sender.email
        Task {
            await store.decideSender(key: key, decision: decision)
            isDeciding = false
        }
    }
}

struct ScreenedSendersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var newSender = ""
    @State private var newDecision: ScreeningDecision = .approved
    @State private var busyKeys: Set<String> = []

    private var rules: [SenderRule] {
        store.senderRules.filter { query.isEmpty || $0.key.localizedCaseInsensitiveContains(query) }.sorted { $0.key < $1.key }
    }

    private var newKey: String {
        let value = newSender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.contains("@") ? value : "@\(value)"
    }

    private var validNewKey: Bool {
        let key = newKey
        return key.count > 3 && key.contains(".") && !key.contains(where: { $0.isWhitespace }) && !key.contains("\n") &&
            key.filter { $0 == "@" }.count == 1 && key.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789@._+-").contains($0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Screened senders").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Find an address or domain", text: $query).textFieldStyle(.roundedBorder)
            List(rules) { rule in
                HStack {
                    Image(systemName: rule.isDomain ? "globe" : "person.crop.circle").foregroundStyle(.secondary)
                    Text(rule.key)
                    Spacer()
                    if busyKeys.contains(rule.key) { ProgressView().controlSize(.small) }
                    Menu(rule.decision == .approved ? "Approved" : "Screened out") {
                        Button("Approve") { change(rule.key, to: .approved) }
                        Button("Screen out") { change(rule.key, to: .blocked) }
                    }.disabled(busyKeys.contains(rule.key))
                }.padding(.vertical, 4)
            }
            HStack {
                TextField("Address or domain", text: $newSender).textFieldStyle(.roundedBorder)
                Picker("Decision", selection: $newDecision) {
                    Text("Approve").tag(ScreeningDecision.approved)
                    Text("Screen out").tag(ScreeningDecision.blocked)
                }.labelsHidden().frame(width: 130)
                Button("Add") { change(newKey, to: newDecision); newSender = "" }.disabled(!validNewKey)
            }
            Text("Changing a screened-out sender to approved also removes their Gmail rejection filter.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20).frame(width: 640, height: 480)
    }

    private func change(_ key: String, to decision: ScreeningDecision) {
        busyKeys.insert(key)
        Task { await store.decideSender(key: key, decision: decision); busyKeys.remove(key) }
    }
}
#endif
