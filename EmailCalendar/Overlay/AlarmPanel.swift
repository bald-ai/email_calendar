#if os(macOS)
import SwiftUI

/// The ⏰ panel floating over the overlay: one tap for the common delays, or one big field that
/// understands "14:30", "7pm", "1h30" and "45m", with the exact ring time shown before you commit.
struct AlarmPanel: View {
    let alarms: AlarmCenter
    let onClose: () -> Void

    @State private var input = ""
    @State private var label = ""
    @FocusState private var focus: Field?
    enum Field { case time, label }

    static let presets: [(minutes: Int, value: String, unit: String)] =
        [(5, "5", "min"), (10, "10", "min"), (15, "15", "min"), (30, "30", "min"), (60, "1", "hour")]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let target = AlarmTime.parse(input, now: context.date)
            VStack(alignment: .leading, spacing: 16) {
                PanelHeader(icon: "alarm.fill", tint: Theme.unread, title: "Alarm", onClose: onClose)

                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.minutes) { preset in
                        Button { set(Date.now.addingTimeInterval(TimeInterval(preset.minutes * 60))) } label: {
                            VStack(spacing: 0) {
                                Text(preset.value).font(.system(size: 22, weight: .bold)).monospacedDigit()
                                Text(preset.unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .help("Ring in \(preset.value) \(preset.unit)")
                    }
                }

                // Temporary, for trying the full-screen alarm without waiting.
                Button { alarms.add(at: Date.now.addingTimeInterval(5), label: label.isEmpty ? "Test alarm" : label); onClose() } label: {
                    Label("Test: ring in 5 seconds", systemImage: "testtube.2").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Or type a time")
                    TextField("", text: $input, prompt: Text("e.g. 14:30, 7pm, 1h30").font(.system(size: 18, weight: .regular)))
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .panelField(focused: focus == .time, tint: Theme.unread)
                        .focused($focus, equals: .time)
                        .onSubmit { submit() }
                    preview(target, now: context.date)
                }

                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Label")
                    TextField("What's it for? (optional)", text: $label)
                        .font(.system(size: 15))
                        .panelField(focused: focus == .label, tint: Theme.unread)
                        .focused($focus, equals: .label)
                        .onSubmit { submit() }
                }

                Button { submit() } label: {
                    Label(target.map { "Set alarm for \($0.formatted(date: .omitted, time: .shortened))" } ?? "Set alarm",
                          systemImage: "alarm.fill")
                }
                .buttonStyle(PanelPrimaryButtonStyle(fill: Theme.unread))
                .disabled(target == nil)

                if !alarms.alarms.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Upcoming")
                        ForEach(alarms.alarms) { alarm in
                            HStack(spacing: 12) {
                                Text(alarm.fireAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(alarm.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(Self.untilText(alarm.fireAt, now: context.date)).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Button { alarms.cancel(alarm.id) } label: {
                                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                        .frame(width: 28, height: 28).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help("Cancel this alarm")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .panelCard()
        .onAppear { focus = .time }
    }

    @ViewBuilder
    private func preview(_ target: Date?, now: Date) -> some View {
        if let target {
            Label {
                Text("Rings \(Self.dayText(target, now: now)) at ").foregroundStyle(Theme.secondary)
                    + Text(target.formatted(date: .omitted, time: .shortened)).bold()
                    + Text(" · \(Self.untilText(target, now: now))").foregroundStyle(Theme.secondary)
            } icon: {
                Image(systemName: "bell.fill").foregroundStyle(Theme.unread)
            }
            .font(.system(size: 13))
        } else if !input.trimmingCharacters(in: .whitespaces).isEmpty {
            Label("Not sure what time that is. Try 14:30, 7pm, 1h30 or 45m.", systemImage: "questionmark.circle.fill")
                .font(.system(size: 13)).foregroundStyle(Theme.unread)
        } else {
            Text("Return sets it. Clock times ring the next time they come around.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }

    private func submit() {
        guard let target = AlarmTime.parse(input, now: .now) else { focus = .time; return }
        set(target)
    }

    private func set(_ date: Date) {
        alarms.add(at: date, label: label)
        input = ""; label = ""
        onClose()
    }

    static func dayText(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    static func untilText(_ date: Date, now: Date = .now) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - Shared panel pieces

/// A floating card over the calendar.
struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }

    /// A clearly bordered input, so it's obvious where to type.
    func panelField(focused: Bool, tint: Color) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? tint : Theme.line, lineWidth: focused ? 2 : 1))
    }
}

struct PanelHeader: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 17, weight: .bold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondary)
                    .frame(width: 26, height: 26).background(Theme.raised, in: Circle())
            }
            .buttonStyle(.plain).help("Close (Esc)")
        }
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.secondary)
    }
}

/// A full-width call to action.
struct PanelPrimaryButtonStyle: ButtonStyle {
    var fill: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(fill.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// A quieter companion to the primary button.
struct PanelSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16).frame(minHeight: 42)
            .background(Theme.raised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}
#endif
