#if os(macOS)
import AppKit
import SwiftUI

/// Letter shortcuts apply only to this window, and never consume text entry.
struct MailKeyboardMonitor: NSViewRepresentable {
    var enabled: Bool
    /// Sender details must consume Escape even when the search field still has focus.
    var capturesEscape = false
    var handle: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.capturesEscape = capturesEscape
        context.coordinator.handle = handle
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var enabled = true
        var capturesEscape = false
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.enabled, event.window === self.view?.window else { return false }
                    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    let character = event.charactersIgnoringModifiers?.lowercased()
                    let isPalette = modifiers == .command && character == "k"
                    let isCapturedEscape = self.capturesEscape && modifiers.isEmpty && event.keyCode == 53
                    // Read-only text (a plain-text email body) can hold focus without taking typing.
                    if !isPalette, !isCapturedEscape, let responder = event.window?.firstResponder,
                       (responder as? NSTextView)?.isEditable == true || responder is NSTextField { return false }
                    // A held key moves through the list, but never repeats an action on whatever comes next.
                    if event.isARepeat, character != "j", character != "k" { return false }
                    return self.handle?(event) == true
                }
                return handled ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
