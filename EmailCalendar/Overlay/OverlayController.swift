#if os(macOS)
import AppKit
import CoreGraphics
import KeyboardShortcuts
import Observation
import QuartzCore
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleCalendarOverlay = Self(
        "toggleCalendarOverlay",
        default: .init(.space, modifiers: [.option])
    )
}

/// A cached calendar surface that can receive keyboard focus without activating the app.
@MainActor
@Observable
final class OverlayController {
    private(set) var isOpen = false

    private let store: AppStore
    @ObservationIgnored private var panel: CalendarOverlayPanel?
    @ObservationIgnored private var selectedScreen: NSScreen?
    @ObservationIgnored private var previousApplication: NSRunningApplication?
    @ObservationIgnored private weak var previousKeyWindow: NSWindow?
    @ObservationIgnored private var localClickMonitor: Any?
    @ObservationIgnored private var globalClickMonitor: Any?
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored private var screensObserver: NSObjectProtocol?
    @ObservationIgnored private var installedHotkey = false
    @ObservationIgnored private var shortcutIsDown = false
    @ObservationIgnored private var shortcutWasOpen = false
    @ObservationIgnored private var isPeek = false
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var animationGeneration = 0
    @ObservationIgnored private var resizeInitialHeight: CGFloat?
    @ObservationIgnored private var restoreFocusAfterClosing = true

    init(store: AppStore) {
        self.store = store
    }

    func installHotkey() {
        guard !installedHotkey else { return }
        installedHotkey = true

        KeyboardShortcuts.onKeyDown(for: .toggleCalendarOverlay) { [weak self] in
            Task { @MainActor in self?.shortcutDown() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleCalendarOverlay) { [weak self] in
            Task { @MainActor in self?.shortcutUp() }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissForEnvironmentChange() }
        }
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismissForEnvironmentChange() }
        }
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        guard let screen = screenUnderMouse() else { return }
        animationGeneration += 1
        isOpen = true
        restoreFocusAfterClosing = true
        resizeInitialHeight = nil
        selectedScreen = screen
        // A rapid reopen during the closing animation keeps the original focus owner.
        if previousApplication == nil {
            previousApplication = NSWorkspace.shared.frontmostApplication
            previousKeyWindow = NSApp.keyWindow
        }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height = screen.frame.height * heightRatio(for: screen)
        let shownFrame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        )
        installContent(in: panel, frame: shownFrame)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let initialFrame = reduceMotion ? shownFrame : NSRect(
            x: shownFrame.minX,
            y: screen.frame.maxY,
            width: shownFrame.width,
            height: shownFrame.height
        )
        panel.setFrame(initialFrame, display: false)
        panel.alphaValue = reduceMotion ? 0 : 1
        // .nonactivatingPanel makes this key operation independent of app activation.
        panel.makeKeyAndOrderFront(nil)
        if let responder = panel.initialFirstResponder {
            panel.makeFirstResponder(responder)
        }
        installClickMonitors()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.23
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.18, 1.0, 0.30, 1.06
            )
            if reduceMotion {
                panel.animator().alphaValue = 1
            } else {
                panel.animator().setFrame(shownFrame, display: true)
            }
        }
    }

    func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        animationGeneration += 1
        let generation = animationGeneration
        resizeInitialHeight = nil
        removeClickMonitors()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let top = selectedScreen?.frame.maxY ?? panel.frame.maxY
        var hiddenFrame = panel.frame
        hiddenFrame.origin.y = top
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if reduceMotion {
                panel.animator().alphaValue = 0
            } else {
                panel.animator().setFrame(hiddenFrame, display: true)
            }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.animationGeneration == generation,
                      !self.isOpen else { return }
                self.panel?.orderOut(nil)
                if self.restoreFocusAfterClosing {
                    self.restoreFocus()
                } else {
                    self.previousApplication = nil
                    self.previousKeyWindow = nil
                }
            }
        }
    }

    private func dismissForEnvironmentChange() {
        // Activating the previous app after switching Spaces can jump back to it.
        // Also suppress restoration if a close animation was already in progress.
        restoreFocusAfterClosing = false
        close()
    }

    private func openInMainApp(event: CalendarEvent?) {
        restoreFocusAfterClosing = false
        close()
        store.openMainWindow(event: event)
    }

    private func shortcutDown() {
        // Carbon hotkeys may repeat while held. Only the initial down begins a peek.
        guard !shortcutIsDown else { return }
        shortcutIsDown = true
        shortcutWasOpen = isOpen
        isPeek = false
        if !isOpen { open() }
        peekTask?.cancel()
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, self.shortcutIsDown else { return }
            self.isPeek = true
        }
    }

    private func shortcutUp() {
        guard shortcutIsDown else { return }
        shortcutIsDown = false
        peekTask?.cancel()
        peekTask = nil
        if isPeek || shortcutWasOpen { close() }
        isPeek = false
    }

    private func makePanel() -> CalendarOverlayPanel {
        let panel = CalendarOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Week calendar overlay"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.onDismiss = { [weak self] in self?.close() }
        return panel
    }

    private func installContent(in panel: CalendarOverlayPanel, frame: NSRect) {
        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]

        // Rebuilding the cached view resets its week and scroll anchor on each summon.
        let host = OverlayHostingView(rootView: OverlayWeekView(
            store: store,
            onClose: { [weak self] in self?.close() },
            onOpenInApp: { [weak self] event in self?.openInMainApp(event: event) },
            onResizeChanged: { [weak self] translation in self?.resize(by: translation) },
            onResizeEnded: { [weak self] in self?.finishResize() }
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor),
            host.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        panel.contentView = material
        panel.initialFirstResponder = host
    }

    private func resize(by translation: CGFloat) {
        guard isOpen, let panel, let screen = selectedScreen else { return }
        if resizeInitialHeight == nil { resizeInitialHeight = panel.frame.height }
        let height = min(
            screen.frame.height * 0.80,
            max(screen.frame.height * 0.15, (resizeInitialHeight ?? panel.frame.height) + translation)
        )
        panel.setFrame(NSRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        ), display: true)
    }

    private func finishResize() {
        defer { resizeInitialHeight = nil }
        guard let panel, let screen = selectedScreen, screen.frame.height > 0 else { return }
        // A drag after a preferences change becomes the new override for this display.
        _ = synchronizeHeightPreference()
        UserDefaults.standard.set(
            Double(panel.frame.height / screen.frame.height),
            forKey: heightDefaultsKey(for: screen)
        )
    }

    private func heightRatio(for screen: NSScreen) -> CGFloat {
        let defaultRatio = synchronizeHeightPreference()
        let defaults = UserDefaults.standard
        let key = heightDefaultsKey(for: screen)
        let value = defaults.object(forKey: key) == nil ? defaultRatio : defaults.double(forKey: key)
        return CGFloat(min(0.80, max(0.15, value.isFinite ? value : 0.25)))
    }

    private func synchronizeHeightPreference() -> Double {
        let defaults = UserDefaults.standard
        let revisionKey = "overlay.height.defaultRatio"
        let ratio = min(0.80, max(0.15, store.overlayHeight.isFinite ? store.overlayHeight : 0.25))
        if let previous = defaults.object(forKey: revisionKey) as? Double, previous != ratio {
            // An explicit preference change resets the remembered display sizes.
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("overlay.height.display.") {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(ratio, forKey: revisionKey)
        return ratio
    }

    private func heightDefaultsKey(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let displayID = number?.uint32Value,
           let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return "overlay.height.display.\(CFUUIDCreateString(nil, uuid) as String)"
        }
        return "overlay.height.display.\(number?.stringValue ?? screen.localizedName)"
    }

    private func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func installClickMonitors() {
        removeClickMonitors()
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.isOpen, !self.belongsToOverlay(event.window) {
                    self.close()
                }
            }
            return event
        }
    }

    private func belongsToOverlay(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent
        }
        return false
    }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    private func restoreFocus() {
        defer {
            previousApplication = nil
            previousKeyWindow = nil
        }
        guard let previousApplication, !previousApplication.isTerminated else { return }
        let currentPID = NSRunningApplication.current.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // An outside click can deliberately select another app; leave that choice alone.
        guard frontmostPID == previousApplication.processIdentifier || frontmostPID == currentPID else { return }
        if previousApplication.processIdentifier == currentPID {
            previousKeyWindow?.makeKey()
        } else {
            previousApplication.activate(options: [])
        }
    }
}

@MainActor
private final class CalendarOverlayPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Allow the frame above the display while sliding in or out.
        frameRect
    }
}

@MainActor
private final class OverlayHostingView: NSHostingView<OverlayWeekView> {
    override var acceptsFirstResponder: Bool { true }
}
#endif
