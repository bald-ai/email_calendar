#if os(macOS)
import SwiftUI
import AppKit

/// The drop-down calendar: a continuously scrolling week timeline, or a scrolling month.
struct OverlayWeekView: View {
    let store: AppStore
    let onClose: () -> Void
    let onOpenInApp: (CalendarEvent?) -> Void
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: () -> Void
    /// Asks the panel for room: in month view, enough height to show every event of the busiest day.
    let onPreferredHeight: (CGFloat?) -> Void

    enum Mode: String, CaseIterable { case week = "Week", month = "Month" }

    @AppStorage("overlay.mode") private var mode: Mode = .week
    @State private var weekPosition = ScrollPosition()
    @State private var hourPosition = ScrollPosition()
    @State private var monthPosition = ScrollPosition(idType: Date.self)
    @State private var weekFirstVisible = Date.now
    @State private var monthFocus = Date.now
    @State private var timelineDayWidth: CGFloat = 0
    @State private var chromeHeight: CGFloat = 60
    @State private var index = CalendarGeometry.DayIndex()
    @State private var selectedEvent: CalendarEvent?
    @State private var quickAddDate: Date?
    @State private var quickAddTitle = ""
    @State private var adding = false
    @State private var quickAddError: String?
    @FocusState private var titleFocused: Bool
    @FocusState private var overlayFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Built once per summon: the overlay is recreated each time it opens, centered on today.
    private let days: [Date]
    private let weeks: [Date]

    init(store: AppStore, onClose: @escaping () -> Void, onOpenInApp: @escaping (CalendarEvent?) -> Void,
         onResizeChanged: @escaping (CGFloat) -> Void, onResizeEnded: @escaping () -> Void,
         onPreferredHeight: @escaping (CGFloat?) -> Void = { _ in }) {
        self.store = store; self.onClose = onClose; self.onOpenInApp = onOpenInApp
        self.onResizeChanged = onResizeChanged; self.onResizeEnded = onResizeEnded
        self.onPreferredHeight = onPreferredHeight
        let calendar = CalendarGeometry.calendar
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)!.start
        let firstDay = calendar.date(byAdding: .weekOfYear, value: -8, to: thisWeek)!
        days = (0..<(7 * 26)).map { calendar.date(byAdding: .day, value: $0, to: firstDay)! }
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: -26, to: thisWeek)!
        weeks = (0..<78).map { calendar.date(byAdding: .weekOfYear, value: $0, to: firstWeek)! }
    }

    private var visibleEvents: [CalendarEvent] { index.all }

    private func rebuildIndex() {
        let visible = Set(store.calendars.filter(\.isVisible).map(\.id))
        index = CalendarGeometry.DayIndex(store.events.filter { visible.contains($0.calendarID) && !$0.isCancelled })
    }

    /// Month view: five rows, each tall enough for the busiest day of the month in view.
    private var preferredHeight: CGFloat? {
        guard mode == .month else { return nil }
        let calendar = CalendarGeometry.calendar
        guard let month = calendar.dateInterval(of: .month, for: monthFocus) else { return nil }
        var busiest = 0
        var day = month.start
        while day < month.end {
            busiest = max(busiest, index.events(on: day).count)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return chromeHeight + OverlayMonth.weekdayHeight + 5 * OverlayMonth.rowHeight(fitting: busiest)
    }

    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.35) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if let date = quickAddDate { quickAddBar(date) }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { chromeHeight = $0 + 9 }
            Group {
                switch mode {
                case .week:
                    OverlayTimeline(days: days, index: index, calendars: store.calendars,
                                    dayPosition: $weekPosition, hourPosition: $hourPosition,
                                    firstVisible: $weekFirstVisible, dayWidth: $timelineDayWidth,
                                    onEvent: { selectedEvent = $0 }, onEmptySlot: beginQuickAdd)
                case .month:
                    OverlayMonth(weeks: weeks, index: index, calendars: store.calendars, position: $monthPosition,
                                 focusMonth: $monthFocus, onEvent: { selectedEvent = $0 }, onDay: openWeek)
                }
            }
            .transition(.opacity)
            Rectangle().fill(Theme.line).frame(height: 1)
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 42, height: 3)
                .frame(maxWidth: .infinity).frame(height: 8)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { onResizeChanged($0.translation.height) }.onEnded { _ in onResizeEnded() })
                .onHover { hovering in if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.window.opacity(0.86)).background(.ultraThinMaterial)
        .environment(store)
        .focusable().focusEffectDisabled()
        .focused($overlayFocused)
        .defaultFocus($overlayFocused, true)
        .onAppear {
            overlayFocused = true
            if mode == .month { scrollMonth(to: .now, animated: false) }
            let span = DateInterval(start: weeks.first!, end: CalendarGeometry.calendar.date(byAdding: .weekOfYear, value: 1, to: weeks.last!)!)
            Task { await store.refreshCalendar(range: span) }
        }
        .onChange(of: store.events, initial: true) { rebuildIndex() }
        .onChange(of: store.calendars) { rebuildIndex() }
        .onChange(of: preferredHeight, initial: true) { _, height in onPreferredHeight(height) }
        .onKeyPress(.escape) {
            if quickAddDate != nil { quickAddDate = nil; overlayFocused = true } else { onClose() }
            return .handled
        }
        .onKeyPress(.leftArrow) { guard !titleFocused else { return .ignored }; step(-1); return .handled }
        .onKeyPress(.rightArrow) { guard !titleFocused else { return .ignored }; step(1); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "tTwWmM")) { press in
            guard !titleFocused else { return .ignored }
            switch press.characters.lowercased() {
            case "w": switchMode(.week)
            case "m": switchMode(.month)
            default: goToToday()
            }
            return .handled
        }
        .popover(item: $selectedEvent, arrowEdge: .bottom) { event in
            CalendarEventDetail(event: event) {
                selectedEvent = nil
                onOpenInApp(event)
            }.id(event.cacheID).environment(store)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            nextUp
            Spacer(minLength: 10)
            Text(title).font(.system(size: 15, weight: .bold)).monospacedDigit().contentTransition(.numericText())
                .animation(animation, value: title)
            HStack(spacing: 2) {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 22) }
                    .help(mode == .week ? "Previous week (←)" : "Previous month (←)")
                Button("Today", action: goToToday).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 6).help("Today (T)")
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22) }
                    .help(mode == .week ? "Next week (→)" : "Next month (→)")
            }
            .padding(2).background(.white.opacity(0.07), in: Capsule())
            modeSwitch
            Button {
                store.navigation = .calendar
                onOpenInApp(nil)
            } label: { Image(systemName: "arrow.up.right.square") }.help("Open calendar in app")
            Button(action: onClose) { Image(systemName: "xmark") }.help("Close (Esc)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Week | Month, as a small pill that slides between the two.
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { item in
                Button { switchMode(item) } label: {
                    Text(item.rawValue).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(mode == item ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background {
                            if mode == item {
                                Capsule().fill(Theme.accent.opacity(0.85)).matchedGeometryEffect(id: "mode", in: modeNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }.help(item == .week ? "Week (W)" : "Month (M)")
            }
        }
        .padding(2).background(.white.opacity(0.07), in: Capsule())
    }
    @Namespace private var modeNamespace

    private var title: String {
        switch mode {
        case .week:
            let calendar = CalendarGeometry.calendar
            let last = calendar.date(byAdding: .day, value: 6, to: weekFirstVisible)!
            let sameMonth = calendar.isDate(weekFirstVisible, equalTo: last, toGranularity: .month)
            let start = weekFirstVisible.formatted(.dateTime.month(.abbreviated).day())
            let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day())
            return "\(start) – \(end)"
        case .month:
            return monthFocus.formatted(.dateTime.month(.wide).year())
        }
    }

    private var nextUp: some View {
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
    }

    private func quickAddBar(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.caption).foregroundStyle(.secondary)
                TextField("Event title", text: $quickAddTitle).textFieldStyle(.plain).focused($titleFocused)
                    .onSubmit(addEvent)
                if adding { ProgressView().controlSize(.mini) }
                Button("Add", action: addEvent).buttonStyle(PillButtonStyle(fill: Theme.accent))
                    .disabled(adding || quickAddTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { quickAddDate = nil; overlayFocused = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if let quickAddError { Text(quickAddError).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(.horizontal, 16).padding(.vertical, 7)
    }

    // MARK: Navigation

    private func switchMode(_ new: Mode) {
        guard new != mode else { return }
        quickAddDate = nil
        let focus = mode == .week ? weekFirstVisible : monthFocus
        withAnimation(.easeOut(duration: 0.18)) { mode = new }
        // Keep your place: the week you were looking at stays in view in the other mode.
        DispatchQueue.main.async {
            if new == .month { scrollMonth(to: focus, animated: false) } else { scrollWeek(to: focus, animated: false) }
        }
    }

    private func goToToday() {
        quickAddDate = nil
        if mode == .week { scrollWeek(to: .now, animated: true, centerHours: true) } else { scrollMonth(to: .now, animated: true) }
    }

    private func step(_ amount: Int) {
        quickAddDate = nil
        let calendar = CalendarGeometry.calendar
        switch mode {
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: weekFirstVisible.addingTimeInterval(3 * 86_400))!.start
            scrollWeek(to: calendar.date(byAdding: .weekOfYear, value: amount, to: start)!, animated: true)
        case .month:
            let month = calendar.dateInterval(of: .month, for: monthFocus)!.start
            scrollMonth(to: calendar.date(byAdding: .month, value: amount, to: month)!, animated: true)
        }
    }

    /// Scroll the timeline so the week containing `date` starts at the left edge.
    private func scrollWeek(to date: Date, animated: Bool, centerHours: Bool = false) {
        let calendar = CalendarGeometry.calendar
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        guard timelineDayWidth > 0, let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: weekStart) }) else { return }
        let x = CGFloat(index) * timelineDayWidth
        withAnimation(animated ? animation : nil) {
            weekPosition.scrollTo(x: x)
            if centerHours { hourPosition.scrollTo(y: OverlayTimeline.nowOffset()) }
        }
    }

    /// Scroll the month so the week holding the 1st of that month (or today) is the second row.
    private func scrollMonth(to date: Date, animated: Bool) {
        let calendar = CalendarGeometry.calendar
        // This month centers on today; any other month starts at its 1st.
        let target = calendar.isDate(date, equalTo: .now, toGranularity: .month)
            ? Date.now : (calendar.dateInterval(of: .month, for: date)?.start ?? date)
        let week = calendar.dateInterval(of: .weekOfYear, for: target)!.start
        let row = calendar.date(byAdding: .weekOfYear, value: -1, to: week)!
        guard let id = weeks.first(where: { calendar.isDate($0, inSameDayAs: row) }) else { return }
        withAnimation(animated ? animation : nil) { monthPosition.scrollTo(id: id, anchor: .top) }
        monthFocus = target
    }

    private func openWeek(_ day: Date) {
        withAnimation(.easeOut(duration: 0.18)) { mode = .week }
        DispatchQueue.main.async { scrollWeek(to: day, animated: false) }
    }

    // MARK: Quick add

    private func beginQuickAdd(_ date: Date) {
        guard store.calendars.contains(where: \.canEdit) else { return }
        quickAddTitle = ""; quickAddError = nil; quickAddDate = date; titleFocused = true
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

    // MARK: Next up

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
}

// MARK: - Week timeline

/// Days run left to right without page breaks. Hours scroll vertically, days scroll horizontally
/// inside them, and the day names above follow the horizontal scroll.
private struct OverlayTimeline: View {
    let days: [Date]
    let index: CalendarGeometry.DayIndex
    let calendars: [CalendarRecord]
    @Binding var dayPosition: ScrollPosition
    @Binding var hourPosition: ScrollPosition
    @Binding var firstVisible: Date
    @Binding var dayWidth: CGFloat
    var onEvent: (CalendarEvent) -> Void
    var onEmptySlot: (Date) -> Void

    static let hourHeight: CGFloat = 46
    static let headerHeight: CGFloat = 50
    private let gutter: CGFloat = 50
    @State private var offsetX: CGFloat = 0
    @State private var positioned = false

    /// Scroll offset that puts the current time about two hours below the top.
    static func nowOffset() -> CGFloat {
        let calendar = CalendarGeometry.calendar
        let minutes = Double(calendar.component(.hour, from: .now) * 60 + calendar.component(.minute, from: .now))
        return max(0, CGFloat(minutes / 60) * hourHeight - 2 * hourHeight)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(40, (geometry.size.width - gutter) / 7)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("All day").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                        .frame(width: gutter, height: Self.headerHeight, alignment: .bottom).padding(.bottom, 6)
                    headerStrip(width: width).frame(height: Self.headerHeight).clipped()
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 0) {
                                ForEach(days, id: \.self) { day in
                                    OverlayDayColumn(day: day, events: index.events(on: day), calendars: calendars, width: width,
                                                     hourHeight: Self.hourHeight, onEvent: onEvent, onEmptySlot: onEmptySlot)
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .scrollPosition($dayPosition)
                        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                            offsetX = x
                            let index = min(max(0, Int((x / width).rounded())), days.count - 1)
                            if !CalendarGeometry.calendar.isDate(firstVisible, inSameDayAs: days[index]) { firstVisible = days[index] }
                        }
                        .frame(height: 24 * Self.hourHeight)
                    }
                }
                .scrollIndicators(.never)
                .scrollPosition($hourPosition)
            }
            .onAppear { dayWidth = width; positionAtToday(width: width) }
            .onChange(of: width) { _, new in
                // Keep the same first day in view when the overlay is resized.
                let index = days.firstIndex { CalendarGeometry.calendar.isDate($0, inSameDayAs: firstVisible) } ?? 0
                dayWidth = new
                dayPosition.scrollTo(x: CGFloat(index) * new)
            }
        }
    }

    /// Only the headers near the visible days are built; they move with the day scroll.
    private func headerStrip(width: CGFloat) -> some View {
        let first = max(0, Int(offsetX / width) - 1)
        let last = min(days.count - 1, first + 9)
        return ZStack(alignment: .topLeading) {
            ForEach(first...last, id: \.self) { index in
                dayHeader(days[index], width: width).offset(x: CGFloat(index) * width - offsetX)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func positionAtToday(width: CGFloat) {
        guard !positioned else { return }
        positioned = true
        let calendar = CalendarGeometry.calendar
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)!.start
        let index = days.firstIndex { calendar.isDate($0, inSameDayAs: weekStart) } ?? 0
        firstVisible = days[index]
        offsetX = CGFloat(index) * width
        DispatchQueue.main.async {
            dayPosition.scrollTo(x: CGFloat(index) * width)
            hourPosition.scrollTo(y: Self.nowOffset())
        }
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour)).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.secondary)
                    .offset(y: -6)
                    .frame(width: gutter - 8, height: Self.hourHeight, alignment: .topTrailing)
                    .frame(width: gutter, alignment: .leading)
            }
        }
    }

    private func dayHeader(_ day: Date, width: CGFloat) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let allDay = index.events(on: day).filter(\.isAllDay)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(day.formatted(.dateTime.weekday(.abbreviated))).foregroundStyle(isToday ? Theme.accent : Theme.secondary)
                Text(day.formatted(.dateTime.day()))
                    .foregroundStyle(isToday ? .white : Theme.text)
                    .padding(.horizontal, isToday ? 6 : 0).padding(.vertical, isToday ? 1 : 0)
                    .background(isToday ? Theme.accent : .clear, in: Capsule())
                if calendar.component(.day, from: day) == 1 {
                    Text(day.formatted(.dateTime.month(.abbreviated))).foregroundStyle(Theme.secondary)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            if let first = allDay.first {
                Button { onEvent(first) } label: {
                    Text(first.title + (allDay.count > 1 ? "  +\(allDay.count - 1)" : ""))
                        .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(CalendarGeometry.textColor(hex(for: first)))
                        .background(CalendarGeometry.color(hex(for: first)), in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 6)
        .frame(width: width, height: Self.headerHeight, alignment: .topLeading)
        .background(isToday ? Theme.accent.opacity(0.08) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .overlay(alignment: .leading) {
            if CalendarGeometry.calendar.component(.weekday, from: day) == CalendarGeometry.calendar.firstWeekday {
                Rectangle().fill(Theme.line).frame(width: 1)
            }
        }
    }

    private func hex(for event: CalendarEvent) -> String {
        calendars.first { $0.id == event.calendarID }?.colorHex ?? "#6586B5"
    }

    private func hourLabel(_ hour: Int) -> String {
        hour == 0 ? "" : Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!.formatted(.dateTime.hour())
    }
}

private struct OverlayDayColumn: View {
    let day: Date
    let events: [CalendarEvent]
    let calendars: [CalendarRecord]
    let width: CGFloat
    let hourHeight: CGFloat
    var onEvent: (CalendarEvent) -> Void
    var onEmptySlot: (Date) -> Void

    var body: some View {
        let isToday = Calendar.current.isDateInToday(day)
        let isPast = day < Calendar.current.startOfDay(for: .now)
        let weekStarts = CalendarGeometry.calendar.component(.weekday, from: day) == CalendarGeometry.calendar.firstWeekday
        ZStack(alignment: .topLeading) {
            Rectangle().fill(isToday ? Theme.accent.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    onEmptySlot(CalendarGeometry.date(at: Double(value.location.y / hourHeight * 60), on: day))
                })
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 0.5).frame(height: hourHeight, alignment: .top)
                }
            }.allowsHitTesting(false)
            ForEach(CalendarGeometry.placements(events, day: day)) { placement in
                chip(placement)
            }
            if isToday {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 0) {
                        Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: -3)
                        Rectangle().fill(Color.red.opacity(0.85)).frame(height: 1.5)
                    }
                    .offset(y: CGFloat(CalendarGeometry.minutes(context.date, on: day)) / 60 * hourHeight - 3.5)
                }.allowsHitTesting(false)
            }
        }
        .frame(width: width, height: 24 * hourHeight)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line.opacity(weekStarts ? 1 : 0.5)).frame(width: weekStarts ? 1 : 0.5) }
        .opacity(isPast ? 0.6 : 1)
    }

    private func chip(_ placement: CalendarGeometry.Placement) -> some View {
        let hex = calendars.first { $0.id == placement.event.calendarID }?.colorHex ?? "#6586B5"
        let color = CalendarGeometry.color(hex)
        let chipWidth = max(12, (width - 6) / CGFloat(placement.lanes) - 2)
        let height = max(18, CGFloat(placement.end - placement.start) / 60 * hourHeight - 2)
        let declined = placement.event.attendees.contains { $0.isSelf && $0.response == .declined }
        return Button { onEvent(placement.event) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(placement.event.title.isEmpty ? "Untitled" : placement.event.title)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(height > 34 ? 2 : 1).strikethrough(declined)
                if height > 30 {
                    Text(placement.event.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 9.5)).opacity(0.8)
                }
            }
            .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 3)
            .frame(width: chipWidth, height: height, alignment: .topLeading)
            .foregroundStyle(Theme.text)
            .background(color.opacity(declined ? 0.15 : 0.35), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 2) }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .offset(x: CGFloat(placement.lane) * (chipWidth + 2) + 3, y: CGFloat(placement.start) / 60 * hourHeight + 1)
        .help("\(placement.event.title), \(placement.event.start.formatted(date: .omitted, time: .shortened))")
    }
}

// MARK: - Month

/// Weeks flow continuously; months are told apart by shading and a label on the 1st.
private struct OverlayMonth: View {
    let weeks: [Date]
    let index: CalendarGeometry.DayIndex
    let calendars: [CalendarRecord]
    @Binding var position: ScrollPosition
    @Binding var focusMonth: Date
    var onEvent: (CalendarEvent) -> Void
    var onDay: (Date) -> Void

    static let weekdayHeight: CGFloat = 24
    private var weekdayHeight: CGFloat { Self.weekdayHeight }

    /// Day number row, then one 16pt line per event (14pt text plus 2pt spacing), plus breathing room.
    static let lineHeight: CGFloat = 16
    static func rowHeight(fitting events: Int) -> CGFloat { 30 + CGFloat(max(2, events)) * lineHeight + 6 }

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = max(54, (geometry.size.height - weekdayHeight) / 5)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { offset in
                        Text(CalendarGeometry.calendar.date(byAdding: .day, value: offset, to: weeks[0])!.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    }
                }
                .frame(height: weekdayHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(weeks, id: \.self) { week in
                            weekRow(week, height: rowHeight).id(week)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.never)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
                    // The month of the second visible row's middle day names what you're looking at.
                    let index = min(weeks.count - 1, max(0, Int((y / rowHeight).rounded()) + 1))
                    let middle = CalendarGeometry.calendar.date(byAdding: .day, value: 3, to: weeks[index])!
                    if !CalendarGeometry.calendar.isDate(middle, equalTo: focusMonth, toGranularity: .month) { focusMonth = middle }
                }
            }
        }
    }

    private func weekRow(_ week: Date, height: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                dayCell(CalendarGeometry.calendar.date(byAdding: .day, value: offset, to: week)!, height: height)
            }
        }
        .frame(height: height)
    }

    private func dayCell(_ day: Date, height: CGFloat) -> some View {
        let calendar = CalendarGeometry.calendar
        let isToday = calendar.isDateInToday(day)
        let dayNumber = calendar.component(.day, from: day)
        let inFocus = calendar.isDate(day, equalTo: focusMonth, toGranularity: .month)
        let shaded = calendar.component(.month, from: day) % 2 == 0
        let dayEvents = index.events(on: day)
        let shown = min(dayEvents.count, max(1, Int((height - 30) / Self.lineHeight)))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(dayNumber)")
                    .font(.system(size: 12, weight: isToday || dayNumber == 1 ? .bold : .medium))
                    .foregroundStyle(isToday ? .white : Theme.text)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(isToday ? Theme.accent : .clear, in: Circle())
                if dayNumber == 1 {
                    Text(day.formatted(.dateTime.month(.abbreviated))).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
                if dayEvents.count > shown {
                    Text("+\(dayEvents.count - shown)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            ForEach(dayEvents.prefix(shown), id: \.cacheID) { event in
                let hex = calendars.first { $0.id == event.calendarID }?.colorHex ?? "#6586B5"
                Button { onEvent(event) } label: {
                    HStack(spacing: 4) {
                        if event.isAllDay {
                            Text(event.title).lineLimit(1).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(CalendarGeometry.textColor(hex))
                                .background(CalendarGeometry.color(hex), in: RoundedRectangle(cornerRadius: 3))
                        } else {
                            Circle().fill(CalendarGeometry.color(hex)).frame(width: 6, height: 6)
                            Text(event.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium)).frame(height: 14).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(shaded ? Color.white.opacity(0.025) : .clear)
        .background(isToday ? Theme.accent.opacity(0.08) : .clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 0.5) }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line.opacity(dayNumber == 1 ? 1 : 0.5)).frame(width: dayNumber == 1 ? 1.5 : 0.5) }
        .opacity(inFocus ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { onDay(day) }
        .help("Open the week of \(day.formatted(.dateTime.month(.abbreviated).day()))")
    }
}
#endif
