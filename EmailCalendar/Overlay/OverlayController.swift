#if os(macOS)
import AppKit
import CoreGraphics
import KeyboardShortcuts
import Observation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

extension KeyboardShortcuts.Name {
    static let toggleCalendarOverlay = Self(
        "toggleCalendarOverlay",
        default: .init(.f3, modifiers: [.command])
    )
}

/// A cached calendar surface that can receive keyboard focus without activating the app.
@MainActor
@Observable
final class OverlayController {
    private(set) var isOpen = false
    /// Kept across summons, so an answer survives an accidental outside click.
    let assistant = EventAssistant()
    let panels = OverlayPanels()
    @ObservationIgnored private var panelWindow: OverlayPanelWindow?
    @ObservationIgnored private var panelHost: FirstMouseHostingView<OverlayPanelHost>?
    @ObservationIgnored private var panelGeneration = 0

    private let store: AppStore
    @ObservationIgnored private var panel: CalendarOverlayPanel?
    @ObservationIgnored private var selectedScreen: NSScreen?
    @ObservationIgnored private var previousApplication: NSRunningApplication?
    @ObservationIgnored private weak var previousKeyWindow: NSWindow?
    @ObservationIgnored private var localClickMonitor: Any?
    @ObservationIgnored private var globalClickMonitor: Any?
    @ObservationIgnored private var pasteMonitor: Any?
    @ObservationIgnored private var scrollMonitor: Any?
    @ObservationIgnored private let physics = ScrollPhysics()
    /// The image picker is a separate window; clicks in it must not dismiss the overlay.
    @ObservationIgnored private var isPickingImages = false
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored private var screensObserver: NSObjectProtocol?
    @ObservationIgnored private var installedHotkey = false
    @ObservationIgnored private var shortcutIsDown = false
    @ObservationIgnored private var shortcutWasOpen = false
    @ObservationIgnored private var isPeek = false
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var animationGeneration = 0
    @ObservationIgnored private var resizeInitialHeight: CGFloat?
    @ObservationIgnored private var resizeStartMouseY: CGFloat = 0
    @ObservationIgnored private var restoreFocusAfterClosing = true
    /// Height the content asked for (month view fitting its busiest day), or nil to use the user's height.
    @ObservationIgnored private var contentHeight: CGFloat?

    init(store: AppStore) {
        self.store = store
        panels.onChange = { [weak self] kind in self?.showPanel(kind) }
        assistant.onOpen = { [weak self] in
            guard let self, self.isOpen, self.panels.current != .assistant else { return }
            self.panels.show(.assistant)
        }
    }

    func installHotkey() {
        guard !installedHotkey else { return }
        installedHotkey = true
        // KeyboardShortcuts stores the default on first use, so earlier installs still hold an old
        // default (⌥Space, then ⌘F2, which Prompt Palette also uses). Move them to ⌘F3 once;
        // a shortcut the user recorded themselves is left alone.
        if !UserDefaults.standard.bool(forKey: "overlay.hotkey.cmdF3") {
            UserDefaults.standard.set(true, forKey: "overlay.hotkey.cmdF3")
            let oldDefaults: [KeyboardShortcuts.Shortcut] = [.init(.space, modifiers: [.option]), .init(.f2, modifiers: [.command])]
            if let current = KeyboardShortcuts.getShortcut(for: .toggleCalendarOverlay), oldDefaults.contains(current) {
                KeyboardShortcuts.setShortcut(.init(.f3, modifiers: [.command]), for: .toggleCalendarOverlay)
            }
        }

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
        // Month view opens already stretched, instead of growing after it appears.
        contentHeight = UserDefaults.standard.string(forKey: "overlay.mode") == OverlayWeekView.Mode.month.rawValue
            ? OverlayWeekView.monthHeight(index: CalendarGeometry.DayIndex(OverlayWeekView.visibleEvents(store)), month: .now)
            : nil
        let height = fittedHeight(on: screen)
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
        panels.close()
        hidePanel(animated: false)
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
        // Opening the window while the overlay is still sliding up looked like a jump cut;
        // wait for the slide (0.14 s), then bring the window in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [store] in store.openMainWindow(event: event) }
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
            assistant: assistant,
            panels: panels,
            onClose: { [weak self] in self?.close() },
            onPickImages: { [weak self] in self?.pickImages() },
            onOpenInApp: { [weak self] event in self?.openInMainApp(event: event) },
            onResizeChanged: { [weak self] in self?.resize() },
            onResizeEnded: { [weak self] in self?.finishResize() },
            onPreferredHeight: { [weak self] height in self?.fitContent(height) },
            onRefocus: { [weak self] in
                guard let self, self.isOpen, self.panels.current == nil else { return }
                self.panel?.makeKey()
            }
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

    /// Follows the mouse in screen coordinates: the handle moves with the window's bottom edge,
    /// so a drag measured from the handle itself shrinks as the window grows and the edge jitters.
    private func resize() {
        guard isOpen, let panel, let screen = selectedScreen else { return }
        let mouseY = NSEvent.mouseLocation.y
        if resizeInitialHeight == nil {
            resizeInitialHeight = panel.frame.height
            resizeStartMouseY = mouseY
        }
        let translation = resizeStartMouseY - mouseY
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

    /// The user's height, stretched (never shrunk) to what the content needs, within 85% of the screen.
    private func fittedHeight(on screen: NSScreen) -> CGFloat {
        let base = screen.frame.height * heightRatio(for: screen)
        guard let contentHeight else { return base }
        return max(base, min(contentHeight, screen.frame.height * 0.85))
    }

    private func fitContent(_ height: CGFloat?) {
        contentHeight = height
        // Called from inside a SwiftUI update; resizing the window there can leave its layout
        // stale, so apply it right after the update finishes.
        DispatchQueue.main.async { [weak self] in self?.applyContentHeight() }
    }

    private func applyContentHeight() {
        guard isOpen, resizeInitialHeight == nil, let panel, let screen = selectedScreen else { return }
        let target = fittedHeight(on: screen)
        guard abs(target - panel.frame.height) > 4 else { return }
        // Instant, top edge fixed: animating the frame relays out the whole grid on every frame.
        panel.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.maxY - target, width: screen.frame.width, height: target), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        // Stay in front of other always-on-top panels (Prompt Palette uses the same level).
        panel.orderFrontRegardless()
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
        return CGFloat(min(0.80, max(0.15, value.isFinite ? value : 0.375)))
    }

    private func synchronizeHeightPreference() -> Double {
        let defaults = UserDefaults.standard
        let revisionKey = "overlay.height.defaultRatio"
        let ratio = min(0.80, max(0.15, store.overlayHeight.isFinite ? store.overlayHeight : 0.375))
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
            Task { @MainActor in if self?.isPickingImages == false { self?.close() } }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.isOpen, !self.isPickingImages, !self.belongsToOverlay(event.window) {
                    self.close()
                }
            }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let window = event.window
            let handled = MainActor.assumeIsolated {
                guard let self, self.isOpen, let window, window === self.panel else { return false }
                // Days across; hours down in week view, week rows down in month view.
                let month = UserDefaults.standard.string(forKey: "overlay.mode") == OverlayWeekView.Mode.month.rawValue
                self.physics.horizontalCount = OverlayWeekView.dayCount
                self.physics.verticalCount = month ? OverlayWeekView.weekCount : 24
                return self.physics.handle(event, in: window)
            }
            return handled ? nil : event
        }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let window = event.window
            let handled = MainActor.assumeIsolated {
                guard let self, self.isOpen, let window, window === self.panel || window === self.panelWindow else { return false }
                return self.paste(editing: window.firstResponder is NSTextView)
            }
            return handled ? nil : event
        }
    }

    /// ⌘V in the overlay: a screenshot or image goes to AI add; so does text, unless a field is being edited.
    private func paste(editing: Bool) -> Bool {
        let board = NSPasteboard.general
        let imageFiles = board.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] ?? []
        let text = board.string(forType: .string)
        if !imageFiles.isEmpty {
            return imageFiles.compactMap(NSImage.init(contentsOf:)).map { assistant.attach($0) }.contains(true)
        }
        if text == nil, let image = NSImage(pasteboard: board) { return assistant.attach(image) }
        guard let text, !editing else { return false }
        assistant.text += text
        assistant.open()
        return true
    }

    private func pickImages() {
        guard !isPickingImages else { return }
        isPickingImages = true
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.message = "Choose a screenshot or photo of the event"
        picker.prompt = "Use"
        // Above the overlay, which floats at the status bar level.
        picker.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPickingImages = false
                if response == .OK {
                    for url in picker.urls { if let image = NSImage(contentsOf: url) { self.assistant.attach(image) } }
                }
                if self.isOpen { (self.panelWindow?.isVisible == true ? self.panelWindow : self.panel)?.makeKeyAndOrderFront(nil) }
            }
        }
    }

    // MARK: Panel window

    /// Shows (or swaps) the floating panel just under the overlay's top bar, rising into place.
    private func showPanel(_ kind: OverlayPanelKind?) {
        guard let kind else { hidePanel(animated: true); return }
        guard isOpen, let panel, let screen = selectedScreen else { return }
        panelGeneration += 1
        let window = panelWindow ?? OverlayPanelWindow()
        panelWindow = window
        window.onCancel = { [weak self] in self?.panels.close() }
        let root = OverlayPanelHost(kind: kind, store: store, assistant: assistant, panels: panels,
                                    onPickImages: { [weak self] in self?.pickImages() })
        // Reusing one hosting view keeps opening a panel cheap; only the root view is swapped.
        if let panelHost { panelHost.rootView = root } else {
            let host = FirstMouseHostingView(rootView: root)
            panelHost = host
            window.contentView = host
        }
        let width: CGFloat = 760
        let top = panel.frame.maxY - 52
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + 12, width: width, height: top - screen.frame.minY - 12)
        if window.frame != frame { window.setFrame(frame, display: false) }
        if window.parent == nil { panel.addChildWindow(window, ordered: .above) }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
    }

    private func hidePanel(animated: Bool) {
        guard let window = panelWindow, window.isVisible else { return }
        panelGeneration += 1
        let generation = panelGeneration
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { finishHidingPanel(generation); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in self?.finishHidingPanel(generation) }
        }
    }

    /// Skipped when the panel was shown again in the meantime.
    private func finishHidingPanel(_ generation: Int) {
        guard panelGeneration == generation, let window = panelWindow else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        panelHost?.rootView = OverlayPanelHost(kind: nil, store: store, assistant: assistant, panels: panels, onPickImages: {})
        if isOpen { panel?.makeKey() }
    }

    /// The overlay, its panel window, and any sheet they present (the editor's delete and
    /// recurring-scope confirmations are sheets, which hang off `sheetParent`, not `parent`).
    private func belongsToOverlay(_ window: NSWindow?) -> Bool {
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.parent ?? current.sheetParent
        }
        return false
    }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        physics.stop()
        localClickMonitor = nil
        globalClickMonitor = nil
        pasteMonitor = nil
        scrollMonitor = nil
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
    /// After a popover or panel closes, the very next click reaches the calendar.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
#endif
