#if os(macOS)
import SwiftUI
import AppKit

struct OverlayWeekView: View {
    let store: AppStore
    let onClose: () -> Void
    let onOpenInApp: (CalendarEvent?) -> Void
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: () -> Void
    @State private var anchor = Date.now
    @State private var navigationDirection = 1
    @State private var scrollToNow = UUID()
    @State private var selectedEvent: CalendarEvent?
    @State private var quickAddDate: Date?
    @State private var quickAddTitle = ""
    @State private var adding = false
    @State private var quickAddError: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var overlayFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleEvents: [CalendarEvent] {
        let visible = Set(store.calendars.filter(\.isVisible).map(\.id))
        return store.events.filter { visible.contains($0.calendarID) && !$0.isCancelled }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let date = quickAddDate {
                HStack(spacing: 9) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.caption).foregroundStyle(.secondary)
                    TextField("Event title", text: $quickAddTitle).textFieldStyle(.plain).focused($titleFocused)
                        .onSubmit(addEvent)
                    if adding { ProgressView().controlSize(.mini) }
                    Button("Add", action: addEvent).disabled(adding || quickAddTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { quickAddDate = nil; overlayFocused = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(.horizontal, 14).padding(.vertical, 7)
                if let quickAddError { Text(quickAddError).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 14).padding(.bottom, 5) }
            }
            CalendarWeekGrid(days: CalendarGeometry.days(inWeekContaining: anchor), events: visibleEvents,
                             calendars: store.calendars, compact: true, scrollToNow: scrollToNow,
                             onEvent: { selectedEvent = $0 }, onEmptySlot: { date in
                guard store.calendars.contains(where: \.canEdit) else { return }
                quickAddTitle = ""; quickAddError = nil; quickAddDate = date; titleFocused = true
            })
            .id(CalendarGeometry.days(inWeekContaining: anchor).first!)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: navigationDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: navigationDirection > 0 ? .leading : .trailing).combined(with: .opacity)))
            .clipped()
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 42, height: 3)
                .frame(maxWidth: .infinity).frame(height: 7)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { onResizeChanged($0.translation.height) }.onEnded { _ in onResizeEnded() })
                .onHover { hovering in if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        }
        .background(Theme.window.opacity(0.82)).background(.ultraThinMaterial)
        .environment(store)
        .focusable().focusEffectDisabled()
        .focused($overlayFocused)
        .defaultFocus($overlayFocused, true)
        .onAppear { overlayFocused = true }
        .onKeyPress(.escape) {
            if quickAddDate != nil { quickAddDate = nil; overlayFocused = true } else { onClose() }
            return .handled
        }
        .onKeyPress(.leftArrow) { guard !titleFocused else { return .ignored }; move(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !titleFocused else { return .ignored }; move(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "tT")) { _ in
            guard !titleFocused else { return .ignored }
            anchor = .now; scrollToNow = UUID(); return .handled
        }
        .popover(item: $selectedEvent, arrowEdge: .bottom) { event in
            CalendarEventDetail(event: event) {
                selectedEvent = nil
                onOpenInApp(event)
            }.id(event.cacheID).environment(store)
        }
        .overlay { HorizontalWeekSwipe(onSwipe: move).allowsHitTesting(false) }

    }

    private var header: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let next = nextEvent(at: context.date)
                HStack(spacing: 8) {
                    if let next {
                        let color = CalendarGeometry.color(store.calendars.first { $0.id == next.calendarID }?.colorHex ?? "#6586B5")
                        let isNow = next.start <= context.date
                        // The anchor: one glance answers "what's next?" without reading the grid.
                        HStack(spacing: 7) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(countdown(for: next, at: context.date)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(color.opacity(isNow ? 0.45 : 0.25), in: Capsule())
                        .onTapGesture { selectedEvent = next }
                        if let url = next.videoURL, next.start.timeIntervalSince(context.date) < 15 * 60 {
                            Button {
                                NSWorkspace.shared.open(url)
                                onClose()
                            } label: { Label("Join", systemImage: "video.fill").font(.system(size: 12, weight: .semibold)) }
                                .buttonStyle(PillButtonStyle(fill: Theme.yes)).help("Join the call")
                        }
                    } else {
                        Text(store.account == nil ? "Sign in to see your week" : "Nothing coming up.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 10)
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
            Button("Today") { anchor = .now; scrollToNow = UUID() }
            Button { move(1) } label: { Image(systemName: "chevron.right") }
            Text("Week \(CalendarGeometry.calendar.component(.weekOfYear, from: anchor)) · \(anchor.formatted(.dateTime.month(.abbreviated).year()))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button {
                store.navigation = .calendar
                onOpenInApp(nil)
            } label: { Image(systemName: "arrow.up.right.square") }.help("Open calendar in app")
            Button(action: onClose) { Image(systemName: "xmark") }.help("Close (Esc)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func nextEvent(at now: Date) -> CalendarEvent? {
        let upcoming = visibleEvents.filter { !$0.isAllDay && $0.end > now && !$0.attendees.contains(where: { $0.isSelf && $0.response == .declined }) }
        return upcoming.filter { $0.start <= now }.min { $0.end < $1.end } ?? upcoming.min { $0.start < $1.start }
    }

    private func countdown(for event: CalendarEvent, at now: Date) -> String {
        let title = event.title.isEmpty ? "Untitled event" : event.title
        if event.start <= now {
            return "Now: \(title), ends in \(max(1, Int(ceil(event.end.timeIntervalSince(now) / 60)))) min"
        }
        let minutes = max(1, Int(ceil(event.start.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "Next: \(title) in \(minutes) min" }
        if minutes < 1440 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return "Next: \(title) in \(hours)h\(remainder == 0 ? "" : " \(remainder)m")"
        }
        return "Next: \(title) · \(event.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    private func move(_ amount: Int) {
        quickAddDate = nil
        navigationDirection = amount
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            anchor = CalendarGeometry.calendar.date(byAdding: .weekOfYear, value: amount, to: anchor)!
        }
        let days = CalendarGeometry.days(inWeekContaining: anchor)
        let end = CalendarGeometry.calendar.date(byAdding: .day, value: 1, to: days.last!)!
        Task { await store.refreshCalendar(range: DateInterval(start: days.first!, end: end)) }
    }

    private func addEvent() {
        guard let start = quickAddDate, !adding else { return }
        let title = quickAddTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        adding = true
        quickAddError = nil
        Task {
            let saved = await store.quickAdd(title: title, start: start)
            adding = false
            if saved { quickAddDate = nil; overlayFocused = true }
            else { quickAddError = store.errorMessage ?? "Could not add this event." }
        }
    }
}

/// A local event monitor observes horizontal trackpad scrolling while leaving
/// ordinary vertical scrolling to the native ScrollView.
private struct HorizontalWeekSwipe: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let view = SwipeView()
        view.onSwipe = onSwipe
        return view
    }
    func updateNSView(_ nsView: SwipeView, context: Context) { nsView.onSwipe = onSwipe }
    static func dismantleNSView(_ nsView: SwipeView, coordinator: ()) { nsView.stopMonitoring() }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var horizontal: CGFloat = 0
        private var paged = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors run on the main thread; NSEvent just isn't marked Sendable.
                nonisolated(unsafe) let event = event
                let swallow = MainActor.assumeIsolated { self?.handle(event) == nil }
                return swallow ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, event.hasPreciseScrollingDeltas else { return event }
            if event.phase.contains(.began) { horizontal = 0; paged = false }
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.4 {
                horizontal += event.scrollingDeltaX
                if abs(horizontal) > 55 && !paged {
                    paged = true
                    onSwipe?(horizontal < 0 ? 1 : -1)
                }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) { horizontal = 0; paged = false }
                return nil
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { horizontal = 0; paged = false }
            return event
        }
    }
}
#endif
