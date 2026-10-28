#if os(macOS)
import SwiftUI
import AppKit

/// One centered column. Navigation lives in the menu under the logo (press h), not in a sidebar.
struct AppShellView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var showsMenu = false
    @State private var showsAccount = false
    @State private var searching = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Theme.window.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if let message = store.errorMessage { errorBanner(message) }
                Group {
                    if !store.isSignedIn {
                        WelcomeView()
                    } else if store.navigation == .calendar {
                        page(maxWidth: 1180) { CalendarMainView() }
                    } else {
                        MailWorkspace(searchFocus: { beginSearch() })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if showsMenu {
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { showsMenu = false }
                JumpMenu(isPresented: $showsMenu).padding(.top, 50)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: showsMenu)
        .foregroundStyle(Theme.text)
        .disabled(store.isQuitting)
        // Outside the disabled shell, so pending emails can still be previewed, sent or undone while quitting.
        .overlay(alignment: .bottom) {
            if store.isSignedIn {
                PendingSendBar().padding(.bottom, store.navigation == .calendar ? 20 : 140).padding(.horizontal, 24)
            }
        }
        .background(MailKeyboardMonitor(enabled: store.isSignedIn, handle: handleShellKey).frame(width: 0, height: 0))
        .onAppear { store.openWindow = { openWindow(id: "main") } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await store.refresh() }
        }
        .onChange(of: store.navigation) { _, _ in
            store.closeThread()
            if !store.searchQuery.isEmpty { endSearch() }
        }
        .onChange(of: store.searchQuery) { _, query in
            if !query.isEmpty, !searching { searching = true; searchText = query }
        }
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 14) {
                if showsBack {
                    Button(action: goBack) {
                        Label(backTitle, systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(PillButtonStyle(fill: Theme.back, foreground: Color(hex: 0x10372B)))
                    .help("Back (Esc)")
                }
                if searching {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                        TextField("Search mail", text: $searchText).textFieldStyle(.plain).focused($searchFocused).frame(width: 220)
                            .onSubmit { searchFocused = false; Task { await store.search(searchText) } }
                            .onKeyPress(.escape) { endSearch(); return .handled }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.raised, in: Capsule())
                } else if store.isSignedIn {
                    Button { beginSearch() } label: {
                        Label("Search", systemImage: "magnifyingglass").font(.system(size: 15, weight: .medium))
                    }.buttonStyle(QuietButtonStyle()).help("Search (/)")
                }
                Spacer()
                if store.isSignedIn && store.navigation != .calendar { drawerToggles }
                if store.isSignedIn { accountMenu }
            }
            if store.isSignedIn {
                Button { showsMenu.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar").font(.system(size: 17, weight: .semibold))
                        Text("·").font(.system(size: 17, weight: .bold))
                        Image(systemName: "envelope.fill").font(.system(size: 17, weight: .semibold))
                        Image(systemName: showsMenu ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Theme.menuGradient)
                    .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Go to… (h)")
            }
        }
        .padding(.horizontal, 26).frame(height: 54)
    }

    /// Days and To-do: which drawer is beside mail. Same as ← / → or a two-finger swipe.
    private var drawerToggles: some View {
        HStack(spacing: 2) {
            drawerToggle(side: 1, symbol: "calendar", title: "Days", key: "←")
            drawerToggle(side: -1, symbol: "checklist", title: "To-do", key: "→")
        }
        .padding(2)
        .background(Theme.raised, in: Capsule())
    }

    private func drawerToggle(side: Int, symbol: String, title: String, key: String) -> some View {
        let isOn = store.drawerPosition == side
        return Button { withAnimation(MailWorkspace.settle) { store.toggleDrawer(side) } } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 24)
                .background(isOn ? Theme.card : .clear, in: Capsule())
                .foregroundStyle(isOn ? Theme.text : Theme.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(isOn ? "Hide" : "Show") \(title) (\(key))")
        .accessibilityLabel(title).accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var showsBack: Bool {
        store.isSignedIn && !store.isComposing && (store.openThreadID != nil || store.poweringThrough || store.navigation != .imbox || !store.searchQuery.isEmpty)
    }

    /// A popover rather than a Menu: macOS menus flatten custom labels, which would lose the avatar.
    private var accountMenu: some View {
        Button { showsAccount.toggle() } label: {
            Avatar(name: store.account?.displayName.isEmpty == false ? store.account!.displayName : store.accountEmail,
                   key: store.accountEmail, size: 30)
        }
        .buttonStyle(.plain).help(store.accountEmail)
        .popover(isPresented: $showsAccount, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.isDemoMode ? "Demo · \(store.accountEmail)" : store.accountEmail)
                    .font(.caption).foregroundStyle(Theme.secondary).padding(.horizontal, 8).padding(.bottom, 4)
                accountItem("Refresh", symbol: "arrow.clockwise") { Task { await store.refresh() } }
                if store.isDemoMode {
                    accountItem("Simulate incoming email", symbol: "envelope.badge") { Task { await store.simulateIncomingMail() } }
                }
                SettingsLink {
                    Label("Preferences…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(QuietButtonStyle())
                    .simultaneousGesture(TapGesture().onEnded { showsAccount = false })
            }
            .padding(10).frame(width: 240)
        }
    }

    private func accountItem(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button { showsAccount = false; perform() } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle())
    }

    private var backTitle: String {
        if store.openThreadID != nil {
            if store.poweringThrough { return "Power Through" }
            return store.navigation == .imbox ? "Back" : store.navigation.title
        }
        return "Imbox"
    }

    private func goBack() {
        if store.openThreadID != nil { store.closeThread() }
        else if store.poweringThrough { store.endPowerThrough() }
        else if !store.searchQuery.isEmpty { endSearch() }
        else { store.navigation = .imbox }
    }

    private func beginSearch() {
        searching = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private func endSearch() {
        searching = false; searchText = ""; searchFocused = false
        Task { await store.search("") }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.unread)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button("Retry") { Task { await store.refresh() } }.buttonStyle(QuietButtonStyle())
            Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(QuietButtonStyle())
        }
        .padding(12).background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 790).padding(.bottom, 8)
    }

    private func page<Content: View>(maxWidth: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 26))
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .frame(maxWidth: maxWidth).padding(.horizontal, 24).padding(.bottom, 20)
    }

    private func handleShellKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53 {
            if showsMenu { showsMenu = false; return true }
            if store.navigation == .calendar { store.navigation = .imbox; return true }
            // On the results list itself; anything on top of it (thread, picked rows, linking) closes first.
            if !store.searchQuery.isEmpty, store.openThreadID == nil, !store.isComposing, !store.poweringThrough,
               store.selection.isEmpty, store.linkingThreadID == nil { endSearch(); return true }
            return false
        }
        if event.charactersIgnoringModifiers?.lowercased() == "h" { showsMenu.toggle(); return true }
        return showsMenu
    }
}

/// The logo menu: numbered destinations, then everything else. Type to filter or search.
struct JumpMenu: View {
    @Environment(AppStore.self) private var store
    @Binding var isPresented: Bool
    @State private var filter = ""
    @FocusState private var focused: Bool
    @State private var showsScreenedSenders = false

    private struct Item: Identifiable {
        var id: String { title }
        var title: String
        var symbol: String
        var action: () -> Void
    }

    /// The number row without Shift on Czech (+ěščřž) and French (&é"'(-) keyboards, so 1–6 work there too.
    private static let unshiftedDigits: [String: Int] = ["+": 1, "ě": 2, "š": 3, "č": 4, "ř": 5, "ž": 6,
                                                         "&": 1, "é": 2, "\"": 3, "'": 4, "(": 5, "-": 6]
    private static let numberRow = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: unshiftedDigits.keys.joined()))

    private var tiles: [(Mailbox, Int)] {
        [(.imbox, 1), (.calendar, 2), (.screener, 3), (.setAside, 4), (.bubbleUp, 5), (.drafts, 6)]
    }

    private var listItems: [Item] {
        [Item(title: "Sent", symbol: "paperplane") { go(.sent) },
         Item(title: "Screened Out", symbol: "hand.raised") { go(.screenedOut) },
         Item(title: store.unreadSpamCount > 0 ? "Spam (\(store.unreadSpamCount) new)" : "Spam", symbol: Mailbox.spam.symbol) { go(.spam) },
         Item(title: "Everything", symbol: "tray.full") { go(.allMail) },
         Item(title: "Screened senders", symbol: "person.crop.circle.badge.checkmark") { showsScreenedSenders = true },
         Item(title: "Write a new email", symbol: "square.and.pencil") { isPresented = false; store.composeRequest = UUID() }]
    }

    private var filteredItems: [Item] {
        let tileItems = tiles.map { mailbox, _ in Item(title: mailbox.title, symbol: mailbox.symbol) { go(mailbox) } }
        return (tileItems + listItems).filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Press h to open this menu from anywhere")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.white.opacity(0.7))
                TextField("", text: $filter, prompt: Text("Type to go somewhere, or search mail…").foregroundStyle(.white.opacity(0.6)))
                    .textFieldStyle(.plain).foregroundStyle(.white).focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.escape) { isPresented = false; return .handled }
                    .onKeyPress(characters: Self.numberRow) { press in
                        guard filter.isEmpty, let number = Int(press.characters) ?? Self.unshiftedDigits[press.characters],
                              let tile = tiles.first(where: { $0.1 == number }) else { return .ignored }
                        go(tile.0); return .handled
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "hH")) { _ in
                        guard filter.isEmpty else { return .ignored }
                        isPresented = false; return .handled
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.25), in: Capsule())

            if filter.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(tiles, id: \.1) { mailbox, number in
                        Button { go(mailbox) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: mailbox.symbol).font(.system(size: 18, weight: .semibold))
                                Text(mailbox.title).font(.system(size: 13, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).frame(height: 66)
                            .background(.white.opacity(store.navigation == mailbox ? 0.32 : 0.18), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                Text("\(number)").font(.system(size: 10, weight: .semibold)).opacity(0.8).padding(7)
                            }
                            .overlay(alignment: .topLeading) {
                                if let count = badge(for: mailbox) {
                                    Text("\(count)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.unread, in: Capsule()).foregroundStyle(.black).padding(6)
                                }
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Text("YOUR").font(.system(size: 11, weight: .semibold)).opacity(0.75).padding(.top, 4)
            }
            VStack(spacing: 2) {
                ForEach(filter.isEmpty ? listItems : filteredItems) { item in
                    Button(action: item.action) {
                        Label(item.title, systemImage: item.symbol).font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }.buttonStyle(MenuRowStyle())
                }
                if !filter.isEmpty {
                    Button(action: submit) {
                        Label("Search mail for “\(filter)”", systemImage: "magnifyingglass").font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }.buttonStyle(MenuRowStyle())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16).frame(width: 360)
        .background(Theme.menuGradient, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true }
        .sheet(isPresented: $showsScreenedSenders) { ScreenedSendersView().environment(store) }
    }

    private func badge(for mailbox: Mailbox) -> Int? {
        let count: Int
        switch mailbox {
        case .screener: count = Set(store.visibleThreads(mailbox: .screener).map { $0.sender.email.lowercased() }).count
        case .imbox: count = store.newForYou.count
        default: return nil
        }
        return count > 0 ? count : nil
    }

    private func go(_ mailbox: Mailbox) {
        store.navigation = mailbox
        store.closeThread()
        store.endPowerThrough()
        isPresented = false
    }

    private func submit() {
        if let first = filteredItems.first { first.action(); return }
        let query = filter
        isPresented = false
        Task { await store.search(query) }
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        var configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(.white.opacity(configuration.isPressed ? 0.3 : (hovering ? 0.18 : 0)), in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 42, weight: .light)).foregroundStyle(Theme.menuGradient)
            Text("A calmer inbox.\nYour week, one keystroke away.")
                .font(.system(size: 32, weight: .bold)).multilineTextAlignment(.center)
            Text("Connect your Google account to bring your mail and calendars together. Your data stays in Google and on this Mac.")
                .font(.title3).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await store.signIn() }
            } label: {
                HStack {
                    if store.isSigningIn { ProgressView().controlSize(.small) }
                    Text(store.isSigningIn ? "Connecting…" : "Sign in with Google")
                }
            }
            .buttonStyle(PillButtonStyle(fill: Theme.accent)).disabled(store.isSigningIn)
            Text("⌘F3 opens your week. Hold to peek.").foregroundStyle(Theme.secondary).padding(.top, 8)
        }
        .frame(maxWidth: 520).padding(44).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
