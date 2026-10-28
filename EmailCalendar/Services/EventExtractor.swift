import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Model settings for turning text or screenshots into events. Mirrors the Friction backend's
/// OpenAI Responses setup (GPT-6.1 Sol), here at normal speed and medium reasoning. Models named
/// `claude-…` go to the Anthropic Messages API instead.
public struct EventExtractorSettings: Sendable, Equatable {
    public var model: String
    /// Reasoning effort (OpenAI) or `output_config.effort` (Claude).
    public var reasoning: String
    /// "default" is normal speed; "fast" costs twice as much. OpenAI only.
    public var serviceTier: String
    public var maxOutputTokens: Int

    public init(model: String = "gpt-6.1-sol", reasoning: String = "medium", serviceTier: String = "default",
                maxOutputTokens: Int? = nil) {
        self.model = model; self.reasoning = reasoning; self.serviceTier = serviceTier
        self.maxOutputTokens = maxOutputTokens ?? ["none": 2400, "low": 2400, "medium": 8192, "high": 16384][reasoning] ?? 32768
    }

    public var isClaude: Bool { model.hasPrefix("claude-") }

    /// USD per million tokens: input, cached input, output (standard tier; prompts under 100K for Haiku).
    var rates: (input: Double, cached: Double, output: Double) {
        switch model {
        case "gpt-6-luna": (0.1, 0.01, 0.5)
        case "gpt-5.6-luna": (0.2, 0.02, 1.2)
        case "gpt-6-sol": (2, 0.2, 10)
        case "claude-haiku-5-5": (0.1, 0.01, 0.5)
        case "claude-sonnet-5-5": (2, 0.2, 10)
        default: (2, 0.1, 10)   // gpt-6.1-sol
        }
    }
}

/// An event the model found, already converted to absolute dates, with everything that needs a second look.
public struct ExtractedEvent: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    public var start: Date
    /// Exclusive. All-day events end at the start of the day after their last day.
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var notes: String
    /// The source zone, retained even when its current UTC offset matches yours.
    public var sourceTimeZone: TimeZone?
    public var confidence: String
    /// Things to double-check before saving.
    public var warnings: [String]
    /// Neutral notes, like a time-zone conversion the app did.
    public var info: [String] = []
    /// One "RRULE:…" line for a repeating event, or empty.
    public var recurrence: [String] = []
    /// One of your calendars, by name, when you asked for it.
    public var calendar: String?
    /// When you asked to be reminded: an alarm this many minutes before the start.
    public var alarmMinutesBefore: Int?
    /// Shared by individual cards and bulk addition. Nil keeps compatibility with extracted defaults.
    public var wantsAlarm: Bool?
    public var shouldSetAlarm: Bool { wantsAlarm ?? (alarmMinutesBefore != nil) }

    func calendarEvent(in calendar: CalendarRecord) -> CalendarEvent {
        CalendarEvent(id: "", calendarID: calendar.id, accountID: calendar.accountID, title: title,
                      start: start, end: end, isAllDay: isAllDay, location: location, notes: notes,
                      recurrence: recurrence, timeZone: sourceTimeZone?.identifier)
    }

    mutating func moveStart(to date: Date, calendar: Calendar = .current) {
        let moved = CalendarDates.moving(start: start, end: end, to: date, allDay: isAllDay, calendar: calendar)
        start = moved.start; end = moved.end
    }

    public enum ZoneStatus: Sendable, Equatable {
        /// In your time zone, stated or (for local things) assumed.
        case local
        /// Given in another zone and converted to yours; `sourceTimeText` has the original.
        case converted
        /// No zone given, but probably not yours: shown as your time, flagged to check.
        case unclear
    }
    public var zoneStatus: ZoneStatus = .local
    /// Your zone, e.g. "Prague, UTC+2".
    public var localZoneText = ""
    /// The source's own times when converted, e.g. "15:00–16:00 New York time (EDT, UTC−4)".
    public var sourceTimeText: String?
    /// How the zone was decided when it wasn't written down, e.g. "From the airports (PRG → LHR)".
    public var zoneNote: String?
}

public struct EventExtraction: Sendable {
    public var events: [ExtractedEvent]
    public var message: String?
    public var usage: Usage
    public var seconds: Double
    /// The model that actually answered (differs only after a Claude refusal fallback).
    public var servedModel: String?

    public struct Usage: Sendable, Equatable {
        public var inputTokens = 0
        public var cachedTokens = 0
        public var outputTokens = 0
        public var reasoningTokens = 0
        /// USD per million tokens for the model that answered; GPT-6.1 Sol unless set.
        public var rates: (input: Double, cached: Double, output: Double) = (2, 0.1, 10)
        public var estimatedCost: Double {
            (Double(inputTokens - cachedTokens) * rates.input + Double(cachedTokens) * rates.cached + Double(outputTokens) * rates.output) / 1e6
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.inputTokens == rhs.inputTokens && lhs.cachedTokens == rhs.cachedTokens
                && lhs.outputTokens == rhs.outputTokens && lhs.reasoningTokens == rhs.reasoningTokens
        }
    }
}

public enum EventExtractorError: Error, LocalizedError, Sendable {
    case missingKey, empty
    case http(Int, String)
    case incomplete(String)
    case refused(String)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add an API key in Preferences to use AI add."
        case .empty: "Type something or paste a screenshot first."
        case let .http(status, message): "The AI service returned \(status): \(message)"
        case let .incomplete(reason): "The answer was cut short (\(reason)). Try again."
        case let .refused(message): "The model declined: \(message)"
        case .invalidOutput: "The model's answer could not be read. Try again."
        }
    }
}

public struct EventExtractor: Sendable {
    public struct Image: Sendable {
        public var data: Data
        public var mimeType: String
        public init(data: Data, mimeType: String = "image/png") { self.data = data; self.mimeType = mimeType }
    }

    public var apiKey: String
    public var settings: EventExtractorSettings
    /// Anthropic keys that aren't scoped to one workspace must name it.
    public var anthropicWorkspaceID: String?
    private let session: URLSession

    public init(apiKey: String, settings: EventExtractorSettings = .init(), anthropicWorkspaceID: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey; self.settings = settings; self.anthropicWorkspaceID = anthropicWorkspaceID; self.session = session
    }

    /// `calendars` are the names of the calendars you can add to, so the AI can pick one when asked.
    public func extract(text: String, images: [Image], now: Date = .now, timeZone: TimeZone = .current,
                        calendars: [String] = []) async throws -> EventExtraction {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw EventExtractorError.missingKey }
        guard !text.isEmpty || !images.isEmpty else { throw EventExtractorError.empty }
        let claude = settings.isClaude
        var request = URLRequest(url: URL(string: claude ? "https://api.anthropic.com/v1/messages" : "https://api.openai.com/v1/responses")!,
                                 timeoutInterval: ["none", "low"].contains(settings.reasoning) ? 60 : 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if claude {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let anthropicWorkspaceID { request.setValue(anthropicWorkspaceID, forHTTPHeaderField: "anthropic-workspace-id") }
            if Self.usesServerFallback(settings.model) { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = claude ? Self.claudeBody(text: text, images: images, now: now, timeZone: timeZone, settings: settings, calendars: calendars)
            : Self.body(text: text, images: images, now: now, timeZone: timeZone, settings: settings, calendars: calendars)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = Date()
        var (data, response) = try await session.data(for: request)
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Overload and rate limits are usually gone a moment later.
        for delay in [1.5, 4.0] where [429, 500, 502, 503, 529].contains(status) {
            try await Task.sleep(for: .seconds(delay))
            (data, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw EventExtractorError.http(status, message)
        }
        var result = try claude ? Self.parseClaude(response: data, now: now, timeZone: timeZone, calendars: calendars)
            : Self.parse(response: data, now: now, timeZone: timeZone, calendars: calendars)
        result.usage.rates = settings.rates
        result.seconds = Date().timeIntervalSince(started)
        return result
    }

    // MARK: Request

    static func body(text: String, images: [Image], now: Date, timeZone: TimeZone, settings: EventExtractorSettings,
                     calendars: [String] = []) -> [String: Any] {
        var content: [[String: Any]] = [["type": "input_text", "text": text.isEmpty ? "Find the event(s) in this image." : text]]
        for image in images {
            content.append(["type": "input_image", "detail": "high",
                            "image_url": "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"])
        }
        return [
            "model": settings.model,
            "service_tier": settings.serviceTier,
            "reasoning": ["effort": settings.reasoning],
            "max_output_tokens": settings.maxOutputTokens,
            "store": false,
            "instructions": instructions(now: now, timeZone: timeZone, calendars: calendars),
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "calendar_events", "strict": true, "schema": schema]]
        ]
    }

    /// Anthropic Messages API: adaptive thinking with an effort level, and the same JSON schema as structured output.
    static func claudeBody(text: String, images: [Image], now: Date, timeZone: TimeZone, settings: EventExtractorSettings,
                           calendars: [String] = []) -> [String: Any] {
        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mimeType, "data": $0.data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text.isEmpty ? "Find the event(s) in this image." : text])
        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": settings.maxOutputTokens,
            "system": instructions(now: now, timeZone: timeZone, calendars: calendars),
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": settings.reasoning, "format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": content]]
        ]
        // A safety-classifier refusal is re-run on a model the API picks, inside the same call.
        if usesServerFallback(settings.model) { body["fallbacks"] = "default" }
        return body
    }

    static func usesServerFallback(_ model: String) -> Bool {
        ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"].contains(model)
    }

    static func instructions(now: Date, timeZone: TimeZone, calendars: [String] = []) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        let offset = timeZone.secondsFromGMT(for: now)
        let utc = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        return """
        You turn what the user types or screenshots (emails, web pages, chats, tickets, posters) into calendar events. \
        The user makes date and time mistakes easily, so accuracy matters more than anything else.

        Right now it is \(formatter.string(from: now)) in the user's time zone, \(timeZone.identifier) (\(utc)).

        Rules:
        - Return every distinct event the user would want on a calendar. Several sessions or dates are separate events. \
        Ignore dates that are not events: when an email was sent, deadlines to RSVP unless the user asks, copyright years, order dates.
        - Copy dates and times as the source states them, in the source's own time zone. Do not convert time zones; \
        put the source's zone in time_zone as an IANA name (for example America/New_York for "ET"/"EST"/"EDT", \
        Europe/London for "BST"/"UK time", UTC for "UTC"/"GMT"). Use null when the source names no zone; it is then the user's zone. \
        A flight or train that departs and arrives in different zones uses local times at each end: time_zone is the \
        departure zone and end_time_zone the arrival zone (infer them from the airports or stations). Otherwise end_time_zone is null.
        - time_zone_basis says how you know the zone: "stated" when the source writes it (an abbreviation, UTC offset or \
        "London time"), "inferred" when you deduced it from places (airports, stations, a venue abroad), "not_given" otherwise. \
        For inferred, time_zone_note names the clue in a few words ("from the airports PRG and LHR").
        - other_zone_likely is true when no zone is written but the event is probably not in the user's time zone: \
        the venue, sender, company or audience is in another country, or it is an online event by an organizer abroad. \
        time_zone_note then says why ("sender signs from Boston"). It is false for local events and for anything with a zone.
        - Ambiguous abbreviations (CST: US Central or China; IST: India, Israel or Ireland; BST; AST) need a warning that \
        names the zone you chose and the alternative.
        - Resolve relative dates ("tomorrow", "in 2 days", "this Thursday") from today's date above. "next <weekday>" is ambiguous \
        when that weekday is still ahead this week: pick the soonest one and warn with the other possible date. \
        When the year is missing, choose the next occurrence that is not in the past; warn about it only if the date \
        is more than three months away.
        - Times are 24-hour HH:MM. "noon" is 12:00, "midnight" at the end of a day is 00:00 on the next date. \
        Doors/arrival times are not the start unless that is the only time given; mention them in notes.
        - A festival, conference, exhibition, holiday or trip spanning several days is one all-day event with end_date, \
        even when it lists daily opening hours (put those in notes). Make separate timed events only for separate sessions, \
        bookings or meetings listed with their own times.
        - A repeating event ("every Tuesday", "weekdays", "on the 1st of every month") is ONE event: date and times are the first \
        occurrence that is not in the past, and recurrence is an RRULE such as FREQ=WEEKLY;BYDAY=TU;COUNT=8, \
        FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR or FREQ=MONTHLY;BYMONTHDAY=1. Add COUNT or UNTIL=YYYYMMDD when the source says when \
        it ends (the app converts this inclusive date to UTC for timed events); otherwise leave it open. A few specific dates ("mon, wed and fri next week") are separate events, not a recurrence. \
        recurrence is null for one-off events.
        - calendar is one of the user's calendars, \(calendars.isEmpty ? "(none listed)" : calendars.map { "“\($0)”" }.joined(separator: ", ")), \
        copied exactly, only when the user names it or asks for it; otherwise null.
        - alarm_minutes_before is set only when the user asks to be reminded or alerted before the event \
        ("remind me 30 min before", "alarm an hour before"): the minutes before the start. Otherwise null.
        - start_time null means an all-day event. Leave end_time null when the source gives no end or duration. \
        end_date is the last day of a multi-day event, otherwise null.
        - stated_weekday is the weekday the source writes next to the date (e.g. "Thursday"), or null. Never infer it yourself.
        - title is short and specific, the way the user would write it in their calendar (e.g. "Dentist – Dr. Novák", "Flight PRG→LHR BA857"). \
        location is a venue or address or video link, else null. notes holds useful details (booking codes, what to bring), \
        at most two short sentences, else null.
        - warnings lists only what the user must double-check: ambiguous dates like 03/04/2026, guessed times, plans that are \
        proposed but not confirmed, conflicting information, text that was hard to read, a zone abbreviation that doesn't fit \
        the date (EST or CET written for a date when daylight saving time applies: say which you assumed). Do not warn about \
        weekday mismatches, ordinary time zone conversion or a missing end time; the app checks those itself. Keep each warning short, and write warnings \
        and message in English. Empty when there is nothing.
        - confidence is high, medium or low.
        - If there is no event at all, return no events and explain why in message. Otherwise message is null.
        """
    }

    static var schema: [String: Any] {
        func nullable(_ description: String) -> [String: Any] { ["type": ["string", "null"], "description": description] }
        let event: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "title": ["type": "string"],
                "date": ["type": "string", "description": "Start date, YYYY-MM-DD"],
                "start_time": nullable("HH:MM 24-hour, or null for all-day"),
                "end_date": nullable("Last date YYYY-MM-DD if different from date"),
                "end_time": nullable("HH:MM 24-hour"),
                "time_zone": nullable("IANA zone stated by the source, or null"),
                "end_time_zone": nullable("IANA zone of end_time when it differs from time_zone, else null"),
                "time_zone_basis": ["type": "string", "enum": ["stated", "inferred", "not_given"]],
                "other_zone_likely": ["type": "boolean"],
                "time_zone_note": nullable("The clue for an inferred zone, or why another zone is likely"),
                "stated_weekday": nullable("Weekday written in the source next to the date"),
                "location": nullable("Venue, address or link"),
                "notes": nullable("Useful details"),
                "recurrence": nullable("RRULE for a repeating event, without the RRULE: prefix, else null"),
                "calendar": nullable("Name of the user's calendar to use, else null"),
                "alarm_minutes_before": ["type": ["integer", "null"], "description": "Minutes before the start for a reminder the user asked for"],
                "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                "warnings": ["type": "array", "items": ["type": "string"]]
            ],
            "required": ["title", "date", "start_time", "end_date", "end_time", "time_zone", "end_time_zone", "time_zone_basis", "other_zone_likely", "time_zone_note", "stated_weekday",
                         "location", "notes", "recurrence", "calendar", "alarm_minutes_before", "confidence", "warnings"]
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": ["events": ["type": "array", "items": event], "message": nullable("Why nothing was found")],
            "required": ["events", "message"]
        ]
    }

    // MARK: Response

    struct RawOutput: Decodable {
        var events: [RawEvent]
        var message: String?
    }

    struct RawEvent: Decodable {
        var title: String
        var date: String
        var start_time: String?
        var end_date: String?
        var end_time: String?
        var time_zone: String?
        var end_time_zone: String?
        var time_zone_basis: String?
        var other_zone_likely: Bool?
        var time_zone_note: String?
        var stated_weekday: String?
        var location: String?
        var notes: String?
        var recurrence: String?
        var calendar: String?
        var alarm_minutes_before: Int?
        var confidence: String
        var warnings: [String]
    }

    static func parseClaude(response data: Data, now: Date, timeZone: TimeZone, calendars: [String] = []) throws -> EventExtraction {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EventExtractorError.invalidOutput }
        let usage = root["usage"] as? [String: Any] ?? [:]
        let cached = usage["cache_read_input_tokens"] as? Int ?? 0
        let parsedUsage = EventExtraction.Usage(inputTokens: (usage["input_tokens"] as? Int ?? 0) + cached, cachedTokens: cached,
                                                outputTokens: usage["output_tokens"] as? Int ?? 0)
        switch root["stop_reason"] as? String {
        case "refusal": throw EventExtractorError.refused((root["stop_details"] as? [String: Any])?["explanation"] as? String ?? "")
        case "max_tokens": throw EventExtractorError.incomplete("max_tokens")
        default: break
        }
        let text = (root["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        guard let raw = try? JSONDecoder().decode(RawOutput.self, from: Data(text.utf8)) else { throw EventExtractorError.invalidOutput }
        let events = raw.events.compactMap { resolve($0, now: now, timeZone: timeZone, calendars: calendars) }
        guard events.count == raw.events.count else { throw EventExtractorError.invalidOutput }
        return EventExtraction(events: events,
                               message: raw.message, usage: parsedUsage, seconds: 0, servedModel: root["model"] as? String)
    }

    static func parse(response data: Data, now: Date, timeZone: TimeZone, calendars: [String] = []) throws -> EventExtraction {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EventExtractorError.invalidOutput }
        let usage = root["usage"] as? [String: Any] ?? [:]
        let parsedUsage = EventExtraction.Usage(
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            cachedTokens: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            reasoningTokens: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0)
        if root["status"] as? String == "incomplete" {
            throw EventExtractorError.incomplete((root["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "unknown")
        }
        var text: String?
        for item in root["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "refusal" { throw EventExtractorError.refused(part["refusal"] as? String ?? "") }
                if part["type"] as? String == "output_text" { text = part["text"] as? String }
            }
        }
        guard let text, let raw = try? JSONDecoder().decode(RawOutput.self, from: Data(text.utf8)) else {
            throw EventExtractorError.invalidOutput
        }
        let events = raw.events.compactMap { resolve($0, now: now, timeZone: timeZone, calendars: calendars) }
        guard events.count == raw.events.count else { throw EventExtractorError.invalidOutput }
        return EventExtraction(events: events,
                               message: raw.message, usage: parsedUsage, seconds: 0)
    }

    /// Dates are computed here, not by the model, so time zones and weekdays are checked by code.
    static func resolve(_ raw: RawEvent, now: Date, timeZone local: TimeZone, calendars: [String] = []) -> ExtractedEvent? {
        var warnings = raw.warnings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var info: [String] = []
        func zone(_ name: String?, otherwise fallback: TimeZone) -> TimeZone {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return fallback }
            if let parsed = TimeZone(identifier: name) { return parsed }
            warnings.append("Unknown time zone “\(name)”; used yours.")
            return fallback
        }
        let startZone = zone(raw.time_zone, otherwise: local)
        let endZone = zone(raw.end_time_zone, otherwise: startZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = startZone
        var endCalendar = calendar
        endCalendar.timeZone = endZone
        guard let day = components(raw.date) else { return nil }
        guard raw.start_time == nil || raw.start_time.flatMap(time) != nil,
              raw.end_time == nil || raw.end_time.flatMap(time) != nil,
              raw.end_date == nil || raw.end_date.flatMap(components) != nil else { return nil }
        let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var event = ExtractedEvent(title: title.isEmpty ? "Untitled event" : title, start: now, end: now, isAllDay: false,
                                   location: raw.location ?? "", notes: raw.notes ?? "", sourceTimeZone: nil,
                                   confidence: raw.confidence, warnings: [])

        if let startTime = raw.start_time.flatMap(time) {
            guard let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day,
                                                                 hour: startTime.hour, minute: startTime.minute)) else { return nil }
            event.start = start
            event.sourceTimeZone = startZone
            let endDay = raw.end_date.flatMap(components) ?? day
            if let endTime = raw.end_time.flatMap(time),
               var end = endCalendar.date(from: DateComponents(year: endDay.year, month: endDay.month, day: endDay.day,
                                                            hour: endTime.hour, minute: endTime.minute)) {
                if end <= start {
                    // Models often repeat the start date as end_date; only a different end day is a contradiction.
                    guard endDay == day else { return nil }
                    end = calendar.date(byAdding: .day, value: 1, to: end)!
                    info.append("Ends after midnight, on the next day.")
                }
                event.end = end
            } else {
                event.end = start.addingTimeInterval(3600)
                // "From 9:00 on the 22nd to the 24th" must not quietly become a one-hour event.
                if let endDay = raw.end_date.flatMap(components), endDay != day {
                    warnings.append("Runs until \(raw.end_date!), but no end time was given, so it's set to one hour. Check the end.")
                }
            }
            event.localZoneText = Self.zoneText(local, at: start)
            let startDiffers = startZone.secondsFromGMT(for: start) != local.secondsFromGMT(for: start)
            let endDiffers = endZone.secondsFromGMT(for: event.end) != local.secondsFromGMT(for: event.end)
            if startDiffers || endDiffers {
                event.zoneStatus = .converted
                event.sourceTimeZone = startZone
                if endZone.secondsFromGMT(for: event.end) == startZone.secondsFromGMT(for: event.end) {
                    event.sourceTimeText = "\(Self.clock(start, startZone))–\(Self.clock(event.end, startZone)) \(Self.placeTime(startZone, at: start))"
                } else {
                    event.sourceTimeText = "Starts \(Self.clock(start, startZone)) \(Self.placeTime(startZone, at: start)), "
                        + "ends \(Self.clock(event.end, endZone)) \(Self.placeTime(endZone, at: event.end))"
                }
                if raw.time_zone_basis == "inferred" {
                    event.zoneNote = "Time zone worked out " + (raw.time_zone_note.map { $0.lowercased().hasPrefix("from") ? $0 : "from \($0)" } ?? "from the places mentioned")
                }
            } else if (raw.time_zone ?? "").isEmpty, raw.other_zone_likely == true {
                event.zoneStatus = .unclear
                event.zoneNote = raw.time_zone_note
                if !warnings.contains(where: { $0.localizedCaseInsensitiveContains("zone") }) { warnings.append("No time zone given, but this is probably not in your time zone"
                                + (raw.time_zone_note.map { " (\($0))" } ?? "") + ". Shown as \(Self.placeName(local)) time: check the real time.") }
            }
            // The night the clocks change, a time can happen twice or not at all (unless the model already said so).
            let modelSaidSo = warnings.contains { $0.localizedCaseInsensitiveContains("daylight") || $0.localizedCaseInsensitiveContains("clocks") }
            for zone in Set([startZone, local].map(\.identifier)).compactMap(TimeZone.init(identifier:)) where !modelSaidSo {
                if let change = zone.nextDaylightSavingTimeTransition(after: start.addingTimeInterval(-3 * 3600)),
                   change < event.end.addingTimeInterval(3600) {
                    warnings.append("Clocks change in \(Self.placeName(zone)) that night (\(Self.clock(change, zone))), so check the time.")
                }
            }
        } else {
            // All-day dates are calendar days, not instants: keep them on the stated day in your zone.
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.timeZone = local
            guard let start = localCalendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return nil }
            let last = raw.end_date.flatMap(components).flatMap {
                localCalendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day))
            } ?? start
            guard last >= start else { return nil }
            event.isAllDay = true
            event.start = start
            event.end = localCalendar.date(byAdding: .day, value: 1, to: last)!
            calendar = localCalendar
        }

        if let stated = raw.stated_weekday?.trimmingCharacters(in: .whitespaces).lowercased(), stated.count >= 2 {
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let actual = names[calendar.component(.weekday, from: event.start) - 1]
            if !actual.hasPrefix(String(stated.prefix(3))) {
                let date = DateFormatter()
                date.timeZone = calendar.timeZone
                date.dateFormat = "d MMM yyyy"
                warnings.append("The source says \(raw.stated_weekday!), but \(date.string(from: event.start)) is a \(actual.capitalized). Check the date.")
            }
        }
        if let rule = raw.recurrence?.trimmingCharacters(in: .whitespaces), !rule.isEmpty {
            if let normalized = RepeatRule.normalize(rule) { event.recurrence = [normalized] }
            else { warnings.append("Couldn't read the repeat pattern, so it's added once.") }
        }
        if let name = raw.calendar, let match = calendars.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            event.calendar = match
        }
        if let minutes = raw.alarm_minutes_before, (0...10_080).contains(minutes) { event.alarmMinutesBefore = minutes }
        if event.end < now && event.recurrence.isEmpty { warnings.append("This is in the past.") }
        else if event.start > now.addingTimeInterval(300 * 86_400) { warnings.append("This is more than 10 months away.") }
        event.warnings = warnings
        event.info = info
        return event
    }

    // MARK: Time zone wording

    static func clock(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "New York", "Prague", or "UTC".
    static func placeName(_ zone: TimeZone) -> String {
        guard zone.identifier.contains("/") else { return zone.secondsFromGMT() == 0 ? "UTC" : zone.identifier }
        return zone.identifier.split(separator: "/").last!.replacingOccurrences(of: "_", with: " ")
    }

    /// "UTC+2", "UTC−4", "UTC+5:30".
    static func offsetText(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "−" : "+"
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        return seconds == 0 ? "UTC" : "UTC\(sign)\(hours)" + (minutes == 0 ? "" : ":\(String(format: "%02d", minutes))")
    }

    /// "Prague, UTC+2" or "New York, EDT, UTC−4" (named abbreviations only where they are unambiguous in English).
    static func zoneText(_ zone: TimeZone, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = zone
        formatter.dateFormat = "zzz"
        let abbreviation = formatter.string(from: date)
        let named = abbreviation.hasPrefix("GMT") || abbreviation.hasPrefix("UTC") ? "" : "\(abbreviation), "
        return placeName(zone) == "UTC" ? "UTC" : "\(placeName(zone)), \(named)\(offsetText(zone, at: date))"
    }

    /// "New York time (EDT, UTC−4)".
    static func placeTime(_ zone: TimeZone, at date: Date) -> String {
        let text = zoneText(zone, at: date)
        guard let comma = text.firstIndex(of: ",") else { return text }
        return "\(text[..<comma]) time (\(text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)))"
    }

    private static func components(_ value: String) -> (year: Int, month: Int, day: Int)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = CalendarDates.day(text, calendar: calendar) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year!, parts.month!, parts.day!)
    }

    private static func time(_ value: String) -> (hour: Int, minute: Int)? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0...59).contains(parts[1]), parts[0] != 24 || parts[1] == 0 else { return nil }
        return (parts[0], parts[1])
    }
}
