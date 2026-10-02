#if os(macOS)
import SwiftUI

struct CalendarWeekGrid: View {
    let days: [Date]
    let events: [CalendarEvent]
    let calendars: [CalendarRecord]
    var compact = false
    var scrollToNow = UUID()
    var onEvent: (CalendarEvent) -> Void
    var onEmptySlot: (Date) -> Void

    private var hourHeight: CGFloat { compact ? 42 : 62 }
    private let gutter: CGFloat = 43

    private func color(for event: CalendarEvent) -> Color {
        CalendarGeometry.color(calendars.first { $0.id == event.calendarID }?.colorHex ?? "#6586B5")
    }

    private func textColor(for event: CalendarEvent) -> Color {
        CalendarGeometry.textColor(calendars.first { $0.id == event.calendarID }?.colorHex ?? "#6586B5")
    }

    var body: some View {
        GeometryReader { geometry in
            let dayWidth = max(20, (geometry.size.width - gutter) / CGFloat(days.count))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("All day").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: gutter)
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                Text(day.formatted(.dateTime.day())).fontWeight(Calendar.current.isDateInToday(day) ? .bold : .regular)
                            }
                            .font(.system(size: compact ? 10 : 12))
                            .foregroundStyle(Calendar.current.isDateInToday(day) ? Color.accentColor : Color.primary)
                            ForEach(events.filter { $0.isAllDay && CalendarGeometry.overlaps($0, day: day) }.prefix(compact ? 1 : 3), id: \.cacheID) { event in
                                Button { onEvent(event) } label: {
                                    Text(event.title.isEmpty ? "Untitled" : event.title)
                                        .font(.system(size: 10)).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 4).padding(.vertical, 2)
                                        .foregroundStyle(textColor(for: event))
                                        .background(color(for: event), in: RoundedRectangle(cornerRadius: 3))
                                }.buttonStyle(.plain)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 5).padding(.top, 5)
                        .frame(width: dayWidth, height: compact ? 47 : 76, alignment: .topLeading)
                        .background(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.07) : .clear)
                        .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5) }
                    }
                }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(hourLabel(hour)).font(.system(size: compact ? 9 : 10, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: gutter - 5, height: hourHeight, alignment: .topTrailing)
                                        .frame(width: gutter, alignment: .leading)
                                        .id("hour-\(hour)")
                                }
                            }
                            ForEach(days, id: \.self) { day in
                                dayColumn(day, width: dayWidth)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { centerNow(proxy) }
                    .onChange(of: scrollToNow) { centerNow(proxy) }
                }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func centerNow(_ proxy: ScrollViewProxy) {
        let hour = Calendar.current.component(.hour, from: .now)
        proxy.scrollTo("hour-\(max(0, hour - (compact ? 2 : 3)))", anchor: .top)
    }

    private func dayColumn(_ day: Date, width: CGFloat) -> some View {
        let placements = CalendarGeometry.placements(events, day: day)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Calendar.current.isDateInToday(day) ? Color.accentColor.opacity(0.05) : Color.clear)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    onEmptySlot(CalendarGeometry.date(at: Double(value.location.y / hourHeight * 60), on: day))
                })
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
                        .frame(height: hourHeight, alignment: .top)
                }
            }.allowsHitTesting(false)
            ForEach(placements) { placement in
                let chipWidth = max(12, (width - 4) / CGFloat(placement.lanes) - 2)
                Button { onEvent(placement.event) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(placement.event.title.isEmpty ? "Untitled" : placement.event.title)
                            .font(.system(size: compact ? 10 : 11, weight: .medium)).lineLimit(compact ? 1 : 2)
                        if !compact && placement.end - placement.start >= 30 {
                            Text(placement.event.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .frame(width: chipWidth, height: max(17, CGFloat(placement.end - placement.start) / 60 * hourHeight - 2), alignment: .topLeading)
                    .foregroundStyle(textColor(for: placement.event))
                    .background(color(for: placement.event), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(color(for: placement.event)).frame(width: 3)
                    }
                    .clipped()
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(placement.lane) * (chipWidth + 2) + 2, y: CGFloat(placement.start) / 60 * hourHeight)
                .accessibilityLabel("\(placement.event.title), \(placement.event.start.formatted(date: .abbreviated, time: .shortened))")
            }
            if Calendar.current.isDateInToday(day) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Rectangle().fill(Color.red.opacity(0.8)).frame(height: 1)
                        .offset(y: CGFloat(CalendarGeometry.minutes(context.date, on: day)) / 60 * hourHeight)
                }.allowsHitTesting(false)
            }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5).frame(maxWidth: .infinity, alignment: .trailing).allowsHitTesting(false)
        }
        .frame(width: width, height: 24 * hourHeight)
        .opacity(day < Calendar.current.startOfDay(for: .now) ? 0.65 : 1)
    }
}
#endif
