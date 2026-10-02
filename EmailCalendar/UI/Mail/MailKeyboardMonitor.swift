#if os(macOS)
import AppKit
import SwiftUI

/// Letter shortcuts apply only to this window, and never consume text entry.
struct MailKeyboardMonitor: NSViewRepresentable {
    var enabled: Bool
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
        context.coordinator.handle = handle
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var enabled = true
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.enabled, event.window === self.view?.window else { return false }
                    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    let isPalette = modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "k"
                    if !isPalette, let responder = event.window?.firstResponder,
                       responder is NSTextView || responder is NSTextField { return false }
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
