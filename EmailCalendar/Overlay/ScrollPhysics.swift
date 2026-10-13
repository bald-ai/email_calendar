#if os(macOS)
import AppKit
import QuartzCore

/// Gives the overlay's scrolling some weight: fingers move it 1:1 (rubber-banding past the ends).
/// On release it coasts, losing speed slowly and landing exactly on a whole day, hour or week row,
/// then a soft spring settles it with a small bounce. A mouse wheel springs one unit per notch.
@MainActor
final class ScrollPhysics {
    enum Axis { case horizontal, vertical }

    /// Snap units come from the content size divided by these counts (days across, hours or week rows down).
    var horizontalCount = 1
    var verticalCount = 1

    // Tuning. Friction is per millisecond, like UIScrollView's deceleration rate: closer to 1 coasts further.
    // A 2000 pt/s flick coasts about 7 days in ~1.8 s; every landing bounces about 7 pt.
    private let friction: CGFloat = 0.9985
    private let springResponse: CGFloat = 0.38
    private let springDamping: CGFloat = 0.62   // Below 1: a small, satisfying overshoot.
    private let handoffSpeed: CGFloat = 140     // pt/s where coasting hands over to the spring.
    private let rubberBand: CGFloat = 0.35

    private weak var scrollView: NSScrollView?
    private var axis: Axis = .vertical
    private var position: CGFloat = 0
    private var velocity: CGFloat = 0
    private var target: CGFloat?
    private var tracking = false
    /// Coasting (exponential slow-down towards `target`) before the spring takes over.
    private var gliding = false
    private var glideRate: CGFloat = 1.5
    private var lastTimestamp: TimeInterval = 0
    private var displayLink: CADisplayLink?
    /// The scroll view we told "live scroll started", so SwiftUI tracks our moves as the user's.
    private weak var liveView: NSScrollView?
    private var lastFrame: CFTimeInterval = 0
    private lazy var linkTarget = DisplayLinkTarget { [weak self] link in self?.tick(link) }

    /// Returns true when the event was handled here (and must not reach the scroll view as well).
    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        // The system's own momentum after a swipe: ours replaces it.
        if !event.momentumPhase.isEmpty { return scrollView != nil }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let phase = event.phase

        guard event.hasPreciseScrollingDeltas else { return wheel(event, in: window, dx: dx, dy: dy) }

        if phase.contains(.mayBegin) {
            // Fingers resting on the trackpad catch a glide in progress; lifting them snaps to the nearest unit.
            stopAnimating()
            velocity = 0
            gliding = false
            target = nil
            if let view = scrollView { position = origin(of: view) }
            return scrollView != nil
        }
        if phase.contains(.began) {
            stopAnimating()
            tracking = true
            gliding = false
            scrollView = nil      // The axis is picked by the first movement.
            velocity = 0
            target = nil
            lastTimestamp = event.timestamp
            return true
        }
        if phase.contains(.changed) || phase.isEmpty {
            if scrollView == nil {
                guard dx != 0 || dy != 0 else { return false }
                axis = abs(dx) > abs(dy) ? .horizontal : .vertical
                guard let view = scrollView(at: event, in: window, axis: axis) else { return false }
                scrollView = view
                position = origin(of: view)
                tracking = true
            }
            guard let view = scrollView else { return false }
            let delta = axis == .horizontal ? dx : dy
            let outside = position < 0 || position > maxOrigin(of: view)
            position -= delta * (outside ? rubberBand : 1)
            let dt = max(1 / 240, min(0.05, event.timestamp - lastTimestamp))
            lastTimestamp = event.timestamp
            velocity = 0.6 * velocity + 0.4 * (-delta / dt)
            setOrigin(position, of: view)
            if phase.isEmpty { tracking = false; release(view) }
            return true
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            tracking = false
            guard let view = scrollView else { return false }
            release(view)
            return true
        }
        return scrollView != nil
    }

    /// A wheel notch moves exactly one unit (day, hour or week row), sprung. Notches add up.
    private func wheel(_ event: NSEvent, in window: NSWindow, dx: CGFloat, dy: CGFloat) -> Bool {
        guard dx != 0 || dy != 0 else { return scrollView != nil }
        let wanted: Axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        guard let view = scrollView(at: event, in: window, axis: wanted) else { return false }
        if view !== scrollView || wanted != axis {
            stop()
            scrollView = view
            axis = wanted
            position = origin(of: view)
        }
        guard let unit = unit(of: view) else { return false }
        let delta = wanted == .horizontal ? dx : dy
        let base = target ?? (position / unit).rounded() * unit
        target = clamp(base + (delta < 0 ? unit : -unit), view)
        tracking = false
        gliding = false
        startAnimating()
        return true
    }

    func stop() {
        endLive()
        stopAnimating()
        tracking = false
        gliding = false
        target = nil
        velocity = 0
        scrollView = nil
    }

    // MARK: Simulation

    /// Where the throw would coast to, rounded to a whole unit. The slow-down rate is adjusted so the
    /// coast ends right there; the spring only adds the final bounce.
    private func release(_ view: NSScrollView) {
        let naturalRate = -log(friction) * 1000
        let coast = velocity / naturalRate
        let end: CGFloat
        if let unit = unit(of: view) { end = clamp(((position + coast) / unit).rounded() * unit, view) }
        else { end = clamp(position + coast, view) }
        target = end
        let distance = end - position
        gliding = abs(velocity) > handoffSpeed && abs(distance) > 1 && (distance > 0) == (velocity > 0)
        if gliding { glideRate = max(0.8, velocity / distance) }
        startAnimating()   // Ends the live scroll when it settles.
    }

    private func startAnimating() {
        guard displayLink == nil, let view = scrollView else { return }
        let link = view.displayLink(target: linkTarget, selector: #selector(DisplayLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrame = 0
    }

    private func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func tick(_ link: CADisplayLink) {
        guard let view = scrollView, let target, !tracking else { stopAnimating(); return }
        let now = link.timestamp
        var remaining = lastFrame == 0 ? 1.0 / 120 : min(1.0 / 30, now - lastFrame)
        lastFrame = now
        let stiffness = pow(2 * .pi / springResponse, 2)
        let damping = 2 * springDamping * sqrt(stiffness)
        // Small fixed steps keep the spring stable whatever the frame rate.
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 240)
            if gliding {
                velocity *= exp(-glideRate * dt)
                position += velocity * dt
                if abs(velocity) < handoffSpeed { gliding = false }
            } else {
                let acceleration = -stiffness * (position - target) - damping * velocity
                velocity += acceleration * dt
                position += velocity * dt
            }
            remaining -= dt
        }
        if !gliding && abs(position - target) < 0.4 && abs(velocity) < 6 {
            position = target
            velocity = 0
            self.target = nil
            setOrigin(position, of: view)
            stopAnimating()
            endLive()
            return
        }
        setOrigin(position, of: view)
    }

    // MARK: Scroll view access

    /// The scroll view under the pointer that can move along `axis` (the day strip sits inside the hour scroll).
    private func scrollView(at event: NSEvent, in window: NSWindow, axis: Axis) -> NSScrollView? {
        guard let content = window.contentView else { return nil }
        var candidate = content.hitTest(content.convert(event.locationInWindow, from: nil))?.enclosingScrollView
        while let view = candidate {
            if maxOrigin(of: view, axis: axis) > 1 { return view }
            candidate = view.superview?.enclosingScrollView
        }
        return nil
    }

    private func unit(of view: NSScrollView) -> CGFloat? {
        guard let document = view.documentView else { return nil }
        let length = axis == .horizontal ? document.frame.width : document.frame.height
        let count = axis == .horizontal ? horizontalCount : verticalCount
        let unit = length / CGFloat(max(1, count))
        return unit >= 12 ? unit : nil
    }

    private func origin(of view: NSScrollView) -> CGFloat {
        axis == .horizontal ? view.contentView.bounds.origin.x : view.contentView.bounds.origin.y
    }

    private func maxOrigin(of view: NSScrollView, axis: Axis? = nil) -> CGFloat {
        guard let document = view.documentView else { return 0 }
        return (axis ?? self.axis) == .horizontal
            ? max(0, document.frame.width - view.contentView.bounds.width)
            : max(0, document.frame.height - view.contentView.bounds.height)
    }

    private func clamp(_ value: CGFloat, _ view: NSScrollView) -> CGFloat { min(max(0, value), maxOrigin(of: view)) }

    /// Moves the content and reports it the way a trackpad scroll would. Without the live-scroll
    /// notifications SwiftUI keeps its own, stale scroll position and jumps back to it whenever the
    /// content updates (the one-frame snap back to the week the overlay opened on).
    private func setOrigin(_ value: CGFloat, of view: NSScrollView) {
        if liveView !== view {
            endLive()
            liveView = view
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
        }
        var origin = view.contentView.bounds.origin
        if axis == .horizontal { origin.x = value } else { origin.y = value }
        view.contentView.setBoundsOrigin(origin)
        view.reflectScrolledClipView(view.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: view)
    }

    private func endLive() {
        guard let view = liveView else { return }
        liveView = nil
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
    }
}

/// CADisplayLink needs an Objective-C target.
private final class DisplayLinkTarget: NSObject {
    let onStep: (CADisplayLink) -> Void
    init(_ onStep: @escaping (CADisplayLink) -> Void) { self.onStep = onStep }
    @objc func step(_ link: CADisplayLink) { onStep(link) }
}
#endif
