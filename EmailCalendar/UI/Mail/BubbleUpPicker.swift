#if os(macOS)
import SwiftUI

struct BubbleUpPicker: View {
    @Environment(\.dismiss) private var dismiss
    var pick: (Date) -> Void
    @State private var custom = Date.now.addingTimeInterval(86_400)
    @State private var showsCustom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring this back…").font(.headline)
            ForEach(presets, id: \.0) { name, date in
                Button {
                    pick(date); dismiss()
                } label: {
                    HStack {
                        Text(name)
                        Spacer()
                        Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).font(.caption)
                    }.frame(maxWidth: .infinity).padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
            Button("Pick a date…") { showsCustom.toggle() }.buttonStyle(.borderless)
            if showsCustom {
                DatePicker("Return", selection: $custom, in: Date.now..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                Button("Bubble Up") { pick(custom); dismiss() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.padding(18).frame(width: 330)
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
#endif
