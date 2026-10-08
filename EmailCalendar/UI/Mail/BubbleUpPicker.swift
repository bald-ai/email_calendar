#if os(macOS)
import SwiftUI

struct BubbleUpPicker: View {
    @Environment(\.dismiss) private var dismiss
    var pick: (Date) -> Void
    @State private var custom = Date.now.addingTimeInterval(86_400)
    @State private var showsCustom = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bubbles.and.sparkles.fill").foregroundStyle(Theme.unread)
                Text("Bubble this up…").font(.system(size: 17, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(QuietButtonStyle())
                    .foregroundStyle(Theme.secondary).keyboardShortcut(.cancelAction)
            }.padding(.bottom, 4)
            Text("It leaves your Imbox and comes back to the top when it’s time.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).padding(.bottom, 8)
            ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                Button { pick(preset.1); dismiss() } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
                            .frame(width: 20, height: 20).background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
                        Text(preset.0).font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(Self.friendly(preset.1)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(PickerRowStyle())
            }
            Button { showsCustom.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar").frame(width: 20)
                    Text("Pick a date…").font(.system(size: 14, weight: .medium))
                    Spacer()
                }.padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(PickerRowStyle())
            if showsCustom {
                HStack {
                    DatePicker("Return", selection: $custom, in: Date.now..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    Spacer()
                    Button("Bubble Up") { pick(custom); dismiss() }.buttonStyle(PillButtonStyle(fill: Theme.accent))
                }.padding(.horizontal, 8).padding(.top, 4)
            }
        }
        .padding(20).frame(width: 360)
        .background(Theme.card)
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard let index = Int(press.characters), presets.indices.contains(index - 1) else { return .ignored }
            pick(presets[index - 1].1); dismiss(); return .handled
        }
    }

    /// "Today 6:00 PM", "Tomorrow 9:00 AM", "Sat 9:00 AM", "Mon, Oct 12".
    static func friendly(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: date).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var presets: [(String, Date)] {
        let calendar = Calendar.current
        let now = Date.now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)!
        let later = max(now.addingTimeInterval(1), min(max(evening, now.addingTimeInterval(3_600)), tomorrow.addingTimeInterval(-1)))
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        let weekend = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 7), matchingPolicy: .nextTime)!
        var nextMonday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
        if calendar.isDate(nextMonday, inSameDayAs: now) { nextMonday = calendar.date(byAdding: .day, value: 7, to: nextMonday)! }
        return [("Later today", later), ("Tomorrow morning", morning), ("This weekend", weekend), ("Next week", nextMonday)]
    }
}
private struct PickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        var configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(hovering || configuration.isPressed ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}
#endif
