#if os(macOS)
import SwiftUI
import AppKit

struct AppShellView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A little more space").font(.headline)
                        Text("Email + Calendar").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
                List(selection: Binding<Mailbox?>(get: { store.navigation }, set: { if let value = $0 { store.navigation = value } })) {
                    ForEach(Mailbox.allCases) { mailbox in
                        Label(mailbox.title, systemImage: mailbox.symbol).tag(mailbox)
                            .padding(.vertical, 4)
                    }
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: store.isSignedIn ? "person.crop.circle" : "person.crop.circle.badge.plus")
                    Text(store.accountEmail.isEmpty ? "Your Google account" : store.accountEmail)
                        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    SettingsLink { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Preferences")
                }.padding(16)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if let message = store.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(.secondary)
                        Text(message).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Retry") { Task { await store.refresh() } }
                        Button { store.errorMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss")
                    }.padding(12).background(Color.secondary.opacity(0.08))
                    Divider()
                }
                if !store.isSignedIn {
                    WelcomeView()
                } else if store.navigation == .calendar {
                    CalendarMainView()
                } else {
                    MailWorkspaceView(mailbox: store.navigation)
                }
            }
            .navigationTitle(store.navigation.title)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { Task { await store.refresh() } } label: {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(store.isRefreshing || !store.isSignedIn)
                    .help("Refresh mail and calendar")
                }
            }
        }
        .tint(Color(red: 0.27, green: 0.44, blue: 0.40))
        .onAppear { store.openWindow = { openWindow(id: "main") } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await store.refresh() }
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 42, weight: .light)).foregroundStyle(.tint)
            Text("A calmer inbox.\nYour week, one keystroke away.")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("Connect your Google account to bring your mail and calendars together. Your data stays in Google and on this Mac.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await store.signIn() }
            } label: {
                HStack {
                    if store.isSigningIn { ProgressView().controlSize(.small) }
                    Text(store.isSigningIn ? "Connecting…" : "Sign in with Google")
                }.padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).disabled(store.isSigningIn)
            HStack(spacing: 6) {
                Text("⌥ Space").font(.system(.body, design: .monospaced))
                Text("opens your week. Hold to peek.").foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(44).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
