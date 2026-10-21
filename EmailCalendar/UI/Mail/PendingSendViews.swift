#if os(macOS)
import SwiftUI

/// "Sending in 24s · Interview follow-up · Undo", over mail and calendar alike. The newest pending
/// email is shown; with more, a "2 pending" button lists them all, each with its own timer.
struct PendingSendBar: View {
    @Environment(AppStore.self) private var store
    @State private var showsList = false
    @State private var preview: PendingSend?

    private var active: [PendingSend] { store.activePendingSends }

    var body: some View {
        Group {
            if let newest = active.max(by: { $0.sendAt < $1.sendAt }) {
                VStack(spacing: 6) {
                    if store.isQuitting {
                        Text("Finishing pending emails before quitting").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    }
                    HStack(spacing: 14) {
                        PendingSendRow(pending: newest, showsSendNow: store.isQuitting) { preview = newest }
                        if active.count > 1 {
                            Button("\(active.count) pending") { showsList.toggle() }
                                .buttonStyle(QuietButtonStyle()).fontWeight(.semibold).foregroundStyle(.white.opacity(0.85))
                                .popover(isPresented: $showsList, arrowEdge: .top) { list }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Theme.actionBar, in: Capsule()).shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            } else if let sent = store.sentConfirmation {
                HStack(spacing: 14) {
                    Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.back)
                    Text(sent.subject.isEmpty ? "(no subject)" : sent.subject).lineLimit(1).foregroundStyle(.white)
                    Button("View") { Task { await store.openLinkedThread(id: sent.threadID) } }
                        .buttonStyle(QuietButtonStyle()).fontWeight(.semibold).foregroundStyle(Theme.back)
                }
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Theme.actionBar, in: Capsule()).shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            }
        }
        .frame(maxWidth: 560)
        .animation(.easeOut(duration: 0.15), value: active.map(\.draftID))
        .sheet(item: $preview) { PendingSendPreview(draftID: $0.draftID).environment(store) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(active.sorted { $0.sendAt < $1.sendAt }) { pending in
                PendingSendRow(pending: pending, showsSendNow: true) { showsList = false; preview = pending }
            }
        }
        .padding(14).frame(width: 440)
    }
}

/// One pending email: its countdown, subject (opens the preview), Undo, and optionally Send now.
private struct PendingSendRow: View {
    @Environment(AppStore.self) private var store
    var pending: PendingSend
    var showsSendNow = false
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PendingCountdown(pending: pending).foregroundStyle(.white.opacity(0.85))
            Button(action: open) {
                Text(pending.subject.isEmpty ? "(no subject)" : pending.subject).lineLimit(1).foregroundStyle(.white)
            }.buttonStyle(QuietButtonStyle()).help("Preview this email")
            Spacer(minLength: 4)
            if pending.status == .waiting {
                if showsSendNow {
                    Button("Send now") { Task { await store.sendPendingNow(pending.draftID) } }
                        .buttonStyle(QuietButtonStyle()).foregroundStyle(.white.opacity(0.85))
                }
                Button("Undo") { Task { await store.undoPendingSend(pending.draftID) } }
                    .buttonStyle(QuietButtonStyle()).fontWeight(.semibold).foregroundStyle(Theme.back)
            }
        }
    }
}

/// "Sending in 24s", then "Sending…" once the countdown ends and the email is handed to Gmail.
private struct PendingCountdown: View {
    var pending: PendingSend

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(pending.sendAt.timeIntervalSince(context.date).rounded(.up))
            if pending.status == .sending || seconds <= 0 {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…") }
            } else {
                Text("Sending in \(seconds)s").monospacedDigit()
            }
        }
    }
}

/// Read-only view of a pending email. The countdown keeps running; Undo opens it for editing.
private struct PendingSendPreview: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var draftID: String

    private var pending: PendingSend? { store.pendingSends.first { $0.draftID == draftID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let pending { PendingCountdown(pending: pending).foregroundStyle(Theme.secondary) }
                else { Text("Sent").foregroundStyle(Theme.secondary) }
                Spacer()
                if let pending, pending.status == .waiting {
                    Button("Send now") { Task { await store.sendPendingNow(draftID) } }.buttonStyle(PillButtonStyle(fill: .white.opacity(0.1)))
                    Button("Undo") { dismiss(); Task { await store.undoPendingSend(draftID) } }.buttonStyle(PillButtonStyle(fill: Theme.accent))
                }
                Button("Close") { dismiss() }.buttonStyle(PillButtonStyle(fill: .white.opacity(0.1))).keyboardShortcut(.cancelAction)
            }
            if let pending {
                Text(pending.subject.isEmpty ? "(no subject)" : pending.subject).font(.system(size: 22, weight: .bold))
                if let from = pending.from { Text("From \(from)").font(.callout).foregroundStyle(Theme.secondary) }
            }
            ScrollView {
                if let message = store.pendingDraftMessage(draftID) {
                    MailMessageCard(message: message, isLatest: true, initiallyExpanded: true) { _, _ in }
                } else {
                    Text("The email is saved in Gmail's Drafts.").foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(24).frame(width: 720, height: 560)
        .background(Theme.card)
        // Once it has been sent, or undone elsewhere, the preview has nothing left to show.
        .onChange(of: pending == nil) { _, gone in if gone { dismiss() } }
    }
}

/// Emails that weren't sent, or may not have been, stay listed at the top of the Imbox until resolved.
struct PendingSendNotice: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let items = store.unresolvedPendingSends
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "1 email wasn’t sent" : "\(items.count) emails weren’t sent").font(.system(size: 15, weight: .bold))
            ForEach(items) { pending in
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(pending.subject.isEmpty ? "(no subject)" : pending.subject)”").fontWeight(.semibold)
                    if pending.status == .uncertain {
                        Text(store.checkingPendingSends.contains(pending.draftID) ? "Checking whether this email was sent…"
                             : "Gmail may have sent it, but the confirmation was lost. It won’t be sent again until it’s been checked.")
                            .font(.callout).foregroundStyle(Theme.secondary)
                        HStack(spacing: 16) {
                            Button("Check again") { Task { await store.checkPendingSend(pending.draftID) } }
                                .disabled(store.checkingPendingSends.contains(pending.draftID))
                            Button("Dismiss") { Task { await store.dismissPendingSend(pending.draftID) } }
                                .help("Stop tracking it. Check your Sent mail first.")
                        }.buttonStyle(QuietButtonStyle()).font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                    } else {
                        if let failure = pending.failure { Text(failure).font(.callout).foregroundStyle(Theme.secondary) }
                        HStack(spacing: 16) {
                            Button("Review email") { Task { await store.undoPendingSend(pending.draftID) } }
                            Button("Retry") { Task { await store.retryPendingSend(pending.draftID) } }
                                .help("Starts a new \(Int(AppStore.undoSendDelay))-second countdown")
                            Button("Move to Drafts") { Task { await store.dismissPendingSend(pending.draftID) } }
                        }.buttonStyle(QuietButtonStyle()).font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.no.opacity(0.5)))
    }
}
#endif
