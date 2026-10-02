#if os(macOS)
import SwiftUI

struct MailScreenerView: View {
    @Environment(AppStore.self) private var store
    var threads: [MailThread]
    var select: (MailThread) -> Void

    private var senders: [MailThread] {
        Dictionary(grouping: threads, by: { $0.sender.email.lowercased() }).values
            .compactMap { $0.max { $0.updatedAt < $1.updatedAt } }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        if senders.isEmpty {
            ContentUnavailableView("All screened", systemImage: "person.crop.circle.badge.checkmark",
                description: Text("New senders will appear here. You decide who reaches your Imbox."))
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    Text("Who gets your attention?").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Approve a sender to move their mail to the Imbox. Screen them out to keep future messages out of Gmail's inbox, too.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(senders) { thread in
                        ScreenerSenderRow(thread: thread) { select(thread) }
                    }
                }.padding(16)
            }
        }
    }
}

private struct ScreenerSenderRow: View {
    @Environment(AppStore.self) private var store
    var thread: MailThread
    var select: () -> Void
    @State private var entireDomain = false
    @State private var isDeciding = false

    private var domain: String { thread.sender.email.split(separator: "@").last.map(String.init) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.sender.displayName).font(.headline)
                    Text(thread.sender.email).font(.caption).foregroundStyle(.secondary)
                    Text(thread.subject).font(.callout).lineLimit(1).padding(.top, 3)
                    Text(thread.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle("Entire @\(domain) domain", isOn: $entireDomain).toggleStyle(.checkbox).font(.caption)
            HStack(spacing: 10) {
                Button { decide(.approved) } label: { Label("Yes", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { decide(.blocked) } label: { Label("No", systemImage: "xmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                if isDeciding { ProgressView().controlSize(.small) }
            }.controlSize(.large).disabled(isDeciding)
        }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
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
