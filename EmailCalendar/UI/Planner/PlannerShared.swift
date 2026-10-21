#if os(macOS)
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An email thread dragged inside the app. Declared in Info.plist so it never lands in other apps as text.
    static let emailThread = UTType(exportedAs: "ai.bald.EmailCalendar.thread")
}

/// What a mail row or thread title carries while it is dragged onto an event or to-do.
struct ThreadDragItem: Codable, Transferable {
    var threadID: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .emailThread)
    }
}

extension View {
    /// Lets the view be dragged onto an event or to-do to link the thread.
    func draggableThread(_ thread: MailThread) -> some View {
        draggable(ThreadDragItem(threadID: thread.id)) {
            Label(thread.subject, systemImage: "envelope")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Theme.accent, in: Capsule())
                .frame(maxWidth: 300)
        }
    }

    /// Accepts dragged threads; `isTargeted` drives the highlight.
    func threadDropTarget(isTargeted: Binding<Bool>, perform: @escaping ([String]) -> Void) -> some View {
        dropDestination(for: ThreadDragItem.self) { items, _ in
            let ids = items.map(\.threadID)
            guard !ids.isEmpty else { return false }
            perform(ids)
            return true
        } isTargeted: { isTargeted.wrappedValue = $0 }
    }
}

/// Short dates for drawers and chips: "Today", "Tomorrow", "Thu 16 Oct".
enum PlannerFormat {
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Today", "Tomorrow", then the weekday: for agenda headings.
    static func dayTitle(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func duration(_ event: CalendarEvent) -> String {
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func eventLabel(title: String, start: Date?, now: Date = .now) -> String {
        guard let start else { return title }
        return "\(day(start, now: now)) \(time(start)) · \(title)"
    }
}

/// Chips under a thread's subject: the events and to-dos it is linked to.
struct ThreadLinksBar: View {
    @Environment(AppStore.self) private var store
    let thread: MailThread

    var body: some View {
        let links = store.links(threadID: thread.id)
        if !links.isEmpty {
            WrapLayout(spacing: 6, lineSpacing: 6) {
                ForEach(links) { link in LinkChip(link: link) }
            }
            .frame(maxWidth: 640)
        }
    }
}

private struct LinkChip: View {
    @Environment(AppStore.self) private var store
    let link: MailLink
    @State private var hovering = false

    private var isEvent: Bool { if case .event = link.target { true } else { false } }

    var body: some View {
        let live = store.targetSummary(link.target)
        HStack(spacing: 0) {
            Button { store.reveal(link.target) } label: {
                HStack(spacing: 6) {
                    Image(systemName: isEvent ? "calendar" : "checklist").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                    Text(isEvent ? PlannerFormat.eventLabel(title: live?.title ?? link.targetTitle, start: live?.start ?? link.targetStart)
                                 : (live?.title ?? link.targetTitle))
                        .lineLimit(1)
                        .strikethrough(live == nil, color: Theme.secondary)
                }
                .padding(.leading, 11).padding(.trailing, 4).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(live == nil ? "This \(isEvent ? "event" : "to-do") is no longer here" : "Show in \(isEvent ? "Days" : "To-do")")
            Button { Task { await store.unlink(link) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary.opacity(hovering ? 1 : 0.6))
            .help("Remove link").accessibilityLabel("Remove link to \(link.targetTitle)")
            .padding(.trailing, 3)
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(live == nil ? Theme.secondary : Theme.text)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        .onHover { hovering = $0 }
    }
}

/// Lays children out in rows, wrapping when a row is full; rows are centred.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// A drawer's title row.
struct DrawerHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold))
            Spacer()
            trailing.font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 18).frame(height: 52)
    }
}
#endif
