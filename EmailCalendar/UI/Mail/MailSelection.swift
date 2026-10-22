#if os(macOS)
import SwiftUI

/// What the selection bar, a picked row's menu and the palette offer for several emails at once.
struct MailBulkCommand: Identifiable {
    var action: MailRootView.ThreadAction
    var title: String
    var symbol: String
    var shortcut = ""
    var id: String { title }

    static func all(for threads: [MailThread]) -> [MailBulkCommand] {
        let aside = threads.allSatisfy(\.isSetAside)
        let unread = threads.contains(where: \.unread)
        let spam = threads.allSatisfy(\.hasSpam)
        return [
            MailBulkCommand(action: .archive, title: "Archive", symbol: "archivebox", shortcut: "e"),
            MailBulkCommand(action: .setAside, title: aside ? "Return to Imbox" : "Set Aside", symbol: aside ? "tray.and.arrow.up" : "pin", shortcut: "a"),
            MailBulkCommand(action: .bubbleUp, title: "Bubble Up…", symbol: "bubbles.and.sparkles", shortcut: "z"),
            MailBulkCommand(action: .toggleRead, title: unread ? "Mark Read" : "Mark Unread", symbol: unread ? "envelope.open" : "envelope.badge"),
            MailBulkCommand(action: spam ? .notSpam : .spam, title: spam ? "Not Spam" : "Spam", symbol: spam ? "checkmark.shield" : Mailbox.spam.symbol),
            MailBulkCommand(action: .trash, title: "Trash", symbol: "trash")
        ]
    }
}

/// The round tick that stands in for a row's avatar while hovering, or once the row is picked.
struct PickCircle: View {
    var isPicked: Bool
    var size: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isPicked ? Theme.accent : .clear)
                Circle().stroke(isPicked ? Theme.accent : Theme.secondary.opacity(0.7), lineWidth: 1.5)
                if isPicked { Image(systemName: "checkmark").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isPicked ? "Unselect (x)" : "Select (x, ⌘-click, ⇧-click for a range)")
    }
}

/// "3 selected · Archive · Set Aside · … · ✕", floating at the bottom of a mailbox while rows are picked.
struct MailSelectionBar: View {
    @Environment(AppStore.self) private var store
    var threads: [MailThread]
    var total: Int
    var selectAll: () -> Void
    var act: (MailRootView.ThreadAction, [MailThread]) -> Void

    var body: some View {
        SelectionCapsule(count: threads.count, noun: "selected", total: total, selectAll: selectAll) {
            ViewThatFits(in: .horizontal) {
                buttons(labeled: true)
                buttons(labeled: false)
            }
        }
    }

    private func buttons(labeled: Bool) -> some View {
        HStack(spacing: labeled ? 14 : 16) {
            ForEach(MailBulkCommand.all(for: threads)) { command in
                Button { act(command.action, threads) } label: {
                    if labeled { Label(command.title, systemImage: command.symbol) } else { Image(systemName: command.symbol) }
                }
                .help(command.shortcut.isEmpty ? command.title : "\(command.title) (\(command.shortcut))")
                .foregroundStyle(command.action == .trash ? Theme.no : .white.opacity(0.9))
            }
        }
        .buttonStyle(QuietButtonStyle()).fixedSize()
    }
}

/// The Screener's version: Yes or No for every picked sender.
struct ScreenerSelectionBar: View {
    @Environment(AppStore.self) private var store
    var threads: [MailThread]
    var total: Int
    var selectAll: () -> Void

    var body: some View {
        SelectionCapsule(count: threads.count, noun: threads.count == 1 ? "sender" : "senders", total: total, selectAll: selectAll) {
            HStack(spacing: 10) {
                Button { decide(.approved) } label: { Label("Yes", systemImage: "hand.thumbsup.fill") }
                    .buttonStyle(PillButtonStyle(fill: Theme.yes)).help("Let them all into your Imbox")
                Button { decide(.blocked) } label: { Label("No", systemImage: "hand.thumbsdown.fill") }
                    .buttonStyle(PillButtonStyle(fill: Theme.no)).help("Screen them all out, also in Gmail")
            }
        }
    }

    private func decide(_ decision: ScreeningDecision) {
        let keys = threads.map { $0.sender.email.lowercased() }
        Task { await store.decideSenders(keys: keys, decision: decision) }
    }
}

private struct SelectionCapsule<Actions: View>: View {
    @Environment(AppStore.self) private var store
    var count: Int
    var noun: String
    var total: Int
    var selectAll: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                if store.isApplyingBatch { ProgressView().controlSize(.small) }
                Text("\(count) \(noun)").fontWeight(.semibold).foregroundStyle(.white).fixedSize()
            }
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 18)
            actions
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 18)
            if count < total {
                Button("All", action: selectAll).buttonStyle(QuietButtonStyle()).foregroundStyle(Theme.back)
                    .help("Select everything in this list (⌘A)")
            }
            Button { store.clearSelection() } label: { Image(systemName: "xmark") }
                .buttonStyle(QuietButtonStyle()).foregroundStyle(.white.opacity(0.7)).help("Clear selection (esc)")
        }
        .font(.system(size: 13.5))
        .disabled(store.isApplyingBatch)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.actionBar, in: Capsule()).shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .padding(.horizontal, 24).padding(.bottom, 22)
    }
}
#endif
