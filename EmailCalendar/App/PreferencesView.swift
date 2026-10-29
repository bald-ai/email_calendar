#if os(macOS)
import SwiftUI
import KeyboardShortcuts
import ServiceManagement

struct PreferencesView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Your week") {
                KeyboardShortcuts.Recorder("Global hotkey", name: .toggleCalendarOverlay)
                Text("Tap to toggle. Hold to peek. Escape closes the overlay.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Default overlay height") {
                    HStack {
                        Slider(value: $store.overlayHeight, in: 0.15...0.60).frame(width: 180)
                        Text("\(Int(store.overlayHeight * 100))%")
                            .monospacedDigit().frame(width: 42)
                    }
                }
                Text("You can also drag the overlay’s bottom edge. Each display remembers its height.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI add") {
                LabeledContent("Model", value: EventAssistant.modelSummary)
                ForEach(EventAssistant.Credential.allCases, id: \.self) { CredentialRow(credential: $0) }
                Text("In the overlay, press I or ⌘V to turn a description or screenshot into events. The workspace ID is only needed for Anthropic keys not scoped to one workspace. Saving an empty field removes the value from Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Make room for focus") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Quiet notification when mail bubbles up", isOn: $store.bubbleNotifications)
                Text("Remote email images stay blocked until you allow them for a sender.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Google account") {
                if store.isSignedIn {
                    LabeledContent("Connected", value: store.accountEmail)
                    Button("Sign out") { Task { await store.signOut() } }
                } else {
                    Button("Sign in with Google") { Task { await store.signIn() } }.disabled(store.isSigningIn)
                }
            }
            if let message = store.errorMessage {
                Section { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped).padding(8).frame(width: 540)
    }
}

private struct CredentialRow: View {
    let credential: EventAssistant.Credential
    @State private var value = ""
    @State private var source = ""

    var body: some View {
        LabeledContent(title) {
            HStack {
                if credential == .anthropicWorkspace {
                    TextField(source, text: $value).frame(width: 220)
                } else {
                    SecureField(source, text: $value).frame(width: 220)
                }
                Button("Save") {
                    do { try credential.save(value); value = ""; source = credential.source }
                    catch { source = error.localizedDescription }
                }
            }
        }
        .onAppear { source = credential.source }
    }

    private var title: String {
        switch credential {
        case .anthropicKey: "Anthropic API key (backup)"
        case .anthropicWorkspace: "Anthropic workspace ID"
        case .openAIKey: "OpenAI API key"
        }
    }
}
#endif
