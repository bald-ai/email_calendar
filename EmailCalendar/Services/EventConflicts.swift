import Foundation

/// Finds events already in the calendar that a new event would duplicate or overlap.
public enum EventConflicts {
    public struct Conflict: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case duplicate, overlap }
        public var kind: Kind
        public var event: CalendarEvent
    }

    /// Duplicates first, then overlaps by start time. Timed events only clash with timed events;
    /// an all-day event only flags an all-day event that looks like the same thing.
    public static func find(title: String, start: Date, end: Date, isAllDay: Bool, in events: [CalendarEvent]) -> [Conflict] {
        let words = keywords(title)
        var conflicts: [Conflict] = []
        for event in events where !event.isCancelled && event.isAllDay == isAllDay
            && !event.attendees.contains(where: { $0.isSelf && $0.response == .declined }) {
            guard event.start < end && start < event.end else { continue }
            let similar = isSimilar(words, keywords(event.title))
            let sameTime = abs(event.start.timeIntervalSince(start)) <= 15 * 60
            if similar && (isAllDay || sameTime) {
                conflicts.append(Conflict(kind: .duplicate, event: event))
            } else if !isAllDay {
                conflicts.append(Conflict(kind: .overlap, event: event))
            }
        }
        return conflicts.sorted { ($0.kind == .duplicate ? 0 : 1, $0.event.start) < ($1.kind == .duplicate ? 0 : 1, $1.event.start) }
    }

    /// Lowercased words of three letters or more, without accents ("Zubař" matches "zubar").
    static func keywords(_ title: String) -> Set<String> {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Set(folded.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    /// Same words, or one title's words all found in the other ("Dentist" vs "Dentist – Dr. Novák").
    static func isSimilar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty }
        let shared = a.intersection(b).count
        return shared == min(a.count, b.count) || Double(shared) / Double(max(a.count, b.count)) >= 0.5
    }
}
