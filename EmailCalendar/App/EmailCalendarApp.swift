#if os(macOS)
import SwiftUI

@main
struct EmailCalendarApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var overlay: OverlayController

    init() {
        let state = AppStore()
        let panel = OverlayController(store: state)
        _store = State(initialValue: state)
        _overlay = State(initialValue: panel)
        state.showOverlay = { [weak panel] in panel?.toggle() }
        appDelegate.store = state
        // Also at launch, not only when the window appears: a login launch may restore no window.
        appDelegate.onLaunch = { [weak panel] in
            panel?.installHotkey()
            Task { await state.start() }
        }
    }

    var body: some Scene {
        WindowGroup("Email + Calendar", id: "main") {
            AppShellView()
                .environment(store)
                .task {
                    overlay.installHotkey()
                    await store.start()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Show Week Overlay") { overlay.toggle() }
                Button("Refresh") { Task { await store.refreshNow() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra("Email + Calendar", systemImage: "calendar") {
            Button("Show Week") { overlay.toggle() }
            Button("Open Email + Calendar") { store.openMainWindow() }
            if !store.alarms.alarms.isEmpty {
                Divider()
                ForEach(store.alarms.alarms) { alarm in
                    Button("Cancel ⏰ \(alarm.fireAt.formatted(date: .omitted, time: .shortened)) · \(alarm.label)") {
                        store.alarms.cancel(alarm.id)
                    }
                }
            }
            Divider()
            SettingsLink { Text("Preferences…") }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }

        Settings {
            PreferencesView().environment(store)
        }
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    var onLaunch: (() -> Void)?
    private var preparing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?()
        // After travel, days and hours must follow the new zone without a relaunch.
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                NSTimeZone.resetSystemTimeZone()
                CalendarGeometry.timeZoneDidChange()
                Task {
                    await self?.store?.reloadCalendarCache()
                    await self?.store?.refresh()
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !preparing else { return .terminateLater }
        preparing = true
        Task {
            let preserved = await store.prepareToQuit()
            preparing = false
            sender.reply(toApplicationShouldTerminate: preserved)
        }
        return .terminateLater
    }
}
#endif
