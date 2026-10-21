#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// Two-finger horizontal swipes over this view's area slide the drawers, like Ulysses.
/// Vertical scrolling, and anything over an email body (which may scroll sideways), pass through.
/// Distances are physical: positive means the fingers moved right, whatever the scroll direction setting.
struct DrawerSwipeMonitor: NSViewRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (_ distance: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    /// Only listens; clicks go to whatever is in front.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onChange: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?
        private enum State { case idle, deciding, sliding, passing }
        private var state = State.idle
        private var distance = CGSize.zero
        private var recent: [(time: TimeInterval, dx: CGFloat)] = []
        private var swallowMomentum = false

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event belongs to a drawer swipe and must not reach the views underneath.
        private func consumes(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            // The flick's momentum after a slide would otherwise scroll whatever is under the pointer.
            if !event.momentumPhase.isEmpty {
                guard swallowMomentum else { return false }
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { swallowMomentum = false }
                return true
            }
            if event.phase.contains(.began) {
                swallowMomentum = false
                let point = view.convert(event.locationInWindow, from: nil)
                let inside = view.bounds.contains(point) && !Self.isOverWebContent(event, in: window)
                state = inside && event.hasPreciseScrollingDeltas ? .deciding : .passing
                distance = .zero; recent = []
                return false
            }
            if event.phase.contains(.changed) {
                let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                switch state {
                case .deciding:
                    distance.width += dx; distance.height += event.scrollingDeltaY
                    guard hypot(distance.width, distance.height) >= 6 else { return false }
                    guard abs(distance.width) > abs(distance.height) * 1.4 else { state = .passing; return false }
                    state = .sliding
                    onChange?(distance.width)
                    return true
                case .sliding:
                    distance.width += dx
                    recent.append((event.timestamp, dx))
                    recent.removeAll { event.timestamp - $0.time > 0.08 }
                    onChange?(distance.width)
                    return true
                case .idle, .passing:
                    return false
                }
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                defer { state = .idle }
                guard state == .sliding else { return false }
                let span = max(0.016, (recent.last?.time ?? 0) - (recent.first?.time ?? 0))
                let velocity = recent.count > 1 ? recent.reduce(0) { $0 + $1.dx } / span : 0
                onEnd?(distance.width, event.phase.contains(.cancelled) ? 0 : velocity)
                swallowMomentum = true
                return true
            }
            return false
        }

        private static func isOverWebContent(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let content = window.contentView else { return false }
            // hitTest takes a point in the superview's space, which for the content view is the window's.
            var hit = content.hitTest(event.locationInWindow)
            while let view = hit {
                if view is WKWebView { return true }
                hit = view.superview
            }
            return false
        }
    }
}
#endif
