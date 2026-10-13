#if os(macOS)
import SwiftUI

/// The ✨ panel floating over the overlay. Step one: paste, drop or choose a screenshot, or describe
/// the event. Step two: one card per event, with the day and time written out large and anything
/// doubtful called out, so a wrong date is caught before it's saved.
struct AssistantPanel: View {
    @Bindable var assistant: EventAssistant
    let onPickImages: () -> Void
    /// Calendars you can add to; the first primary one is the default.
    var calendars: [CalendarRecord] = []
    let onAdd: (_ event: ExtractedEvent, _ withAlarm: Bool) -> Void
    let onClose: () -> Void
    /// Events already in the calendar that this one would duplicate or overlap.
    var conflicts: (ExtractedEvent) -> [EventConflicts.Conflict] = { _ in [] }

    @FocusState private var textFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(icon: "sparkles", tint: Theme.accent, title: "Add with AI",
                        subtitle: EventAssistant.modelSummary, onClose: onClose)
            if assistant.proposals.isEmpty { compose } else { results }
        }
        .padding(20)
        .frame(width: 620)
        .panelCard()
        .dropDestination(for: URL.self) { urls, _ in
            urls.compactMap(NSImage.init(contentsOf:)).map { assistant.attach($0) }.contains(true)
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: assistant.focusRequest, initial: true) { textFocused = true }
        .onAppear { assistant.calendarNames = calendars.map(\.title) }
    }

    // MARK: Step 1

    private var compose: some View {
        VStack(alignment: .leading, spacing: 14) {
            if assistant.attachments.isEmpty { dropZone } else { thumbnails }

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(assistant.attachments.isEmpty ? "Or describe it" : "Anything to add? (optional)")
                TextField(assistant.attachments.isEmpty ? "e.g. dentist Thursday 9:40 at Korunní 48" : "e.g. only the Saturday show, or: it's in Brno",
                          text: $assistant.text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 15))
                    .panelField(focused: textFocused, tint: Theme.accent)
                    .focused($textFocused)
                    .onSubmit(assistant.run)
            }

            if let message = assistant.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Theme.unread)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: assistant.run) {
                if assistant.isWorking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small).tint(.white); Text("Reading…") }
                } else {
                    Label("Find events", systemImage: "sparkles")
                }
            }
            .buttonStyle(PanelPrimaryButtonStyle(fill: Theme.accent))
            .disabled(!assistant.canRun)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.plus").font(.system(size: 30, weight: .regular))
                .foregroundStyle(dropTargeted ? Theme.accent : Theme.secondary)
            Text("Paste a screenshot  ⌘V").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 4) {
                Text("or drop an image here, or").foregroundStyle(Theme.secondary)
                Button("choose a file…", action: onPickImages).buttonStyle(.link)
            }
            .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .background((dropTargeted ? Theme.accent.opacity(0.12) : Theme.window), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(dropTargeted ? Theme.accent : Theme.line,
                                                                 style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }

    private var thumbnails: some View {
        HStack(spacing: 10) {
            ForEach(assistant.attachments) { attachment in
                Image(nsImage: attachment.image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 132, height: 88).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    .overlay(alignment: .topTrailing) {
                        Button { assistant.remove(attachment.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22).background(.black.opacity(0.65), in: Circle())
                        }
                        .buttonStyle(.plain).padding(5).help("Remove")
                    }
            }
            Button(action: onPickImages) {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    Text("Add").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.secondary)
                .frame(width: 88, height: 88)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Add another image (or paste with ⌘V)")
            Spacer(minLength: 0)
        }
    }

    // MARK: Step 2

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(assistant.proposals.count == 1 ? "Found 1 event. Check the day and time, then add it."
                 : "Found \(assistant.proposals.count) events. Check each day and time, then add them.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($assistant.proposals) { $event in
                        ProposalCard(event: $event, calendars: calendars, conflicts: conflicts(event), onAdd: { onAdd(event, $0) })
                            .disabled(assistant.pendingAdds.contains(event.id))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            if let message = assistant.message {
                Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.yes)
            }
            HStack(spacing: 10) {
                Button { assistant.startOver() } label: { Label("Start over", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(PanelSecondaryButtonStyle())
                let addable = assistant.proposals.filter { !assistant.pendingAdds.contains($0.id) && !conflicts($0).contains { $0.kind == .duplicate } }
                if assistant.proposals.count > 1 && !addable.isEmpty {
                    let skipped = assistant.proposals.count - addable.count
                    Button { for event in addable { onAdd(event, event.shouldSetAlarm) } } label: {
                        Label(skipped == 0 ? "Add all \(addable.count)"
                              : addable.count == 1 ? "Add the new one, skip the duplicate"
                              : "Add \(addable.count) new, skip \(skipped) duplicate\(skipped == 1 ? "" : "s")",
                              systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(PanelPrimaryButtonStyle(fill: Theme.accent))
                }
            }
        }
    }
}

// MARK: - One found event

struct ProposalCard: View {
    @Binding var event: ExtractedEvent
    var calendars: [CalendarRecord] = []
    var conflicts: [EventConflicts.Conflict] = []
    let onAdd: (_ withAlarm: Bool) -> Void
    @State private var editing = false
    private var withAlarm: Binding<Bool> { Binding(get: { event.shouldSetAlarm }, set: { event.wantsAlarm = $0 }) }

    init(event: Binding<ExtractedEvent>, calendars: [CalendarRecord] = [], conflicts: [EventConflicts.Conflict] = [],
         onAdd: @escaping (_ withAlarm: Bool) -> Void) {
        _event = event
        self.calendars = calendars
        self.conflicts = conflicts
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $event.title).textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold))

            HStack(alignment: .center, spacing: 14) {
                DayBadge(date: event.start)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dayLine(event)).font(.system(size: 14, weight: .semibold))
                    Text(Self.timeLine(event)).font(.system(size: 24, weight: .bold)).monospacedDigit()
                    Text(Self.distanceText(event)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(editing ? "Done" : "Change") { editing.toggle() }.buttonStyle(PanelSecondaryButtonStyle())
            }

            if editing {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Starts").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        DatePicker("Starts", selection: startBinding, displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    }
                    GridRow {
                        Text(event.isAllDay ? "Last day" : "Ends").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        DatePicker("Ends", selection: endBinding, in: event.start..., displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
                    }
                }
                .labelsHidden().datePickerStyle(.field)
            }

            zoneRow

            HStack(spacing: 14) {
                repeatMenu
                if calendars.count > 1 { calendarMenu }
                Spacer(minLength: 0)
            }

            if !event.location.isEmpty {
                Label(event.location, systemImage: "mappin.and.ellipse").font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
            }

            ForEach(event.info, id: \.self) { note in
                Label(note, systemImage: "globe").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }

            if !event.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(event.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(Theme.unread)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.unread.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            if !conflicts.isEmpty { conflictBox }

            HStack {
                if let alarm = Self.alarmTime(for: event) {
                    Toggle(isOn: withAlarm) {
                        Text((event.isAllDay ? "Alarm at 9:00 that day" : "Alarm \(Self.leadText(event)) before (\(alarm.formatted(date: .omitted, time: .shortened)))")
                             + (event.recurrence.isEmpty ? "" : ", first time"))
                    }
                    .toggleStyle(.checkbox).font(.system(size: 13))
                }
                Spacer()
                Button { onAdd(event.shouldSetAlarm) } label: {
                    Label(isDuplicate ? "Add anyway" : "Add to calendar", systemImage: "calendar.badge.plus").padding(.horizontal, 6)
                }
                .buttonStyle(PanelPrimaryButtonStyle(fill: isDuplicate ? Theme.secondary : Theme.accent)).fixedSize()
            }
        }
        .padding(14)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: isDuplicate ? 1.5 : 1))
    }

    private var isDuplicate: Bool { conflicts.contains { $0.kind == .duplicate } }

    /// Which time zone the big time is in, always spelled out. Converted times show the original;
    /// a zone that couldn't be confirmed is called out.
    @ViewBuilder
    private var zoneRow: some View {
        if !event.isAllDay {
            switch event.zoneStatus {
            case .local:
                Label("Your time · \(event.localZoneText)", systemImage: "clock")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            case .converted:
                VStack(alignment: .leading, spacing: 3) {
                    Label("Converted to your time (\(event.localZoneText))", systemImage: "globe")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Original: \(event.sourceTimeText ?? "")").font(.system(size: 13)).monospacedDigit()
                    if let note = event.zoneNote { Text(note).font(.system(size: 12)).opacity(0.8) }
                }
                .foregroundStyle(Theme.rule)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.rule.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            case .unclear:
                Label("Time zone not confirmed: shown as your time (\(event.localZoneText))", systemImage: "questionmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.unread)
            }
        }
    }

    private static let repeatChoices: [(String, String?)] = [
        ("Does not repeat", nil), ("Every day", "FREQ=DAILY"), ("Every weekday", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"),
        ("Every week", "FREQ=WEEKLY"), ("Every month", "FREQ=MONTHLY"), ("Every year", "FREQ=YEARLY"),
    ]

    /// What the AI set (e.g. "Every week on Tue, 8 times"), changeable in one click.
    private var repeatMenu: some View {
        Menu {
            ForEach(Self.repeatChoices, id: \.0) { choice in
                Button(choice.0) { event.recurrence = choice.1.flatMap(RepeatRule.normalize).map { [$0] } ?? [] }
            }
        } label: {
            Label(event.recurrence.first.map(RepeatRule.describe) ?? "Does not repeat", systemImage: "repeat")
                .font(.system(size: 13, weight: event.recurrence.isEmpty ? .regular : .semibold))
                .foregroundStyle(event.recurrence.isEmpty ? Theme.secondary : Theme.text)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var selectedCalendar: CalendarRecord? {
        calendars.first { $0.title == event.calendar } ?? calendars.first(where: \.isPrimary) ?? calendars.first
    }

    private var calendarMenu: some View {
        Menu {
            ForEach(calendars) { calendar in
                Button(calendar.title) { event.calendar = calendar.title }
            }
        } label: {
            Label(selectedCalendar?.title ?? "Calendar", systemImage: "calendar").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    static func leadText(_ event: ExtractedEvent) -> String {
        let minutes = event.alarmMinutesBefore ?? 10
        return minutes % 60 == 0 && minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min"
    }

    private var borderColor: Color {
        if isDuplicate { return Theme.no }
        return event.warnings.isEmpty && conflicts.isEmpty ? Theme.line : Theme.unread.opacity(0.6)
    }

    /// Red for "this is already in your calendar", orange for "something else is on at that time".
    private var conflictBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(conflicts, id: \.event.cacheID) { conflict in
                let other = conflict.event
                let title = other.title.isEmpty ? "Untitled event" : other.title
                let when = other.isAllDay ? other.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    : "\(other.start.formatted(date: .omitted, time: .shortened)) – \(other.end.formatted(date: .omitted, time: .shortened))"
                if conflict.kind == .duplicate {
                    Label("Already in your calendar: “\(title)”, \(when)", systemImage: "doc.on.doc.fill")
                        .foregroundStyle(Theme.no)
                } else {
                    Label("Overlaps “\(title)”, \(when)", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(Theme.unread)
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background((isDuplicate ? Theme.no : Theme.unread).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Moving the start keeps the length.
    private var startBinding: Binding<Date> {
        Binding(get: { event.start }, set: { date in
            event.moveStart(to: date)
        })
    }

    /// All-day ends are exclusive; the picker shows the last day.
    private var endBinding: Binding<Date> {
        Binding(get: { event.isAllDay ? event.end.addingTimeInterval(-1) : event.end }, set: { date in
            event.end = event.isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))! : date
        })
    }

    static func alarmTime(for event: ExtractedEvent, now: Date = .now) -> Date? {
        let time = event.isAllDay ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: event.start)!
            : event.start.addingTimeInterval(-TimeInterval((event.alarmMinutesBefore ?? 10) * 60))
        return time > now ? time : nil
    }

    /// "Thursday, 15 October" (plus the year when it isn't this year).
    static func dayLine(_ event: ExtractedEvent, now: Date = .now) -> String {
        let sameYear = Calendar.current.isDate(event.start, equalTo: now, toGranularity: .year)
        let style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        return sameYear ? event.start.formatted(style) : event.start.formatted(style.year())
    }

    /// "09:40 – 10:40", "All day", "Until Sun 25 Oct", or an end on another day.
    static func timeLine(_ event: ExtractedEvent) -> String {
        let calendar = Calendar.current
        let time = Date.FormatStyle().hour().minute()
        if event.isAllDay {
            let last = event.end.addingTimeInterval(-1)
            return calendar.isDate(event.start, inSameDayAs: last) ? "All day"
                : "All day, until \(last.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        }
        if calendar.isDate(event.start, inSameDayAs: event.end) || event.end == calendar.startOfDay(for: event.end) && event.end.timeIntervalSince(event.start) <= 86_400 {
            return "\(event.start.formatted(time)) – \(event.end.formatted(time))"
        }
        return "\(event.start.formatted(time)) – \(event.end.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    static func distanceText(_ event: ExtractedEvent, now: Date = .now) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: event.start)).day ?? 0
        let length = event.isAllDay ? "" : " · " + Duration.seconds(event.end.timeIntervalSince(event.start))
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        switch days {
        case ..<0: return "\(-days) day\(days == -1 ? "" : "s") ago"
        case 0: return (event.isAllDay ? "Today" : "Today, " + AlarmPanel.untilText(event.start, now: now)) + length
        case 1: return "Tomorrow" + length
        case 2...13: return "In \(days) days" + length
        default: return "In \(days / 7) weeks (\(days) days)" + length
        }
    }
}

/// A tear-off calendar page: month, day number, weekday.
struct DayBadge: View {
    let date: Date
    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 3).background(Theme.no)
            Text(date.formatted(.dateTime.day())).font(.system(size: 26, weight: .bold)).monospacedDigit()
                .padding(.top, 1)
            Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary).padding(.bottom, 4)
        }
        .frame(width: 60)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}
#endif
