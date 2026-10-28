#if os(macOS)
import AppKit
import SwiftUI

/// "Power Through New": every new Imbox email as one scrolling stack of cards, oldest first.
/// Each card ends in its own action bar; the card a third of the way down the window takes the keys.
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
    /// Measured email heights and sheet colors by thread, so a card the lazy stack rebuilds keeps its size.
    @State private var bodyHeights: [String: CGFloat] = [:]
    @State private var sheetColors: [String: Color] = [:]

    private var focused: String? { focusedID ?? threads.first?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    PageTitle(title: "Power Through New", subtitle: subtitle).padding(.top, 10).padding(.bottom, 28)
                    if threads.isEmpty {
                        caughtUp
                    } else {
                        LazyVStack(spacing: 24) {
                            ForEach(threads) { thread in
                                PowerThroughCard(thread: thread, isFocused: thread.id == focused,
                                                 bodyHeight: Binding { bodyHeights[thread.id] } set: { bodyHeights[thread.id] = $0 },
                                                 sheetColor: Binding { sheetColors[thread.id] } set: { sheetColors[thread.id] = $0 },
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
                            Label("Mark all as seen", systemImage: "eye").padding(.horizontal, 4)
                        }
                        .buttonStyle(PillButtonStyle(fill: Theme.raised, foreground: Theme.text))
                        .help("Move every email here to Previously Seen")
                        .padding(.top, 36)
                    }
                    Spacer(minLength: 90)
                }
                .frame(maxWidth: 860).frame(maxWidth: .infinity).padding(.horizontal, 40)
            }
            .scrollIndicators(.automatic)
            // A card j/k brings to the top stops just short of the edge.
            .safeAreaPadding(.top, 16)
            .onChange(of: scrollRequest) { _, id in
                guard let id else { return }
                scrollRequest = nil
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        // Bodies for the card in view and the next few, fetched together before they scroll in.
        .task(id: focused) {
            guard let start = threads.firstIndex(where: { $0.id == focused }) else { return }
            try? await store.hydrateBodies(of: Array(threads[start..<min(start + 4, threads.count)]))
        }
    }

    private var subtitle: String? {
        threads.isEmpty ? nil : threads.count == 1 ? "1 new email" : "\(threads.count) new emails"
    }

    private var caughtUp: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.secondary)
            Text("You’re all caught up.").font(.system(size: 17, weight: .semibold))
            Button { store.endPowerThrough() } label: { Label("Back to the Imbox", systemImage: "chevron.left") }
                .buttonStyle(PillButtonStyle(fill: Theme.back, foreground: Color(hex: 0x10372B))).padding(.top, 6)
        }
        .padding(.vertical, 60).frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
    }
}

/// One new email: subject and sender, the latest message (cut short until "Show full email"), then its actions.
private struct PowerThroughCard: View {
    @Environment(AppStore.self) private var store
    var thread: MailThread
    var isFocused: Bool
    @Binding var bodyHeight: CGFloat?
    @Binding var sheetColor: Color?
    var compose: (MailMessage, MailComposeAction) -> Void
    var bubble: () -> Void
    var act: (MailRootView.ThreadAction) -> Void
    @State private var expanded = false
    /// The HTML body with its inline images, built once they're in rather than on every redraw.
    @State private var resolvedHTML: String?
    @State private var textHeight: CGFloat = 0
    @State private var bodyError: String?

    private static let inset: CGFloat = 28
    private static let collapsedHTML: CGFloat = 420
    private static let collapsedText: CGFloat = 300
    /// Content only a little taller than the cut is shown whole, rather than hiding a few lines behind a button.
    private static let slack: CGFloat = 120
    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    /// The newest real message; drafts never lead a card.
    private var message: MailMessage? {
        thread.messages.filter { !$0.labels.contains("DRAFT") && $0.draftID == nil }.max { $0.date < $1.date }
            ?? thread.latestMessage
    }
    private var isHTML: Bool { message?.html?.isEmpty == false }
    private var bodyText: String { message.map { $0.plainText.isEmpty ? $0.snippet : $0.plainText } ?? thread.snippet }
    private var htmlHeight: CGFloat { bodyHeight ?? 320 }
    private var fullHeight: CGFloat { isHTML ? htmlHeight : textHeight }
    private var collapsedHeight: CGFloat { isHTML ? Self.collapsedHTML : Self.collapsedText }
    private var isLong: Bool { fullHeight > collapsedHeight + Self.slack }
    private var isClipped: Bool { isLong && !expanded }
    private var earlierCount: Int { thread.messages.filter { $0.id != message?.id }.count }
    private var blocksImages: Bool {
        guard isHTML, let message else { return false }
        return !store.allowsRemoteImages(sender: message.from.email)
    }
    /// Set once the body is downloaded, so building the HTML waits for it.
    private var readyMessageID: String? { message.flatMap { $0.needsBodyHydration ? nil : $0.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, Self.inset).padding(.top, 24).padding(.bottom, 18)
            messageBody.padding(.horizontal, Self.inset)
            if hasDetails { details.padding(.horizontal, Self.inset).padding(.top, 14) }
            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 22)
            actionBar.padding(.horizontal, 20).padding(.vertical, 12)
                .background(Theme.window.opacity(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: Self.shape)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(isFocused ? Theme.back.opacity(0.4) : Theme.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .task(id: message?.id) { await hydrate() }
        .task(id: readyMessageID) { await resolveHTML() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { store.open(thread) } label: {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 23, weight: .bold)).multilineTextAlignment(.leading).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
            }.buttonStyle(QuietButtonStyle()).help("Open the whole thread (o)")
            if let message {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        MailSenderButton(message: message, avatarSize: 36)
                        Text("to \(message.to.map(\.displayName).joined(separator: ", "))")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                            .help(message.to.map(\.formatted).joined(separator: ", "))
                            .padding(.leading, 48)
                    }
                    Spacer(minLength: 12)
                    if blocksImages {
                        Button { Task { await store.setAllowsRemoteImages(sender: message.from.email, allowed: true) } } label: {
                            Label("Load images", systemImage: "photo").font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(QuietButtonStyle()).foregroundStyle(Theme.secondary)
                        .help("Always load remote images from \(message.from.email)")
                        Text("·").foregroundStyle(Theme.secondary.opacity(0.6))
                    }
                    Text(Theme.shortDate(message.date)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .help(message.date.formatted(date: .complete, time: .shortened))
                }
            }
        }
    }

    @ViewBuilder private var messageBody: some View {
        if let bodyError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.unread)
                Text("Couldn’t load this email: \(bodyError)").font(.callout).foregroundStyle(Theme.secondary)
                Button("Retry") { Task { await hydrate() } }.buttonStyle(QuietButtonStyle()).fontWeight(.semibold)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if let message, readyMessageID == nil || (isHTML && resolvedHTML == nil) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised.opacity(0.6))
                .frame(height: min(bodyHeight ?? 240, Self.collapsedHTML))
                .overlay { ProgressView().controlSize(.small) }
                .accessibilityLabel("Loading \(message.subject)")
        } else if let resolvedHTML, let message {
            let sheet = sheetColor ?? .white
            MailHTMLView(html: resolvedHTML, allowsRemoteImages: store.allowsRemoteImages(sender: message.from.email),
                         height: Binding { htmlHeight } set: { bodyHeight = $0 }, inset: 22, edgeColor: $sheetColor)
                .frame(height: htmlHeight)
                .frame(height: isClipped ? collapsedHeight : htmlHeight, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) { if isClipped { showMore(fading: sheet) } }
                .background(sheet)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // Keeps the sheet's edge where the card is white too (the light appearance).
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        } else {
            Text(bodyText)
                .font(.system(size: 15)).lineSpacing(4).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                .frame(height: isClipped ? collapsedHeight : nil, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) { if isClipped { showMore(fading: Theme.card) } }
        }
    }

    /// The cut fades into the email's own background, with the way to read the rest on top of it.
    private func showMore(fading color: Color) -> some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [color.opacity(0), color.opacity(0.9), color], startPoint: .top, endPoint: .bottom)
                .frame(height: 96).allowsHitTesting(false)
            Button { withAnimation(.easeOut(duration: 0.2)) { expanded = true } } label: {
                Label("Show full email", systemImage: "chevron.down")
                    .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14).frame(height: 30)
                    .foregroundStyle(Theme.text)
                    .background(Theme.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            }
            .buttonStyle(QuietButtonStyle()).padding(.bottom, 16)
        }
    }

    private var hasDetails: Bool {
        earlierCount > 0 || message?.attachments.isEmpty == false || (expanded && isLong)
    }

    /// Earlier messages and attachments open the whole thread; Show less folds a long email back.
    private var details: some View {
        HStack(spacing: 8) {
            if let message, !message.attachments.isEmpty {
                detail(message.attachments.count == 1 ? message.attachments[0].name : "\(message.attachments.count) attachments",
                       symbol: "paperclip") { store.open(thread) }
            }
            if earlierCount > 0 {
                detail(earlierCount == 1 ? "1 earlier message" : "\(earlierCount) earlier messages",
                       symbol: "text.bubble") { store.open(thread) }
            }
            Spacer(minLength: 0)
            if expanded && isLong {
                Button { withAnimation(.easeOut(duration: 0.2)) { expanded = false } } label: {
                    Label("Show less", systemImage: "chevron.up").font(.system(size: 12.5, weight: .medium))
                }.buttonStyle(QuietButtonStyle()).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func detail(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Theme.raised, in: Capsule())
        }
        .buttonStyle(QuietButtonStyle()).help("Open the whole thread")
    }

    /// Reply on its own at the leading edge; the ways to be done with the email together at the other.
    /// Narrow windows drop the key hints first, then the labels.
    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            actions(.full)
            actions(.compact)
            actions(.icon)
        }
    }

    private func actions(_ style: CardActionButton.Style) -> some View {
        HStack(spacing: 8) {
            if let message {
                CardActionButton(title: "Reply", symbol: "arrowshape.turn.up.left.fill", key: "R", style: style, prominent: true) {
                    compose(message, .reply)
                }
            }
            Spacer(minLength: 16)
            CardActionButton(title: "Set Aside", symbol: "pin", key: "A", style: style) { act(.setAside) }
            CardActionButton(title: "Bubble Up", symbol: "bubbles.and.sparkles", key: "Z", style: style, perform: bubble)
            CardActionButton(title: "Archive", symbol: "archivebox", key: "E", style: style) { act(.archive) }
            CardActionButton(title: "Seen", symbol: "eye", key: "S", style: style) { act(.seen) }
        }
    }

    private func hydrate() async {
        guard message?.needsBodyHydration == true else { return }
        bodyError = nil
        do { try await store.hydrateBodies(of: [thread]) }
        catch is CancellationError {}
        catch { bodyError = error.localizedDescription }
    }

    private func resolveHTML() async {
        guard let message, !message.needsBodyHydration, let html = message.html, !html.isEmpty else {
            resolvedHTML = nil
            return
        }
        var images: [String: Data] = [:]
        if html.localizedCaseInsensitiveContains("cid:") {
            for attachment in message.attachments {
                guard let contentID = attachment.contentID, attachment.mimeType.lowercased().hasPrefix("image/") else { continue }
                if let data = try? await store.attachmentData(attachment, message: message) { images[contentID] = data }
            }
        }
        guard !Task.isCancelled else { return }
        resolvedHTML = message.html(inliningImages: images)
    }
}

private struct CardActionButton: View {
    enum Style { case full, compact, icon }
    var title: String
    var symbol: String
    var key: String
    var style: Style
    var prominent = false
    var perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold))
                if style != .icon { Text(title).font(.system(size: 13, weight: .semibold)).fixedSize() }
                if style == .full {
                    Text(key).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .frame(minWidth: 17, minHeight: 17)
                        .foregroundStyle(prominent ? Color(hex: 0x10372B).opacity(0.65) : Theme.secondary)
                        .background(prominent ? Color.black.opacity(0.1) : Theme.window, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.leading, 11).padding(.trailing, style == .full ? 7 : 11)
            .frame(height: 32)
            .foregroundStyle(prominent ? Color(hex: 0x10372B) : Theme.text)
            .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(prominent ? .clear : Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(QuietButtonStyle()).onHover { hovering = $0 }
        .help("\(title) (\(key.lowercased()))").accessibilityLabel(title)
    }

    private var fill: Color {
        if prominent { return Theme.back.opacity(hovering ? 0.85 : 1) }
        return hovering ? Theme.hover : Theme.raised
    }
}
#endif
