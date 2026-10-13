#if os(macOS)
import SwiftUI
import AppKit

struct CalendarEventEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var event: CalendarEvent
    @State private var isSaving = false
    @State private var failure: String?
    @State private var asksScope = false
    @State private var asksDelete = false
    @State private var customRecurrence = ""
    @State private var repeatChoice: RepeatChoice
    @State private var original: CalendarEvent
    /// Set when shown as a panel (in the overlay) instead of a sheet.
    private let onDone: (() -> Void)?

    private enum RepeatChoice: String, CaseIterable {
        case never = "Does not repeat", daily = "Daily", weekdays = "Weekdays", weekly = "Weekly", monthly = "Monthly", yearly = "Yearly", custom = "Custom"
        var rule: String? {
            switch self {
            case .never, .custom: nil
            case .daily: "RRULE:FREQ=DAILY"
            case .weekdays: "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
            case .weekly: "RRULE:FREQ=WEEKLY"
            case .monthly: "RRULE:FREQ=MONTHLY"
            case .yearly: "RRULE:FREQ=YEARLY"
            }
        }
    }

    init(event: CalendarEvent, onDone: (() -> Void)? = nil) {
        _original = State(initialValue: event)
        self.onDone = onDone
        _event = State(initialValue: event)
        let exact = RepeatChoice.allCases.first { $0.rule != nil && event.recurrence == [$0.rule!] }
        _repeatChoice = State(initialValue: event.recurrence.isEmpty ? .never : (exact ?? .custom))
        _customRecurrence = State(initialValue: event.recurrence.joined(separator: "\n"))
    }

    private var calendarColor: Color {
        CalendarGeometry.color(store.calendars.first { $0.id == event.calendarID }?.colorHex ?? "#6586B5")
    }

    private var whenText: String {
        if event.isAllDay {
            let last = event.end.addingTimeInterval(-1)
            return Calendar.current.isDate(event.start, inSameDayAs: last)
                ? event.start.formatted(.dateTime.weekday(.wide).month(.wide).day())
                : "\(event.start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return "\(event.start.formatted(.dateTime.weekday(.wide).month(.wide).day())) · \(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
    }

    private var canEdit: Bool { store.calendars.first { $0.id == event.calendarID }?.canEdit == true }
    private var ownAttendance: EventAttendee? { event.attendees.first(where: \.isSelf) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(original.id.isEmpty ? "NEW EVENT" : "EVENT").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButtonStyle())
                        .foregroundStyle(Theme.secondary).keyboardShortcut(.cancelAction).help("Close (Esc)")
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(calendarColor).frame(width: 12, height: 12)
                    TextField("", text: $event.title, prompt: Text("Add a title").foregroundStyle(Theme.secondary.opacity(0.6)), axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 24, weight: .bold)).disabled(!canEdit || isSaving)
                }
                Text(whenText).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)
            Form {
                Section {
                    Picker("Calendar", selection: $event.calendarID) {
                        ForEach(store.calendars.filter { $0.canEdit || $0.id == event.calendarID }) { calendar in
                            Text(calendar.title).tag(calendar.id)
                        }
                    }
                    Toggle("All day", isOn: $event.isAllDay)
                    DatePicker("Starts", selection: startBinding, displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker(event.isAllDay ? "Through" : "Ends", selection: endBinding, in: event.start..., displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    if original.recurringEventID != nil {
                        Label("Part of a recurring series", systemImage: "repeat").foregroundStyle(.secondary)
                    } else {
                        Picker("Repeat", selection: $repeatChoice) {
                            ForEach(RepeatChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if repeatChoice == .custom {
                            TextField("Recurrence rule", text: $customRecurrence, axis: .vertical)
                                .help("Google Calendar recurrence lines, for example RRULE:FREQ=WEEKLY;BYDAY=MO,WE")
                        }
                    }
                    TextField("Location", text: $event.location)
                    TextField("Notes", text: $event.notes, axis: .vertical).lineLimit(3...8)
                }.disabled(!canEdit || isSaving)

                if let link = CalendarEventDetail.videoLink(for: event) {
                    Section {
                        Link(destination: link) {
                            Label("Join call", systemImage: "video.fill").font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(Theme.yes, in: Capsule()).foregroundStyle(.white)
                        }.buttonStyle(.plain)
                    }
                }
                if !event.attendees.isEmpty {
                    Section("Guests") {
                        ForEach(event.attendees) { attendee in
                            HStack(spacing: 10) {
                                Avatar(name: attendee.name ?? attendee.email, key: attendee.email, size: 22)
                                Text(attendee.name ?? attendee.email).textSelection(.enabled)
                                Spacer()
                                Text(attendee.response == .needsAction ? "No response" : attendee.response.rawValue.capitalized).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                        if ownAttendance != nil {
                            HStack(spacing: 8) {
                                Text("Going?").foregroundStyle(Theme.secondary)
                                Spacer()
                                ForEach([AttendanceStatus.accepted, .tentative, .declined], id: \.self) { response in
                                    let selected = ownAttendance?.response == response
                                    let fill = response == .accepted ? Theme.yes : (response == .declined ? Theme.no : Theme.secondary)
                                    Button(response == .accepted ? "Yes" : (response == .declined ? "No" : "Maybe")) {
                                        Task {
                                            if await store.respondToEvent(event, response: response) { close() }
                                            else { failure = store.errorMessage ?? "Could not update your response." }
                                        }
                                    }.buttonStyle(PillButtonStyle(fill: selected ? fill : fill.opacity(0.25)))
                                }
                            }
                        }
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 10)
            }
            HStack {
                if !original.id.isEmpty && canEdit {
                    Button { asksDelete = true } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(QuietButtonStyle()).foregroundStyle(Theme.no)
                }
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                if canEdit {
                    Button(original.id.isEmpty ? "Create event" : "Save") {
                        if original.isRecurring { asksScope = true } else { save(.thisEvent) }
                    }
                    .buttonStyle(PillButtonStyle(fill: Theme.accent)).keyboardShortcut(.defaultAction)
                    .disabled(isSaving || event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || event.end <= event.start)
                }
            }.padding(18).disabled(isSaving)
        }
        .frame(width: 490, height: 640)
        .background(Theme.card)
        .confirmationDialog("Edit recurring event", isPresented: $asksScope, titleVisibility: .visible) {
            Button("This event") { save(.thisEvent) }
            Button("All events") { save(.allEvents) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(original.isRecurring ? "Delete recurring event?" : "Delete this event?", isPresented: $asksDelete, titleVisibility: .visible) {
            Button(original.isRecurring ? "This event" : "Delete event", role: .destructive) { delete(.thisEvent) }
            if original.isRecurring { Button("All events", role: .destructive) { delete(.allEvents) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: event.isAllDay) { _, allDay in
            if allDay {
                event.start = Calendar.current.startOfDay(for: event.start)
                event.end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(event.start, event.end.addingTimeInterval(-1))))!
            } else {
                event.start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: event.start)!
                event.end = event.start.addingTimeInterval(1800)
            }
        }
    }

    private func close() {
        if let onDone { onDone() } else { dismiss() }
    }

    private var startBinding: Binding<Date> {
        Binding(get: { event.start }, set: { date in
            let duration = event.end.timeIntervalSince(event.start)
            let dayCount = Calendar.current.dateComponents([.day], from: event.start, to: event.end).day ?? 1
            event.start = event.isAllDay ? Calendar.current.startOfDay(for: date) : date
            event.end = event.isAllDay ? Calendar.current.date(byAdding: .day, value: max(1, dayCount), to: event.start)! : event.start.addingTimeInterval(duration)
        })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { event.isAllDay ? event.end.addingTimeInterval(-1) : event.end }, set: { date in
            event.end = event.isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))! : date
        })
    }

    private func save(_ scope: EventEditScope) {
        var updated = event
        updated.title = updated.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let calendar = store.calendars.first(where: { $0.id == updated.calendarID }) { updated.accountID = calendar.accountID }
        if original.recurringEventID == nil {
            updated.recurrence = repeatChoice == .custom ? customRecurrence.split(separator: "\n").map(String.init) : (repeatChoice.rule.map { [$0] } ?? [])
        }
        isSaving = true
        failure = nil
        Task {
            let saved = await store.saveEvent(updated, scope: scope, originalCalendarID: original.calendarID, originalEvent: original,
                                              recoverMovedEdit: { pending in
                                                  event = pending; original = pending
                                                  repeatChoice = pending.recurrence.isEmpty ? .never :
                                                      (RepeatChoice.allCases.first { $0.rule != nil && pending.recurrence == [$0.rule!] } ?? .custom)
                                                  customRecurrence = pending.recurrence.joined(separator: "\n")
                                              })
            isSaving = false
            if saved { close() } else { failure = store.errorMessage ?? "Could not save this event." }
        }
    }

    private func delete(_ scope: EventEditScope) {
        isSaving = true
        failure = nil
        Task {
            let deleted = await store.deleteEvent(original, scope: scope)
            isSaving = false
            if deleted { close() } else { failure = store.errorMessage ?? "Could not delete this event." }
        }
    }
}

struct CalendarEventDetail: View {
    @Environment(AppStore.self) private var store
    let event: CalendarEvent
    /// Edits right here, in a panel, without leaving for the main window.
    let onEdit: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(event.title.isEmpty ? "Untitled event" : event.title).font(.headline).textSelection(.enabled)
            Label {
                Text(event.isAllDay ? event.start.formatted(date: .complete, time: .omitted) : "\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
            } icon: { Image(systemName: "clock") }.font(.caption).foregroundStyle(.secondary)
            if !event.location.isEmpty { Label(event.location, systemImage: "mappin").font(.caption).textSelection(.enabled) }
            if let link = Self.videoLink(for: event) {
                Link(destination: link) { Label("Join call", systemImage: "video.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            }
            if !event.notes.isEmpty {
                ScrollView { Text(event.notes).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
            }
            if event.attendees.contains(where: \.isSelf) {
                HStack {
                    Button("Accept") { Task { await store.respondToEvent(event, response: .accepted) } }
                    Button("Decline") { Task { await store.respondToEvent(event, response: .declined) } }
                }.buttonStyle(.bordered).controlSize(.small)
            }
            HStack {
                Button { onOpen() } label: { Label("Open in app", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                    .buttonStyle(PillButtonStyle(fill: Theme.accent)).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 300)
    }

    static func videoLink(for event: CalendarEvent) -> URL? {
        if let url = event.videoURL, url.scheme == "https" || url.scheme == "http" { return url }
        let text = "\(event.location) \(event.notes)"
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { url in
            guard let host = url.host?.lowercased(), url.scheme == "https" else { return false }
            return host == "meet.google.com" || host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "teams.microsoft.com"
        }
    }
}
#endif
