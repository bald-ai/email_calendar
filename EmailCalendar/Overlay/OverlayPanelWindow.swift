#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// What floats over the overlay: the alarm, AI add, or an event being edited.
enum OverlayPanelKind: Equatable {
    case alarm, assistant
    case edit(CalendarEvent)
}

/// Which panel is up. The overlay view dims behind it; the controller shows it in its own window.
@MainActor @Observable
final class OverlayPanels {
    private(set) var current: OverlayPanelKind?
    @ObservationIgnored var onChange: ((OverlayPanelKind?) -> Void)?

    func show(_ kind: OverlayPanelKind) {
        current = kind
        onChange?(kind)
    }

    func close() {
        guard current != nil else { return }
        current = nil
        onChange?(nil)
    }
}

/// A borderless child window of the overlay, so a panel can be as tall as it needs without the
/// overlay itself resizing (which is what made opening the editor jump).
@MainActor
final class OverlayPanelWindow: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Clicks land even when the window isn't key yet (after a popover closed, say),
/// instead of the first click only focusing it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content: the card, top-centred, rising gently into place. Clicking around it closes it.
/// One hosting view is reused for every panel; only this root view changes.
struct OverlayPanelHost: View {
    let kind: OverlayPanelKind?
    let store: AppStore
    let assistant: EventAssistant
    let panels: OverlayPanels
    let onPickImages: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if let kind {
                // Nearly invisible, but it catches clicks next to the card.
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { panels.close() }
                PanelEntrance { card(kind) }.id(Self.key(kind)).padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(store)
        .preferredColorScheme(.dark)
    }

    static func key(_ kind: OverlayPanelKind) -> String {
        switch kind {
        case .alarm: "alarm"
        case .assistant: "assistant"
        case let .edit(event): "edit-\(event.cacheID)"
        }
    }

    @ViewBuilder
    private func card(_ kind: OverlayPanelKind) -> some View {
        switch kind {
        case .alarm:
            AlarmPanel(alarms: store.alarms, onClose: panels.close)
        case .assistant:
            AssistantPanel(assistant: assistant, onPickImages: onPickImages, calendars: store.calendars.filter(\.canEdit),
                           onAdd: { event, alarm in add(event, alarm: alarm) }, onClose: { assistant.close(); panels.close() },
                           conflicts: { EventConflicts.find(title: $0.title, start: $0.start, end: $0.end,
                                                            isAllDay: $0.isAllDay, in: store.events) })
        case let .edit(event):
            CalendarEventEditor(event: event, onDone: panels.close)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .panelCard()
        }
    }

    private func add(_ event: ExtractedEvent, alarm: Bool) {
        guard assistant.beginAdd(event.id) else { return }
        Task {
            defer { assistant.endAdd(event.id) }
            if await store.quickAdd(event) {
                if alarm, let time = ProposalCard.alarmTime(for: event) { store.alarms.add(at: time, label: event.title) }
                guard assistant.proposals.contains(where: { $0.id == event.id }) else { return }
                assistant.didAdd(event.id, title: event.title)
                if assistant.proposals.isEmpty { assistant.close(); panels.close() }
            } else if assistant.proposals.contains(where: { $0.id == event.id }) {
                assistant.reportFailure(store.errorMessage ?? "Could not add “\(event.title)”.")
            }
        }
    }
}

/// Rises a few points into place with a slight scale-up and fade; replays for each new panel.
private struct PanelEntrance<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
            .offset(y: shown || reduceMotion ? 0 : -8)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.88)) { shown = true }
            }
    }
}
#endif
