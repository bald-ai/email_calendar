#if os(macOS)
import SwiftUI

/// Mail in the middle, the next seven days in a drawer on the left, to-dos in a drawer on the right.
/// One drawer shows at a time. Swipe with two fingers, press ← / →, or click a drawer's spine.
struct MailWorkspace: View {
    @Environment(AppStore.self) private var store
    var searchFocus: () -> Void
    /// Live finger travel during a swipe, in points; 0 when the drawers are at rest.
    @State private var swipe: CGFloat = 0
    @State private var swiping = false

    /// How far a swipe travels for one full step.
    private let stepLength: CGFloat = 260
    static let settle = Animation.spring(response: 0.36, dampingFraction: 0.88)

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let daysWidth = min(320, max(270, total * 0.22))
            let todoWidth = min(360, max(290, total * 0.24))
            let base = Double(store.drawerPosition)
            let raw = base + Double(swipe / stepLength)
            // A swipe moves at most one step from where it started, and never past the last drawer.
            let position = min(1, max(-1, min(base + 1, max(base - 1, raw))))
            HStack(spacing: 0) {
                DrawerColumn(edge: .leading, width: daysWidth, shown: position) {
                    DaysDrawer()
                } spine: {
                    DrawerSpine(side: 1)
                }
                MailRootView(searchFocus: searchFocus)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { if store.linkingThreadID != nil { LinkModeBanner().padding(.top, 6) } }
                DrawerColumn(edge: .trailing, width: todoWidth, shown: -position) {
                    TodoDrawer()
                } spine: {
                    DrawerSpine(side: -1)
                }
            }
            // Past the last drawer the row gives a little and springs back, so the swipe never feels dead.
            .offset(x: rubberBand(raw - position) * 48)
        }
        .background(DrawerSwipeMonitor(onChange: { distance in
            swiping = true
            // One step per swipe, as in Ulysses.
            swipe = max(-1.2 * stepLength, min(1.2 * stepLength, distance))
        }, onEnd: finishSwipe))
        .animation(swiping ? nil : Self.settle, value: store.drawerPosition)
        .animation(swiping ? nil : Self.settle, value: swipe)
        .onChange(of: store.navigation) { _, _ in store.cancelLinking() }
    }

    private func rubberBand(_ overshoot: Double) -> Double {
        overshoot == 0 ? 0 : (overshoot > 0 ? 1 : -1) * (1 - 1 / (1 + abs(overshoot) * 2))
    }

    private func finishSwipe(distance: CGFloat, velocity: CGFloat) {
        let travelled = distance / stepLength
        var step = 0
        if travelled > 0.3 || (velocity > 500 && travelled > 0.05) { step = 1 }
        else if travelled < -0.3 || (velocity < -500 && travelled < -0.05) { step = -1 }
        swiping = false
        withAnimation(Self.settle) {
            swipe = 0
            store.slideDrawers(step)
        }
    }
}

/// A drawer that folds to a thin spine. `shown` runs 0…1; the content slides out under the outer edge
/// instead of squeezing, and the spine fades in as it goes.
private struct DrawerColumn<Content: View, Spine: View>: View {
    let edge: HorizontalEdge
    let width: CGFloat
    let shown: Double
    @ViewBuilder var content: Content
    @ViewBuilder var spine: Spine
    static var spineWidth: CGFloat { 34 }

    var body: some View {
        let fraction = min(1, max(0, shown))
        let visible = Self.spineWidth + (width - Self.spineWidth) * fraction
        let inner: Alignment = edge == .leading ? .trailing : .leading
        content
            .frame(width: width)
            .frame(width: visible, alignment: inner)
            .clipped()
            .allowsHitTesting(fraction > 0.5)
            .accessibilityHidden(fraction < 0.5)
            .overlay(alignment: edge == .leading ? .leading : .trailing) {
                spine.frame(width: Self.spineWidth)
                    .opacity(1 - min(1, fraction * 2.5))
                    .allowsHitTesting(fraction < 0.3)
                    .accessibilityHidden(fraction >= 0.3)
            }
            .background(Theme.window)
            .overlay(alignment: edge == .leading ? .trailing : .leading) {
                Rectangle().fill(Theme.line).frame(width: 1)
            }
    }
}

/// What is left of a folded drawer: its icon and one hint. Click it, or hold a dragged email over it, to open.
private struct DrawerSpine: View {
    @Environment(AppStore.self) private var store
    let side: Int
    @State private var hovering = false
    @State private var dropHover = false
    @State private var springTask: Task<Void, Never>?

    var body: some View {
        Button { store.drawerPosition = side } label: {
            VStack(spacing: 8) {
                Image(systemName: side == 1 ? "calendar" : "checklist").font(.system(size: 14, weight: .semibold))
                hint
                Spacer()
            }
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(dropHover ? Theme.accent.opacity(0.22) : (hovering ? Theme.hover : Theme.window))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering || dropHover ? Theme.text : Theme.secondary)
        .onHover { hovering = $0 }
        .help(side == 1 ? "Show Days (←)" : "Show To-do (→)")
        .accessibilityLabel(side == 1 ? "Show Days" : "Show To-do")
        // Spring-loaded, like a Finder folder: hovering a dragged email here opens the drawer.
        .dropDestination(for: ThreadDragItem.self) { _, _ in false } isTargeted: { targeted in
            dropHover = targeted
            springTask?.cancel()
            guard targeted else { return }
            springTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(MailWorkspace.settle) { store.drawerPosition = side }
            }
        }
    }

    @ViewBuilder private var hint: some View {
        if side == 1 {
            if let next = store.events.filter({ !$0.isAllDay && !$0.isCancelled && $0.start > .now && Calendar.current.isDateInToday($0.start) })
                .min(by: { $0.start < $1.start }) {
                Text(next.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .help("Next: \(next.title)")
            }
        } else {
            let count = store.planner.openTodos.count
            if count > 0 {
                Text("\(count)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.line, in: Capsule())
            }
        }
    }
}

/// Shown while link mode waits for an event or to-do to be clicked.
private struct LinkModeBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
            Text("Click an event or to-do to link “\(store.linkingThreadID.flatMap { store.thread(id: $0)?.subject } ?? "this email")”")
                .lineLimit(1)
            Button("Cancel") { store.cancelLinking() }
                .buttonStyle(QuietButtonStyle()).fontWeight(.semibold).foregroundStyle(Theme.back)
                .help("Cancel (Esc)")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Theme.actionBar, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .frame(maxWidth: 560)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
#endif
