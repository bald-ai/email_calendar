#if os(macOS)
import SwiftUI

/// The next seven days as an agenda. Events are drop targets for mail; click one to see its linked email.
struct DaysDrawer: View {
    @Environment(AppStore.self) private var store
    @State private var expanded: String?
    @State private var flashing: String?
    @State private var editing: CalendarEvent?

    private var visibleEvents: [CalendarEvent] {
        let visible = Set(store.calendars.filter(\.isVisible).map(\.id))
        return store.events.filter { visible.contains($0.calendarID) && !$0.isCancelled }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let days = AgendaDay.days(from: now, count: 7, events: visibleEvents)
            VStack(alignment: .leading, spacing: 0) {
                DrawerHeader(title: "Days") {
                    if let first = days.first?.date, let last = days.last?.date {
                        Text("\(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated)))")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                            ForEach(days) { day in
                                Section {
                                    dayBody(day, now: now)
                                } header: {
                                    dayHeader(day.date, now: now)
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 28)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: store.plannerReveal) { _, reveal in
                        guard let reveal, case .event(let id) = reveal.target else { return }
                        expanded = id
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                        flash(id)
                    }
                }
            }
        }
        .task(id: Calendar.current.startOfDay(for: .now)) {
            let start = Calendar.current.startOfDay(for: .now)
            await store.refreshCalendar(range: DateInterval(start: start, duration: 8 * 86_400))
        }
        .sheet(item: $editing) { event in CalendarEventEditor(event: event).id(event.cacheID).environment(store) }
    }

    private func dayHeader(_ day: Date, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(PlannerFormat.dayTitle(day, now: now)).font(.system(size: 14, weight: .bold))
            Spacer()
            Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 6)
        .background(Theme.window)
    }

    @ViewBuilder private func dayBody(_ day: AgendaDay, now: Date) -> some View {
        let isToday = Calendar.current.isDate(day.date, inSameDayAs: now)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(day.allDay, id: \.cacheID) { event in row(event, now: now) }
            let nowIndex = isToday ? (day.timed.firstIndex { $0.start > now } ?? day.timed.count) : nil
            ForEach(Array(day.timed.enumerated()), id: \.element.cacheID) { index, event in
                if index == nowIndex { NowLine(now: now) }
                row(event, now: now)
            }
            if let nowIndex, nowIndex == day.timed.count, !day.timed.isEmpty { NowLine(now: now) }
            if day.isEmpty {
                Text("Nothing scheduled").font(.system(size: 12.5)).foregroundStyle(Theme.secondary.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
        }
    }

    private func row(_ event: CalendarEvent, now: Date) -> some View {
        AgendaRow(event: event, now: now, isExpanded: expanded == event.cacheID, isFlashing: flashing == event.cacheID,
                  toggle: {
                      if store.completeLinking(to: .event(event.cacheID)) { return }
                      withAnimation(.easeOut(duration: 0.18)) { expanded = expanded == event.cacheID ? nil : event.cacheID }
                  },
                  open: { editing = event })
            .id(event.cacheID)
    }

    private func flash(_ id: String) {
        flashing = id
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if flashing == id { withAnimation(.easeOut(duration: 0.4)) { flashing = nil } }
        }
    }
}

private struct NowLine: View {
    let now: Date
    var body: some View {
        HStack(spacing: 6) {
            Text(PlannerFormat.time(now)).font(.system(size: 11, weight: .bold)).monospacedDigit()
            Circle().frame(width: 6, height: 6)
            Rectangle().frame(height: 1.5)
        }
        .foregroundStyle(Theme.no)
        .padding(.leading, 10).padding(.vertical, 1)
        .accessibilityLabel("Now, \(PlannerFormat.time(now))")
    }
}

/// One event: a neutral block with time, title, linked-mail count and length.
private struct AgendaRow: View {
    @Environment(AppStore.self) private var store
    let event: CalendarEvent
    let now: Date
    let isExpanded: Bool
    let isFlashing: Bool
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false
    @State private var dropTarget = false

    private var links: [MailLink] { store.links(to: .event(event.cacheID)) }
    private var isPast: Bool { event.end <= now }
    private var isLive: Bool { event.start <= now && now < event.end && !event.isAllDay }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(event.isAllDay ? "All day" : PlannerFormat.time(event.start))
                    .font(.system(size: 12, weight: isLive ? .bold : .medium)).monospacedDigit()
                    .foregroundStyle(isLive ? Theme.text : Theme.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(event.title.isEmpty ? "Untitled" : event.title)
                    .font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if !links.isEmpty {
                    Label("\(links.count)", systemImage: "envelope")
                        .labelStyle(CompactLabel())
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                        .help("\(links.count) linked email\(links.count == 1 ? "" : "s")")
                }
                if !event.isAllDay {
                    Text(PlannerFormat.duration(event)).font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(Theme.secondary.opacity(0.75))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if isExpanded { details }
        }
        .background(background, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(border, style: StrokeStyle(lineWidth: store.linkingThreadID != nil && !dropTarget ? 1.2 : (isLive || dropTarget || isFlashing ? 1.5 : 1),
                                                         dash: store.linkingThreadID != nil && !dropTarget ? [4, 3] : []))
        }
        .opacity(isPast && !isExpanded && !dropTarget ? 0.45 : 1)
        .onHover { hovering = $0 }
        .threadDropTarget(isTargeted: $dropTarget) { ids in
            Task { for id in ids { await store.link(threadID: id, to: .event(event.cacheID)) } }
        }
        .contextMenu {
            Button("Open Event…", action: open)
            Button("Show in Calendar") { store.navigation = .calendar; store.selectedEventID = event.cacheID }
            if let url = event.videoURL { Button("Join Call") { NSWorkspace.shared.open(url) } }
        }
        .help(event.location.isEmpty ? "" : event.location)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(event.title), \(event.isAllDay ? "all day" : PlannerFormat.time(event.start))")
    }

    private var background: Color {
        if dropTarget { return Theme.accent.opacity(0.18) }
        if hovering || isExpanded { return Theme.hover }
        return Theme.card
    }

    private var border: Color {
        if dropTarget || isFlashing || store.linkingThreadID != nil { return Theme.accent }
        if isLive { return Theme.secondary }
        return Theme.line.opacity(0.7)
    }

    /// Linked mail, then the event's own actions.
    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if links.isEmpty {
                Text("No linked email. Drag one here.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .padding(.vertical, 3)
            }
            ForEach(links) { link in LinkedMailRow(link: link) }
            HStack(spacing: 14) {
                Button("Open Event", action: open)
                if let url = event.videoURL { Button("Join") { NSWorkspace.shared.open(url) } }
                if !event.location.isEmpty, event.videoURL == nil {
                    Text(event.location).lineLimit(1).foregroundStyle(Theme.secondary)
                }
            }
            .buttonStyle(QuietButtonStyle()).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.rule)
            .padding(.top, 6)
        }
        .padding(.leading, 70).padding(.trailing, 10).padding(.bottom, 9)
    }
}

/// A linked email inside an expanded event or to-do: sender avatar and subject, opens the thread.
struct LinkedMailRow: View {
    @Environment(AppStore.self) private var store
    let link: MailLink
    @State private var hovering = false
    @State private var opening = false

    var body: some View {
        let thread = store.thread(id: link.threadID)
        HStack(spacing: 8) {
            Button {
                opening = true
                Task { await store.openLinkedThread(id: link.threadID); opening = false }
            } label: {
                HStack(spacing: 8) {
                    Avatar(name: link.senderName, key: link.senderEmail, size: 18)
                    Text(thread?.subject ?? link.subject).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(opening)
            .help("Open email")
            Spacer(minLength: 4)
            Button { Task { await store.unlink(link) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary).opacity(hovering ? 1 : 0)
            .help("Remove link").accessibilityLabel("Remove link")
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}

/// Icon and count close together, for small badges.
struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}
#endif
