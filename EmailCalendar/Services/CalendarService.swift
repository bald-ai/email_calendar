import Foundation

/// The remote write succeeded. Retrying creation would make a duplicate event.
struct CalendarWriteCommittedError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// The overlay and main calendar read this cache without waiting for Google.
/// Raw date-only values stay in SQLite so all-day dates survive a system time-zone change.
actor CalendarService {
    enum CalendarError: LocalizedError, Sendable {
        case invalidDates, missingTitle, missingEvent, readOnlyCalendar, invalidGoogleDate(String)
        var errorDescription: String? {
            switch self {
            case .invalidDates: "An event must end after it starts."
            case .missingTitle: "Give the event a title."
            case .missingEvent: "This event is no longer in the calendar cache. Refresh and try again."
            case .readOnlyCalendar: "You cannot edit events in this calendar."
            case .invalidGoogleDate(let id): "Google returned an invalid date for event \(id)."
            }
        }
    }

    private struct SyncState: Codable, Sendable {
        var token: String
        var interval: DateInterval
        var fetchedAt: Date
    }

    private struct PendingSync: Sendable {
        var id: UUID
        var task: Task<Void, Error>
    }

    private let api: GoogleAPI
    private let store: LocalStore
    private let calendarCollection = "calendar.sources"
    private var syncTasks: [String: PendingSync] = [:]
    private var operationTails: [String: Task<Void, Never>] = [:]
    private var operationCancellers: [UUID: @Sendable () -> Void] = [:]
    private var isDraining = false

    init(api: GoogleAPI, store: LocalStore) {
        self.api = api
        self.store = store
    }

    func cachedCalendars(accountID: String) async throws -> [CalendarRecord] {
        var calendars = try await store.all(CalendarRecord.self, collection: calendarCollection, accountID: accountID)
        for index in calendars.indices {
            if let visible = try await store.metadata(Bool.self, key: visibilityKey(calendars[index].id), accountID: accountID) {
                calendars[index].isVisible = visible
            }
        }
        return calendars.sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func cachedEvents(accountID: String, visibleOnly: Bool = true) async throws -> [CalendarEvent] {
        let calendars = try await cachedCalendars(accountID: accountID)
        var result: [CalendarEvent] = []
        for calendar in calendars where !visibleOnly || calendar.isVisible {
            let raw = try await store.all(GoogleEvent.self, collection: eventsCollection(calendar.id), accountID: accountID)
            result += try raw.filter { $0.status != "cancelled" }.map {
                try Self.event(from: $0, calendarID: calendar.id, accountID: accountID)
            }
        }
        return result.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    func setVisibility(calendarID: String, accountID: String, isVisible: Bool) async throws {
        guard var calendar = try await store.load(CalendarRecord.self, id: calendarID,
                                                  collection: calendarCollection, accountID: accountID) else { return }
        calendar.isVisible = isVisible
        // Separate metadata also preserves the choice if a calendar disappears and is re-added.
        try await store.setMetadata(isVisible, key: visibilityKey(calendarID), accountID: accountID)
        try await store.save(calendar, id: calendar.id, collection: calendarCollection, accountID: accountID)
    }

    /// Concurrent refresh requests join the same work. Writes and sync run in account order.
    func sync(accountID: String) async throws {
        guard !isDraining else { throw CancellationError() }
        if let existing = syncTasks[accountID] { return try await existing.task.value }
        let id = UUID()
        let task = Task {
            try await self.serialized(accountID: accountID) {
                try await self.synchronize(accountID: accountID)
            }
        }
        syncTasks[accountID] = PendingSync(id: id, task: task)
        defer {
            if syncTasks[accountID]?.id == id { syncTasks.removeValue(forKey: accountID) }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    /// Drain before switching OAuth accounts, so an old cache request cannot use a new account's token.
    func cancelAllOperations() async {
        isDraining = true
        defer { isDraining = false }
        let syncs = Array(syncTasks.values)
        let cancellers = Array(operationCancellers.values)
        let tails = Array(operationTails.values)
        for pending in syncs { pending.task.cancel() }
        for cancel in cancellers { cancel() }
        for tail in tails { await tail.value }
        for pending in syncs { _ = try? await pending.task.value }
        operationTails.removeAll()
        operationCancellers.removeAll()
        syncTasks.removeAll()
    }

    /// Navigation beyond the normal cache horizon can fetch an explicit date range.
    func ensureEvents(accountID: String, interval: DateInterval) async throws {
        try await serialized(accountID: accountID) {
            let calendars = try await self.cachedCalendars(accountID: accountID)
            for calendar in calendars where calendar.isVisible {
                let coverage = try await self.coverage(calendarID: calendar.id, accountID: accountID)
                if coverage.contains(where: { $0.start <= interval.start && $0.end >= interval.end }) { continue }
                try await self.refreshRange(calendarID: calendar.id, accountID: accountID, interval: interval)
                try await self.store.setMetadata(Self.mergedIntervals(coverage + [interval]), key: self.coverageKey(calendar.id), accountID: accountID)
            }
        }
    }

    @discardableResult
    func create(_ event: CalendarEvent) async throws -> CalendarEvent {
        try await serialized(accountID: event.accountID) {
            try await self.requireWritable(calendarID: event.calendarID, accountID: event.accountID)
            try Self.validate(event)
            let raw = try await self.api.insertEvent(calendarID: event.calendarID, event: Self.googleEvent(from: event))
            do {
                if raw.recurrence?.isEmpty == false {
                    try await self.refreshKnownRanges(calendarID: event.calendarID, accountID: event.accountID)
                } else {
                    try await self.save(raw, calendarID: event.calendarID, accountID: event.accountID)
                }
                return try Self.event(from: raw, calendarID: event.calendarID, accountID: event.accountID)
            } catch {
                throw Self.committedWarning("created", error: error)
            }
        }
    }

    @discardableResult
    func update(_ event: CalendarEvent, originalCalendarID: String? = nil,
                scope: EventEditScope = .thisEvent) async throws -> CalendarEvent {
        try await serialized(accountID: event.accountID) {
            try Self.validate(event)
            let sourceCalendarID = originalCalendarID ?? event.calendarID
            try await self.requireWritable(calendarID: sourceCalendarID, accountID: event.accountID)
            try await self.requireWritable(calendarID: event.calendarID, accountID: event.accountID)
            let oldRaw = try await self.store.load(GoogleEvent.self, id: event.id,
                                                   collection: self.eventsCollection(sourceCalendarID), accountID: event.accountID)
            var edited = event
            var original = oldRaw
            var mutationETag = event.etag ?? oldRaw?.etag
            if scope == .allEvents, let seriesID = event.recurringEventID {
                guard let oldRaw else { throw CalendarError.missingEvent }
                let master = try await self.api.event(calendarID: sourceCalendarID, id: seriesID)
                let old = try Self.event(from: oldRaw, calendarID: sourceCalendarID, accountID: event.accountID)
                let masterEvent = try Self.event(from: master, calendarID: sourceCalendarID, accountID: event.accountID)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = master.start?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
                let shift = calendar.dateComponents([.day, .hour, .minute, .second], from: old.start, to: event.start)
                edited.id = seriesID
                edited.start = calendar.date(byAdding: shift, to: masterEvent.start) ?? masterEvent.start
                let duration = calendar.dateComponents([.day, .hour, .minute, .second], from: event.start, to: event.end)
                edited.end = calendar.date(byAdding: duration, to: edited.start) ?? edited.start.addingTimeInterval(event.end.timeIntervalSince(event.start))
                edited.recurrence = event.recurrence.isEmpty ? master.recurrence ?? [] : event.recurrence
                edited.recurringEventID = nil
                edited.originalStart = nil
                original = master
                mutationETag = master.etag
            } else if event.recurringEventID != nil {
                edited.recurrence = []
            }
            let isMoving = sourceCalendarID != event.calendarID
            if isMoving {
                let moved = try await self.api.moveEvent(calendarID: sourceCalendarID, eventID: edited.id,
                                                        destinationCalendarID: event.calendarID)
                edited.id = moved.id
                original = moved
                mutationETag = moved.etag
                do {
                    try await self.removeCached(id: event.id, seriesID: scope == .allEvents ? event.recurringEventID : nil,
                                                calendarID: sourceCalendarID, accountID: event.accountID)
                    if moved.recurrence?.isEmpty == false {
                        try await self.refreshKnownRanges(calendarID: event.calendarID, accountID: event.accountID)
                    } else {
                        try await self.save(moved, calendarID: event.calendarID, accountID: event.accountID)
                    }
                } catch {
                    throw Self.moveWarning(error: error)
                }
            }
            var payload = Self.googleEvent(from: edited, timeZone: original?.start?.timeZone)
            payload.id = edited.id
            payload.etag = mutationETag
            let raw: GoogleEvent
            do {
                raw = try await self.api.updateEvent(calendarID: event.calendarID, event: payload)
            } catch {
                if isMoving { throw Self.moveWarning(error: error) }
                throw error
            }
            do {
                if raw.recurrence?.isEmpty == false {
                    // Google returns the master; fetch expanded instances before publishing the change.
                    try await self.refreshKnownRanges(calendarID: event.calendarID, accountID: event.accountID)
                    if let updated = try await self.cachedEvents(accountID: event.accountID, visibleOnly: false).first(where: {
                        $0.calendarID == event.calendarID && $0.id == event.id
                    }) { return updated }
                } else {
                    try await self.save(raw, calendarID: event.calendarID, accountID: event.accountID)
                }
                return try Self.event(from: raw, calendarID: event.calendarID, accountID: event.accountID)
            } catch {
                throw Self.committedWarning("updated", error: error)
            }
        }
    }

    func delete(_ event: CalendarEvent, scope: EventEditScope = .thisEvent) async throws {
        try await serialized(accountID: event.accountID) {
            try await self.requireWritable(calendarID: event.calendarID, accountID: event.accountID)
            let id = scope == .allEvents ? event.recurringEventID ?? event.id : event.id
            try await self.api.deleteEvent(calendarID: event.calendarID, eventID: id)
            do {
                try await self.removeCached(id: id, seriesID: scope == .allEvents ? id : nil,
                                            calendarID: event.calendarID, accountID: event.accountID)
            } catch { throw Self.committedWarning("deleted", error: error) }
        }
    }

    @discardableResult
    func respond(to event: CalendarEvent, status: AttendanceStatus) async throws -> CalendarEvent {
        try await serialized(accountID: event.accountID) {
            let email = event.attendees.first(where: \.isSelf)?.email ?? event.accountID
            let raw = try await self.api.respondToInvitation(calendarID: event.calendarID, eventID: event.id,
                                                            email: email, responseStatus: status.rawValue)
            do {
                try await self.save(raw, calendarID: event.calendarID, accountID: event.accountID)
                return try Self.event(from: raw, calendarID: event.calendarID, accountID: event.accountID)
            } catch { throw Self.committedWarning("responded to", error: error) }
        }
    }

    private func serialized<T: Sendable>(accountID: String, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !isDraining else { throw CancellationError() }
        let previous = operationTails[accountID]
        let id = UUID()
        let task = Task {
            if let previous { await previous.value }
            try Task.checkCancellation()
            return try await operation()
        }
        operationCancellers[id] = { task.cancel() }
        defer { operationCancellers.removeValue(forKey: id) }
        operationTails[accountID] = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func synchronize(accountID: String) async throws {
        var sources: [GoogleCalendar] = []
        var pageToken: String?
        repeat {
            let page = try await api.calendarList(pageToken: pageToken)
            sources += page.items.filter { $0.deleted != true }
            pageToken = page.nextPageToken
        } while pageToken != nil
        var calendars: [CalendarRecord] = []
        for source in sources {
            let visible = try await store.metadata(Bool.self, key: visibilityKey(source.id), accountID: accountID)
            calendars.append(CalendarRecord(id: source.id, accountID: accountID,
                title: source.summaryOverride ?? source.summary ?? source.id,
                colorHex: source.backgroundColor ?? "#6586B5", isVisible: visible ?? source.selected ?? true,
                isPrimary: source.primary ?? false, accessRole: source.accessRole ?? "reader"))
        }
        try await store.save(calendars.map { LocalStore.Record(id: $0.id, value: $0) },
                             collection: calendarCollection, accountID: accountID, replacing: true)
        for calendar in calendars where calendar.accessRole != "freeBusyReader" {
            try Task.checkCancellation()
            let previous = try await store.metadata(SyncState.self, key: syncKey(calendar.id), accountID: accountID)
            let now = Date.now
            // Rebuild monthly so the finite expansion horizon advances with the current date.
            let fresh = previous.map { now.timeIntervalSince($0.fetchedAt) < 30 * 86_400 } ?? false
            do {
                try await synchronizeEvents(calendarID: calendar.id, accountID: accountID, state: fresh ? previous : nil)
            } catch let error as GoogleAPIError where error.statusCode == 410 {
                // An expired token needs a full replacement, while the old cache remains usable offline.
                try await store.removeMetadata(key: syncKey(calendar.id), accountID: accountID)
                try await synchronizeEvents(calendarID: calendar.id, accountID: accountID, state: nil)
            }
        }
    }

    private func synchronizeEvents(calendarID: String, accountID: String, state: SyncState?) async throws {
        let interval = state?.interval ?? Self.defaultInterval()
        let fetched = try await fetch(calendarID: calendarID, syncToken: state?.token, interval: interval)
        var items = fetched.items
        var ranges = [interval]
        if state == nil {
            // A reset refreshes supplemental navigation ranges too, keeping an open old week intact.
            let previous = try await coverage(calendarID: calendarID, accountID: accountID)
            for range in previous where range.start < interval.start || range.end > interval.end {
                let supplementary = try await fetch(calendarID: calendarID, interval: range)
                items += supplementary.items
                ranges.append(range)
            }
        }
        try await apply(items, calendarID: calendarID, accountID: accountID, replacing: state == nil)
        if state == nil {
            try await store.setMetadata(Self.mergedIntervals(ranges), key: coverageKey(calendarID), accountID: accountID)
        }
        if let token = fetched.nextSyncToken {
            try await store.setMetadata(SyncState(token: token, interval: interval, fetchedAt: state?.fetchedAt ?? .now),
                                        key: syncKey(calendarID), accountID: accountID)
        }
    }

    private func fetch(calendarID: String, syncToken: String? = nil, interval: DateInterval) async throws -> GooglePage<GoogleEvent> {
        var items: [GoogleEvent] = []
        var pageToken: String?
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await api.events(calendarID: calendarID, syncToken: syncToken, pageToken: pageToken,
                                           timeMin: interval.start, timeMax: interval.end, singleEvents: true, showDeleted: true)
            items += page.items
            pageToken = page.nextPageToken
            if pageToken == nil { token = page.nextSyncToken }
        } while pageToken != nil
        return GooglePage(items: items, nextSyncToken: token)
    }

    private func apply(_ changes: [GoogleEvent], calendarID: String, accountID: String, replacing: Bool = false) async throws {
        let existing: [GoogleEvent] = replacing ? [] : try await store.all(GoogleEvent.self, collection: eventsCollection(calendarID), accountID: accountID)
        var rows = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for raw in changes {
            if raw.status == "cancelled" {
                rows.removeValue(forKey: raw.id)
                rows = rows.filter { $0.value.recurringEventId != raw.id }
            } else {
                // Validate before replacing the last known good cache.
                _ = try Self.event(from: raw, calendarID: calendarID, accountID: accountID)
                rows[raw.id] = raw
            }
        }
        try await store.save(rows.values.map { LocalStore.Record(id: $0.id, value: $0, sortDate: Self.date($0.start)) },
                             collection: eventsCollection(calendarID), accountID: accountID, replacing: true)
    }

    private func save(_ event: GoogleEvent, calendarID: String, accountID: String) async throws {
        try await store.save(event, id: event.id, collection: eventsCollection(calendarID), accountID: accountID,
                             sortDate: Self.date(event.start))
    }

    private func removeCached(id: String, seriesID: String?, calendarID: String, accountID: String) async throws {
        let rows = try await store.all(GoogleEvent.self, collection: eventsCollection(calendarID), accountID: accountID)
        let remaining = rows.filter { $0.id != id && (seriesID == nil || $0.recurringEventId != seriesID) }
        try await store.save(remaining.map { LocalStore.Record(id: $0.id, value: $0, sortDate: Self.date($0.start)) },
                             collection: eventsCollection(calendarID), accountID: accountID, replacing: true)
    }

    private func refreshRange(calendarID: String, accountID: String, interval: DateInterval) async throws {
        let fetched = try await fetch(calendarID: calendarID, interval: interval)
        // A range refresh also removes instances moved out of the range or cancelled in a series edit.
        let existing = try await store.all(GoogleEvent.self, collection: eventsCollection(calendarID), accountID: accountID)
        let outside = existing.filter { raw in
            guard let start = Self.date(raw.start), let end = Self.date(raw.end) else { return false }
            return end <= interval.start || start >= interval.end
        }
        var rows = Dictionary(outside.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for raw in fetched.items where raw.status != "cancelled" {
            _ = try Self.event(from: raw, calendarID: calendarID, accountID: accountID)
            rows[raw.id] = raw
        }
        try await store.save(rows.values.map { LocalStore.Record(id: $0.id, value: $0, sortDate: Self.date($0.start)) },
                             collection: eventsCollection(calendarID), accountID: accountID, replacing: true)
    }

    private func refreshKnownRanges(calendarID: String, accountID: String) async throws {
        let ranges = try await coverage(calendarID: calendarID, accountID: accountID)
        for interval in ranges.isEmpty ? [Self.defaultInterval()] : ranges {
            try await refreshRange(calendarID: calendarID, accountID: accountID, interval: interval)
        }
    }

    private func coverage(calendarID: String, accountID: String) async throws -> [DateInterval] {
        try await store.metadata([DateInterval].self, key: coverageKey(calendarID), accountID: accountID) ?? []
    }

    private func requireWritable(calendarID: String, accountID: String) async throws {
        guard let calendar = try await store.load(CalendarRecord.self, id: calendarID, collection: calendarCollection,
                                                  accountID: accountID), calendar.canEdit else { throw CalendarError.readOnlyCalendar }
    }

    private func eventsCollection(_ id: String) -> String { "calendar.events.\(id)" }
    private func syncKey(_ id: String) -> String { "calendar.sync.\(id)" }
    private func coverageKey(_ id: String) -> String { "calendar.coverage.\(id)" }
    private func visibilityKey(_ id: String) -> String { "calendar.visible.\(id)" }

    private static func defaultInterval() -> DateInterval {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return DateInterval(start: calendar.date(byAdding: .year, value: -1, to: today)!,
                            end: calendar.date(byAdding: .year, value: 2, to: today)!)
    }

    private static func mergedIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { merged.append(interval) }
        }
        return merged
    }

    private static func validate(_ event: CalendarEvent) throws {
        guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CalendarError.missingTitle }
        guard event.end > event.start else { throw CalendarError.invalidDates }
        if event.isAllDay, Calendar.current.startOfDay(for: event.end) <= Calendar.current.startOfDay(for: event.start) {
            throw CalendarError.invalidDates
        }
    }

    private static func committedWarning(_ action: String, error: any Error) -> CalendarWriteCommittedError {
        CalendarWriteCommittedError(message: "The event was \(action) in Google Calendar, but the local calendar could not refresh. \(error.localizedDescription) Refresh again when you are online.")
    }

    private static func moveWarning(error: any Error) -> CalendarWriteCommittedError {
        CalendarWriteCommittedError(message: "The event moved to the selected calendar, but saving the remaining changes failed. \(error.localizedDescription) Refresh the calendar before retrying those changes.")
    }

    static func event(from raw: GoogleEvent, calendarID: String, accountID: String) throws -> CalendarEvent {
        guard let start = date(raw.start), let end = date(raw.end), end > start else {
            throw CalendarError.invalidGoogleDate(raw.id)
        }
        let attendees = (raw.attendees ?? []).compactMap { value -> EventAttendee? in
            guard let email = value.email else { return nil }
            return EventAttendee(email: email, name: value.displayName,
                response: AttendanceStatus(rawValue: value.responseStatus ?? "needsAction") ?? .needsAction,
                isSelf: value.isSelf ?? false, isOrganizer: value.organizer ?? false)
        }
        return CalendarEvent(id: raw.id, calendarID: calendarID, accountID: accountID, title: raw.summary ?? "(Untitled)",
            start: start, end: end, isAllDay: raw.start?.date != nil, location: raw.location ?? "", notes: raw.description ?? "",
            recurrence: raw.recurrence ?? [], recurringEventID: raw.recurringEventId, originalStart: date(raw.originalStartTime),
            videoURL: videoURL(raw), htmlLink: raw.htmlLink.flatMap(URL.init(string:)), attendees: attendees,
            status: raw.status ?? "confirmed", etag: raw.etag)
    }

    private static func googleEvent(from event: CalendarEvent, timeZone: String? = nil) -> GoogleEvent {
        let zone = timeZone ?? TimeZone.current.identifier
        func value(_ date: Date) -> GoogleEventDateTime {
            if event.isAllDay {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = .current
                formatter.dateFormat = "yyyy-MM-dd"
                return GoogleEventDateTime(date: formatter.string(from: date))
            }
            return GoogleEventDateTime(dateTime: ISO8601DateFormatter().string(from: date), timeZone: zone)
        }
        return GoogleEvent(id: event.id, summary: event.title, start: value(event.start), end: value(event.end),
            description: event.notes, location: event.location, recurrence: event.recurrence.isEmpty ? nil : event.recurrence,
            attendees: event.attendees.isEmpty ? nil : event.attendees.map { attendee in
                var value = GoogleAttendee(email: attendee.email, responseStatus: attendee.response.rawValue)
                value.displayName = attendee.name
                return value
            })
    }

    static func date(_ value: GoogleEventDateTime?) -> Date? {
        guard let value else { return nil }
        if let date = value.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let result = formatter.date(from: date), formatter.string(from: result) == date else { return nil }
            return result
        }
        guard let text = value.dateTime else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = value.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func videoURL(_ raw: GoogleEvent) -> URL? {
        let conference = raw.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
        if let link = raw.hangoutLink ?? conference, let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") { return url }
        let text = [raw.location, raw.description].compactMap { $0 }.joined(separator: " ")
        guard let pattern = try? NSRegularExpression(pattern: "https?://(?:[a-zA-Z0-9-]+\\.)?(?:zoom\\.us|meet\\.google\\.com)/[^\\s<>\"']+", options: .caseInsensitive),
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }
}
