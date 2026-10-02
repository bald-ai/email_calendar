#if os(macOS)
import SwiftUI

@main
struct EmailCalendarApp: App {
    @State private var store: AppStore
    @State private var overlay: OverlayController

    init() {
        let state = AppStore()
        let panel = OverlayController(store: state)
        _store = State(initialValue: state)
        _overlay = State(initialValue: panel)
        state.showOverlay = { [weak panel] in panel?.toggle() }
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
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Email + Calendar", systemImage: "calendar") {
            Button("Show Week") { overlay.toggle() }
            Button("Open Email + Calendar") { store.openMainWindow() }
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
#endif
