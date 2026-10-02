#if os(macOS)
import SwiftUI

struct CalendarMainView: View {
    @Environment(AppStore.self) private var store
    @State private var mode: Mode = .week
    @State private var anchor = Date.now
    @State private var scrollToNow = UUID()
    @State private var editing: CalendarEvent?
    @State private var showCalendars = false

    private enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }
    private var visibleEvents: [CalendarEvent] {
        let visible = Set(store.calendars.filter(\.isVisible).map(\.id))
        return store.events.filter { visible.contains($0.calendarID) && !$0.isCancelled }
    }
    private var range: DateInterval {
        let calendar = CalendarGeometry.calendar
        return calendar.dateInterval(of: mode == .month ? .month : (mode == .day ? .day : .weekOfYear), for: anchor)!
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(anchor.formatted(.dateTime.month(.wide).year())).font(.title2.weight(.medium))
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("Previous \(mode.rawValue.lowercased())")
                Button("Today") { anchor = .now; scrollToNow = UUID() }
                Button { move(1) } label: { Image(systemName: "chevron.right") }.help("Next \(mode.rawValue.lowercased())")
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 190)
            }.padding(16)
            Divider()
            if store.calendars.isEmpty {
                ContentUnavailableView("Your calendars", systemImage: "calendar", description: Text("Sign in with Google to bring your calendars here."))
            } else if mode == .month {
                CalendarMonthGrid(anchor: anchor, events: visibleEvents, calendars: store.calendars, onEvent: { editing = $0 }, onDay: { date in
                    anchor = date; mode = .day
                }, onNew: createEvent)
            } else {
                CalendarWeekGrid(days: mode == .day ? [Calendar.current.startOfDay(for: anchor)] : CalendarGeometry.days(inWeekContaining: anchor),
                                 events: visibleEvents, calendars: store.calendars, scrollToNow: scrollToNow,
                                 onEvent: { editing = $0 }, onEmptySlot: createEvent)
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showCalendars.toggle() } label: { Label("Calendars", systemImage: "list.bullet") }
                    .popover(isPresented: $showCalendars) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Calendars").font(.headline)
                            ForEach(store.calendars) { calendar in
                                Toggle(isOn: Binding(get: { store.calendars.first { $0.id == calendar.id }?.isVisible ?? false }, set: { visible in
                                    Task { await store.setCalendarVisible(calendar, visible) }
                                })) {
                                    Label {
                                        Text(calendar.title)
                                    } icon: {
                                        Circle().fill(CalendarGeometry.color(calendar.colorHex)).frame(width: 9, height: 9)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }.padding(18).frame(minWidth: 250)
                    }
            }
            ToolbarItem {
                Button { createEvent(CalendarGeometry.date(at: Double(Calendar.current.component(.hour, from: .now)) * 60, on: anchor)) } label: {
                    Label("New event", systemImage: "plus")
                }.disabled(!store.calendars.contains(where: \.canEdit))
            }
        }
        .task(id: "\(mode.rawValue)-\(range.start.timeIntervalSince1970)") { await store.refreshCalendar(range: range) }
        .sheet(item: $editing, onDismiss: { store.selectedEventID = nil }) { event in CalendarEventEditor(event: event).id(event.cacheID).environment(store) }
        .onChange(of: store.selectedEventID) { _, eventID in
            if let selected = selectedEvent(for: eventID) {
                anchor = selected.start
                editing = selected
            }
        }
        .onAppear {
            if let selected = selectedEvent(for: store.selectedEventID) {
                anchor = selected.start; editing = selected
            }
        }
    }

    private func selectedEvent(for identifier: String?) -> CalendarEvent? {
        guard let identifier else { return nil }
        return store.events.first { $0.cacheID == identifier } ?? store.events.first { $0.id == identifier }
    }

    private func move(_ amount: Int) {
        let component: Calendar.Component = mode == .month ? .month : (mode == .day ? .day : .weekOfYear)
        anchor = CalendarGeometry.calendar.date(byAdding: component, value: amount, to: anchor)!
    }

    private func createEvent(_ date: Date) {
        guard let calendar = store.calendars.first(where: { $0.isPrimary && $0.canEdit }) ?? store.calendars.first(where: \.canEdit) else { return }
        editing = CalendarEvent(id: "", calendarID: calendar.id, accountID: calendar.accountID, start: date, end: date.addingTimeInterval(1800))
    }
}

private struct CalendarMonthGrid: View {
    let anchor: Date
    let events: [CalendarEvent]
    let calendars: [CalendarRecord]
    let onEvent: (CalendarEvent) -> Void
    let onDay: (Date) -> Void
    let onNew: (Date) -> Void

    var body: some View {
        let days = CalendarGeometry.monthDays(containing: anchor)
        let rows = days.count / 7
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(CalendarGeometry.days(inWeekContaining: anchor), id: \.self) { day in
                        Text(day.formatted(.dateTime.weekday(.wide))).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(Array(days[(row * 7)..<(row * 7 + 7)]), id: \.self) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                Button { onDay(day) } label: {
                                    Text(day.formatted(.dateTime.day())).font(.caption.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
                                        .frame(width: 24, height: 24)
                                        .background(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                                }.buttonStyle(.plain)
                                let daily = events.filter { CalendarGeometry.overlaps($0, day: day) }.sorted { $0.start < $1.start }
                                let limit = max(1, Int((geometry.size.height / CGFloat(rows) - 50) / 22))
                                ForEach(daily.prefix(limit), id: \.cacheID) { event in
                                    Button { onEvent(event) } label: {
                                        HStack(spacing: 3) {
                                            if !event.isAllDay { Text(event.start.formatted(date: .omitted, time: .shortened)).opacity(0.8) }
                                            Text(event.title.isEmpty ? "Untitled" : event.title).lineLimit(1)
                                        }
                                        .font(.system(size: 10)).padding(.horizontal, 4).padding(.vertical, 3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(CalendarGeometry.textColor(calendars.first { $0.id == event.calendarID }?.colorHex ?? "#6586B5"))
                                        .background(CalendarGeometry.color(calendars.first { $0.id == event.calendarID }?.colorHex ?? "#6586B5"), in: RoundedRectangle(cornerRadius: 3))
                                    }.buttonStyle(.plain)
                                }
                                if daily.count > limit {
                                    Button("\(daily.count - limit) more") { onDay(day) }.font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onNew(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!) }
                            .background(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.04) : .clear)
                            .opacity(Calendar.current.isDate(day, equalTo: anchor, toGranularity: .month) ? 1 : 0.45)
                            .overlay { Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
                        }
                    }
                }
            }
        }
    }
}
#endif
