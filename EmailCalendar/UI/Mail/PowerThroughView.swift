#if os(macOS)
import AppKit
import SwiftUI

/// "Power Through New": every new Imbox email as one scrolling stack of cards, oldest first.
/// Each card carries its own action rail, which rides the bottom of the window while the card is on screen.
struct PowerThroughPage: View {
    @Environment(AppStore.self) private var store
    var threads: [MailThread]
    /// The card the keyboard acts on: the one under a line a third of the way down the window.
    @Binding var focusedID: String?
    /// Set to scroll a card to the top (j/k); cleared once handled.
    @Binding var scrollRequest: String?
    var compose: (MailMessage, MailComposeAction) -> Void
    var bubble: (MailThread) -> Void
    var act: (MailThread, MailRootView.ThreadAction) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    PageTitle(title: "Power Through New").padding(.top, 26).padding(.bottom, 30)
                    if threads.isEmpty {
                        caughtUp
                    } else {
                        LazyVStack(spacing: 44) {
                            ForEach(threads) { thread in
                                PowerThroughCard(thread: thread, isFocused: thread.id == (focusedID ?? threads.first?.id),
                                                 compose: compose, bubble: { bubble(thread) }, act: { act(thread, $0) })
                                    .id(thread.id)
                                    .onGeometryChange(for: Bool.self) { geometry in
                                        guard let viewport = geometry.bounds(of: .scrollView) else { return false }
                                        let line = viewport.minY + viewport.height / 3
                                        return line >= 0 && line < geometry.size.height
                                    } action: { underLine in
                                        if underLine { focusedID = thread.id }
                                    }
                                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.97))))
                            }
                        }
                        .animation(.easeOut(duration: 0.22), value: threads.map(\.id))
                        Button { Task { await store.markAllSeen(threads) } } label: {
                            Text("Mark all as seen").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .buttonStyle(PillButtonStyle(fill: Theme.rule)).help("Move every email here to Previously Seen")
                        .padding(.top, 40)
                    }
                    Spacer(minLength: 90)
                }
                .frame(maxWidth: 880).frame(maxWidth: .infinity).padding(.horizontal, 64)
            }
            .scrollIndicators(.automatic)
            .onChange(of: scrollRequest) { _, id in
                guard let id else { return }
                scrollRequest = nil
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private var caughtUp: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.secondary)
            Text("You’re all caught up.").font(.system(size: 17, weight: .semibold))
            Button { store.endPowerThrough() } label: { Label("Back to the Imbox", systemImage: "chevron.left") }
                .buttonStyle(PillButtonStyle(fill: Theme.back, foreground: Color(hex: 0x10372B))).padding(.top, 6)
        }
        .padding(.vertical, 60).frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28))
    }
}

/// One new email: subject, sender, the latest message (clipped until "See more…"), and the rail.
private struct PowerThroughCard: View {
    @Environment(AppStore.self) private var store
    var thread: MailThread
    var isFocused: Bool
    var compose: (MailMessage, MailComposeAction) -> Void
    var bubble: () -> Void
    var act: (MailRootView.ThreadAction) -> Void
    @State private var expanded = false
    @State private var htmlHeight: CGFloat = 200
    @State private var inlineImages: [String: Data] = [:]

    private static let collapsedHeight: CGFloat = 440
    private static let railWidth: CGFloat = 84
    private static let railHeight: CGFloat = 5 * RailButton.height + 4 * 6
    /// Leaves room for the rail beside the message.
    private static let trailingPadding: CGFloat = 66

    /// The newest real message; drafts never lead a card.
    private var message: MailMessage? {
        thread.messages.filter { !$0.labels.contains("DRAFT") && $0.draftID == nil }.max { $0.date < $1.date }
            ?? thread.latestMessage
    }
    private var html: String? {
        guard let html = message?.html(inliningImages: inlineImages), !html.isEmpty else { return nil }
        return html
    }
    private var bodyText: String { message.map { $0.plainText.isEmpty ? $0.snippet : $0.plainText } ?? thread.snippet }
    private var isClipped: Bool {
        guard !expanded else { return false }
        return html != nil ? htmlHeight > Self.collapsedHeight : bodyText.count > 900 || bodyText.filter(\.isNewline).count > 14
    }
    private var earlierCount: Int { thread.messages.filter { $0.id != message?.id }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.open(thread) } label: {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 28, weight: .bold)).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
            }.buttonStyle(QuietButtonStyle()).help("Open the whole thread (o)")
            if let message { sender(message).padding(.top, 12).padding(.bottom, 14) }
            messageBody
            footer.padding(.top, 14)
        }
        .padding(.top, 36).padding(.bottom, 30).padding(.leading, 44).padding(.trailing, Self.trailingPadding)
        .frame(maxWidth: .infinity, minHeight: Self.railHeight + 150, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28))
        .overlay(alignment: .topTrailing) { stickyRail }
        .task(id: message?.id) {
            guard let message else { return }
            for attachment in message.attachments {
                guard let contentID = attachment.contentID, attachment.mimeType.lowercased().hasPrefix("image/"),
                      inlineImages[contentID] == nil else { continue }
                if let data = try? await store.attachmentData(attachment, message: message) { inlineImages[contentID] = data }
            }
        }
    }

    private func sender(_ message: MailMessage) -> some View {
        HStack(spacing: 12) {
            Avatar(name: message.from.displayName, key: message.from.email, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.from.displayName).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text("to \(message.to.map(\.formatted).joined(separator: ", ")) · \(Theme.shortDate(message.date))")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary).lineLimit(1)
                    .help(message.date.formatted(date: .complete, time: .shortened))
            }
        }
    }

    @ViewBuilder private var messageBody: some View {
        if let html, let message {
            MailHTMLView(html: html, allowsRemoteImages: store.allowsRemoteImages(sender: message.from.email), height: $htmlHeight)
                .frame(height: htmlHeight)
                .frame(height: expanded ? htmlHeight : min(htmlHeight, Self.collapsedHeight), alignment: .top)
                .clipped()
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 22))
                .clipShape(RoundedRectangle(cornerRadius: 22))
        } else {
            Text(bodyText)
                .font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                .lineLimit(isClipped ? 14 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if isClipped {
                Button("See more…") { withAnimation(.easeOut(duration: 0.2)) { expanded = true } }
                    .buttonStyle(OutlineCapsuleStyle())
            }
            if earlierCount > 0 {
                Button(earlierCount == 1 ? "1 earlier message" : "\(earlierCount) earlier messages") { store.open(thread) }
                    .buttonStyle(OutlineCapsuleStyle())
            }
            if let message, !message.attachments.isEmpty {
                Button { store.open(thread) } label: {
                    Label(message.attachments.count == 1 ? message.attachments[0].name : "\(message.attachments.count) attachments",
                          systemImage: "paperclip").lineLimit(1)
                }.buttonStyle(OutlineCapsuleStyle())
            }
            Spacer(minLength: 0)
            if html != nil, let message, !store.allowsRemoteImages(sender: message.from.email) {
                Button("Load images") { Task { await store.setAllowsRemoteImages(sender: message.from.email, allowed: true) } }
                    .buttonStyle(QuietButtonStyle()).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .help("Always load remote images from \(message.from.email)")
            }
        }
    }

    /// The rail rides the bottom of the window, but never leaves its card: it stops at the card's
    /// bottom edge, and below the subject when the card is only just scrolling in.
    private var stickyRail: some View {
        GeometryReader { geometry in
            let cardBottom = geometry.size.height - Self.railHeight - 30
            let windowBottom = (geometry.bounds(of: .scrollView)?.maxY ?? geometry.size.height) - Self.railHeight - 24
            rail.offset(x: Self.railWidth / 2 - 4, y: max(0, min(cardBottom, max(150, windowBottom))))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var rail: some View {
        VStack(spacing: 6) {
            if let message {
                RailButton(title: "Reply", symbol: "arrowshape.turn.up.left.fill", key: "R", showsKey: isFocused) { compose(message, .reply) }
            }
            RailButton(title: "Aside", symbol: "pin.fill", key: "A", showsKey: isFocused) { act(.setAside) }
            RailButton(title: "Bubble", symbol: "bubbles.and.sparkles.fill", key: "Z", showsKey: isFocused, perform: bubble)
            RailButton(title: "Archive", symbol: "archivebox.fill", key: "E", showsKey: isFocused) { act(.archive) }
            RailButton(title: "Seen", symbol: "eye.fill", key: "S", showsKey: isFocused) { act(.seen) }
        }
        .frame(width: Self.railWidth, height: Self.railHeight, alignment: .top)
    }
}

private struct RailButton: View {
    static let height: CGFloat = 62
    var title: String
    var symbol: String
    var key: String
    var showsKey: Bool
    var perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(height: 18)
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .frame(width: 84, height: Self.height)
            .overlay(alignment: .topTrailing) {
                if showsKey {
                    Text(key).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary.opacity(0.8))
                        .padding(.top, 5).padding(.trailing, 7)
                }
            }
            .background(hovering ? Theme.hover : Theme.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hovering ? Theme.back.opacity(0.7) : Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help("\(title) (\(key.lowercased()))")
    }
}

private struct OutlineCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1).contentShape(Capsule())
    }
}
#endif
