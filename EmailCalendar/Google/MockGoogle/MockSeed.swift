import Foundation

/// Demo mailbox and calendars, generated relative to the first launch.
enum MockSeed {
    struct Arrival {
        var from: String
        var subject: String
        var body: String
        var html: String?
        var threadID: String?
    }

    static let me = "\(MockGoogleBackend.accountName) <\(MockGoogleBackend.accountEmail)>"

    static func make(now: Date) -> MockState {
        var state = MockState()
        state.labels = MockGoogleBackend.systemLabels.sorted().map {
            GoogleLabel(id: $0, name: $0, type: "system", messageListVisibility: nil, labelListVisibility: nil)
        }
        // Pre-create the app's labels so seeded mail can already be Set Aside.
        for name in ["HEY/Set Aside", "HEY/Bubble Up", "HEY/Screener", "HEY/Screened Out"] {
            state.labelCounter += 1
            state.labels.append(GoogleLabel(id: "Label_\(state.labelCounter)", name: name, type: "user",
                                            messageListVisibility: "show", labelListVisibility: "labelShow"))
        }
        let setAside = "Label_1"
        let hour: TimeInterval = 3_600, day: TimeInterval = 86_400
        var counter = 0
        func add(_ thread: String, from: String, to: String = me, subject: String, body: String, ago: TimeInterval,
                 labels: Set<String>, html: String? = nil, attachments: [(String, String, String)] = []) {
            counter += 1
            let id = "m\(String(format: "%04d", counter))"
            var headers = [GoogleMailHeader(name: "From", value: from), GoogleMailHeader(name: "To", value: to),
                           GoogleMailHeader(name: "Subject", value: subject),
                           GoogleMailHeader(name: "Message-ID", value: "<\(id)@mock.example>")]
            if let parent = state.thread(thread).last {
                headers.append(GoogleMailHeader(name: "In-Reply-To", value: parent.header("Message-ID")))
            }
            state.messages[id] = MockMessage(
                id: id, threadId: thread, labelIds: labels,
                internalDate: Int64(now.addingTimeInterval(-ago).timeIntervalSince1970 * 1_000),
                headers: headers, plain: body, html: html,
                attachments: attachments.enumerated().map { index, file in
                    MockAttachment(id: "\(id)-att\(index)", filename: file.0, mimeType: file.1, data: Data(file.2.utf8))
                })
        }

        let maya = "Maya Chen <maya.chen@northwind.io>"
        add("t-roadmap", from: maya, subject: "Q4 roadmap draft",
            body: "Hi Alex,\n\nFirst pass at the Q4 roadmap is in the doc. Biggest open question is whether checkout v2 slips to January.\n\nCan you sanity-check the estimates before Thursday?\n\nMaya",
            ago: 3 * day, labels: ["INBOX"])
        add("t-roadmap", from: me, to: maya, subject: "Re: Q4 roadmap draft",
            body: "Looks solid. I think checkout v2 is realistic for mid-December if we drop the gift-card flow. Will add comments tonight.",
            ago: 3 * day - 2 * hour, labels: ["SENT"])
        add("t-roadmap", from: maya, subject: "Re: Q4 roadmap draft",
            body: "Thanks! I exported the estimates so you can filter them. Agree on gift cards — let's raise it in planning.",
            ago: 2 * hour, labels: ["INBOX", "UNREAD"],
            attachments: [("q4-estimates.csv", "text/csv", "Epic,Owner,Weeks\nCheckout v2,Alex,6\nSearch revamp,Maya,4\nGift cards,Sam,3\n")])

        let tom = "Tom Becker <tom@beckerfamily.net>"
        add("t-climb", from: tom, subject: "Climbing Saturday?",
            body: "New bouldering gym opened near the river. Saturday morning? I can pick you up at 9.", ago: day + 3 * hour, labels: ["INBOX"])
        add("t-climb", from: me, to: tom, subject: "Re: Climbing Saturday?",
            body: "Yes! 9 works. I'll bring the chalk.", ago: day, labels: ["SENT"])
        add("t-climb", from: tom, subject: "Re: Climbing Saturday?",
            body: "Great. Lunch after? I booked us a table at Lokál for 12:30.", ago: 40 * 60, labels: ["INBOX", "UNREAD"])

        let jana = "Jana Novak <jana.novak@gmail.com>"
        add("t-boiler", from: jana, subject: "Boiler service next week",
            body: "Hello Alex, the technician will come on Wednesday between 8 and 10 to service the boiler. Please make sure someone is home.\n\nJana",
            ago: 2 * day, labels: ["INBOX"])
        add("t-boiler", from: me, to: jana, subject: "Re: Boiler service next week",
            body: "Thanks Jana, I'll work from home that morning.", ago: 2 * day - hour, labels: ["SENT"])

        add("t-logo", from: "Priya Shah <priya@studio-shah.design>", subject: "Logo concepts v2",
            body: "Hi Alex — three new directions attached in the deck. My favourite is B (the stacked wordmark). Let me know by Friday?",
            ago: 5 * hour, labels: ["INBOX", "UNREAD"],
            html: "<p>Hi Alex — three new directions are in the deck.</p><p>My favourite is <b>B</b> (the stacked wordmark). Let me know by Friday?</p><p>Priya</p>")
        add("t-logo", from: me, to: "Priya Shah <priya@studio-shah.design>", subject: "Re: Logo concepts v2",
            body: "These are great, will send feedback tomorrow.", ago: 4 * hour, labels: ["SENT"])

        add("t-pr", from: "GitHub <notifications@github.com>", subject: "[northwind/web] Fix flaky checkout test (#482)",
            body: "@maya-chen requested your review on this pull request.\n\nThe checkout spec was racing the payment iframe. This waits for the ready event instead of sleeping.",
            ago: hour, labels: ["INBOX", "UNREAD"])
        add("t-linear", from: "Linear <notifications@linear.app>", subject: "3 issues assigned to you",
            body: "NW-1203 Search results flicker on slow connections\nNW-1188 Add keyboard shortcut for archive\nNW-1176 Dark mode contrast on order page",
            ago: 4 * hour, labels: ["INBOX"])
        add("t-news", from: "Field Notes <hello@fieldnotes.news>", subject: "Field Notes #112: The quiet power of defaults",
            body: "This week: why the best tools decide less for you, a short history of the inbox, and three links worth your time.",
            ago: 9 * hour, labels: ["INBOX"],
            html: "<h2>Field Notes #112</h2><img src=\"https://images.fieldnotes.news/112/header.png\" width=\"560\"><p>This week: why the best tools decide less for you, a short history of the inbox, and three links worth your time.</p>")
        add("t-trip", from: "Northwind Air <receipts@northwindair.example>", subject: "Your trip to Lisbon — booking ZK4P2Q",
            body: "Thanks for booking with Northwind Air. Your itinerary is attached.\n\nPRG → LIS, departing 07:05.",
            ago: day + 6 * hour, labels: ["INBOX"],
            attachments: [("itinerary.txt", "text/plain", "Booking ZK4P2Q\nPRG 07:05 → LIS 09:40\nLIS 18:20 → PRG 22:50\nSeat 14A\n")])
        add("t-bank", from: "Fio Bank <noreply@fio.example>", subject: "Your monthly statement is ready",
            body: "Your statement for September is available in internet banking.", ago: 2 * day + 5 * hour, labels: ["INBOX"])
        add("t-mom", from: "Eva Rivera <eva.rivera@seznam.cz>", subject: "Sunday lunch?",
            body: "Are you coming on Sunday? I'm making svíčková. Bring Tom if he's free!", ago: 20 * hour, labels: ["INBOX", "UNREAD"])

        add("t-lease", from: jana, subject: "Lease renewal", body: "Attached is the renewed lease for next year. No changes except the dates.",
            ago: 10 * day, labels: [setAside],
            attachments: [("lease-2027.txt", "text/plain", "Residential lease\nTerm: 1 Jan 2027 – 31 Dec 2027\nRent unchanged.\n")])
        add("t-config", from: "Config <events@config.example>", subject: "Your Config 2026 schedule",
            body: "Day 1: Keynote 9:00, Systems at scale 11:00\nDay 2: Workshops all day", ago: 12 * day, labels: [setAside])

        add("t-notes", from: "Sam Ortiz <sam.ortiz@northwind.io>", subject: "1:1 notes",
            body: "Notes from today: hiring plan, on-call rotation, and the offsite budget.", ago: 6 * day, labels: [])
        add("t-notes", from: me, to: "Sam Ortiz <sam.ortiz@northwind.io>", subject: "Re: 1:1 notes",
            body: "Thanks Sam — I'll draft the rotation by Monday.", ago: 6 * day - hour, labels: ["SENT"])
        add("t-invoice", from: me, to: "Accounts <accounting@client.example>", subject: "Invoice 2026-09",
            body: "Hello, please find the September invoice details below. Total: €4,200. Due in 14 days.", ago: 4 * day, labels: ["SENT"])
        add("t-offsite", from: me, to: maya, subject: "Ideas for the offsite",
            body: "Rough list so far:\n- half-day hike\n- roadmap retro\n- ", ago: 30 * 60, labels: ["DRAFT"])
        state.drafts["r-offsite"] = "m\(String(format: "%04d", counter))"

        state.idCounter = 100
        state.historyID = 1_000
        state.oldestHistoryID = 1_000
        seedCalendar(into: &state, now: now)
        return state
    }

    /// Simulated arrivals cycle through new senders (for the Screener) and replies from known ones.
    static func nextArrival(index: Int, knownThreads: Set<String>, state: MockState) -> Arrival {
        let pool: [Arrival] = [
            Arrival(from: "Lena Park <lena@parkandco.studio>", subject: "Intro: Lena from Park & Co",
                    body: "Hi Alex, Maya suggested I reach out — we help product teams run research sprints. Open to a 20-minute chat next week?"),
            Arrival(from: "Maya Chen <maya.chen@northwind.io>", subject: "Re: Q4 roadmap draft",
                    body: "Planning moved to 10:00 Thursday, same room. Bringing snacks.", threadID: "t-roadmap"),
            Arrival(from: "Deals Weekly <promo@dealsweekly.example>", subject: "48 hours only: 60% off everything",
                    body: "Our biggest sale of the season starts now. Don't miss out!",
                    html: "<h1>60% OFF</h1><img src=\"https://cdn.dealsweekly.example/banner.jpg\"><p>Our biggest sale of the season starts now.</p>"),
            Arrival(from: "Hire Fast <talent@hire-fast.example>", subject: "Exciting opportunity for you",
                    body: "Hi there, I came across your profile and think you'd be a perfect fit for a fast-growing startup."),
            Arrival(from: "Tom Becker <tom@beckerfamily.net>", subject: "Re: Climbing Saturday?",
                    body: "Forecast says rain, so indoor it is. See you at 9!", threadID: "t-climb"),
            Arrival(from: "Kovac Dental <appointments@kovacdental.example>", subject: "Reminder: cleaning on Tuesday",
                    body: "This is a reminder of your appointment on Tuesday at 8:00. Reply C to confirm.")
        ]
        var arrival = pool[index % pool.count]
        if let thread = arrival.threadID, !knownThreads.contains(thread) { arrival.threadID = nil }
        if index >= pool.count && arrival.threadID == nil { arrival.subject += " (\(index / pool.count + 1))" }
        return arrival
    }

    /// This month busy (one to three entries on weekdays) and next month light (zero or one), so
    /// the calendar views can be judged with a realistic but readable schedule. Replaces any earlier
    /// generated batch: those events are deleted, so synced caches drop them too.
    static func addBusyCalendar(into state: inout MockState, now: Date) {
        for index in state.events.indices where state.events[index].event.id.hasPrefix("busy") && !state.events[index].deleted {
            state.events[index].deleted = true
            state.calendarVersion += 1
            state.events[index].version = state.calendarVersion
        }
        let calendar = Calendar.current
        let zone = TimeZone.current.identifier
        let iso = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let mine = MockGoogleBackend.accountEmail, work = "work@group.calendar.google.com"
        let family = "family@group.calendar.google.com"
        let workTitles = ["Design crit", "Sprint planning", "1:1 with Maya", "Customer call", "Code review", "Hiring panel",
                          "Roadmap review", "Retro", "Pairing with Sam", "Vendor call", "Bug triage", "Interview"]
        let personalTitles = ["Run", "Groceries", "Haircut", "Coffee with Tom", "Therapy", "Call Mom", "Yoga", "Swim"]
        let familyTitles = ["Dinner at Mom's", "Birthday party", "Movie night", "Brunch"]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let thisMonth = calendar.dateInterval(of: .month, for: now)!
        let nextMonth = calendar.dateInterval(of: .month, for: thisMonth.end)!
        var day = thisMonth.start
        while day < nextMonth.end {
            let full = day < thisMonth.end
            let weekend = calendar.isDateInWeekend(day)
            var entries: [(String, String)] = []
            if weekend {
                for _ in 0..<(full ? next(2) : (next(4) == 0 ? 1 : 0)) {
                    entries.append(next(2) == 0 ? (family, familyTitles[next(familyTitles.count)]) : (mine, personalTitles[next(personalTitles.count)]))
                }
            } else {
                for _ in 0..<(full ? 1 + next(2) : next(2)) { entries.append((work, workTitles[next(workTitles.count)])) }
                if full && next(4) == 0 { entries.append((mine, personalTitles[next(personalTitles.count)])) }
            }
            let key = dayFormatter.string(from: day)
            for (index, entry) in entries.enumerated() {
                let hour = min(19, 9 + index * 2 + next(2))
                let start = calendar.date(bySettingHour: hour, minute: next(2) * 30, second: 0, of: day)!
                let minutes = [30, 45, 60, 90][next(4)]
                var event = GoogleEvent(id: "busy4\(key.replacingOccurrences(of: "-", with: ""))x\(index)", summary: entry.1,
                                        start: GoogleEventDateTime(dateTime: iso.string(from: start), timeZone: zone),
                                        end: GoogleEventDateTime(dateTime: iso.string(from: start.addingTimeInterval(Double(minutes) * 60)), timeZone: zone))
                event.status = "confirmed"
                event.etag = "\"busy4-\(key)-\(index)\""
                if entry.0 == work && next(3) == 0 { event.hangoutLink = "https://meet.google.com/busy-\(key)-\(index)" }
                state.calendarVersion += 1
                state.events.append(MockEvent(calendarID: entry.0, event: event, version: state.calendarVersion))
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
    }

    private static func seedCalendar(into state: inout MockState, now: Date) {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let zone = TimeZone.current.identifier
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0, from base: Date? = nil) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: base ?? weekStart)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let iso = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        func timed(_ date: Date) -> GoogleEventDateTime { GoogleEventDateTime(dateTime: iso.string(from: date), timeZone: zone) }
        func allDay(_ date: Date) -> GoogleEventDateTime { GoogleEventDateTime(date: dayFormatter.string(from: date)) }

        func cal(_ id: String, _ name: String, _ color: String, role: String = "owner", primary: Bool = false) -> GoogleCalendar {
            GoogleCalendar(id: id, summary: name, summaryOverride: nil, description: nil, timeZone: zone, backgroundColor: color,
                           foregroundColor: "#FFFFFF", primary: primary, selected: true, accessRole: role, deleted: nil)
        }
        let mine = MockGoogleBackend.accountEmail, work = "work@group.calendar.google.com"
        let family = "family@group.calendar.google.com", holidays = "en.czech#holiday@group.v.calendar.google.com"
        state.calendars = [cal(mine, MockGoogleBackend.accountName, "#4F8A6B", primary: true), cal(work, "Work", "#4A6FA5"),
                           cal(family, "Family", "#D08C3E"), cal(holidays, "Holidays in Czechia", "#8E6FB0", role: "reader")]

        var counter = 0
        func add(_ calendarID: String, _ title: String, _ start: GoogleEventDateTime, _ end: GoogleEventDateTime,
                 rrule: String? = nil, location: String? = nil, notes: String? = nil, meet: String? = nil,
                 organizer: String? = nil, guests: [(String, String)] = []) {
            counter += 1
            var event = GoogleEvent(id: "seed\(counter)", summary: title, start: start, end: end, description: notes,
                                    location: location, recurrence: rrule.map { ["RRULE:\($0)"] })
            event.status = "confirmed"
            event.hangoutLink = meet
            event.etag = "\"seed\(counter)\""
            if !guests.isEmpty {
                event.attendees = guests.map { email, status in
                    var attendee = GoogleAttendee(email: email, responseStatus: status)
                    if email == mine { attendee.isSelf = true; attendee.displayName = MockGoogleBackend.accountName }
                    if email == organizer { attendee.organizer = true }
                    return attendee
                }
            }
            event.organizer = GoogleAttendee(email: organizer ?? mine, responseStatus: nil)
            state.calendarVersion += 1
            state.events.append(MockEvent(calendarID: calendarID, event: event, version: state.calendarVersion))
        }

        let lastWeek = calendar.date(byAdding: .day, value: -7, to: weekStart)!
        add(work, "Daily standup", timed(at(0, 9, 30, from: lastWeek)), timed(at(0, 9, 45, from: lastWeek)),
            rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", meet: "https://meet.google.com/abc-defg-hij")
        add(work, "1:1 with Sam", timed(at(1, 14, from: lastWeek)), timed(at(1, 14, 30, from: lastWeek)),
            rrule: "FREQ=WEEKLY;BYDAY=TU", location: "Sam's desk")
        add(mine, "Gym", timed(at(0, 18, from: lastWeek)), timed(at(0, 19, from: lastWeek)), rrule: "FREQ=WEEKLY;BYDAY=MO,WE,FR",
            location: "Holmes Place")

        // Always something coming up soon after first launch, so the overlay's "Next" line is alive.
        let soon = calendar.date(bySetting: .second, value: 0, of: now.addingTimeInterval(35 * 60)) ?? now.addingTimeInterval(35 * 60)
        let soonStart = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: soon))!
        let rounded = soonStart.addingTimeInterval(-Double(calendar.component(.minute, from: soonStart) % 5) * 60)
        add(work, "Design review", timed(rounded), timed(rounded.addingTimeInterval(45 * 60)),
            location: "https://zoom.us/j/9876543210", notes: "Logo directions + onboarding flow.",
            guests: [(mine, "accepted"), ("priya@studio-shah.design", "accepted"), ("maya.chen@northwind.io", "tentative")])
        add(work, "Roadmap planning", timed(at(3, 10)), timed(at(3, 12)), location: "Room Atlas",
            notes: "Agenda: checkout v2 scope, gift cards, Q4 staffing.")
        add(work, "Vendor demo", timed(at(2, 15)), timed(at(2, 16)), organizer: "sales@vendor.example",
            guests: [(mine, "declined"), ("sales@vendor.example", "accepted")])
        add(work, "Quarterly all-hands", timed(at(7, 16)), timed(at(7, 17)), meet: "https://meet.google.com/xyz-quar-ter",
            organizer: "ceo@northwind.io",
            guests: [("ceo@northwind.io", "accepted"), (mine, "needsAction"), ("maya.chen@northwind.io", "accepted")])
        add(mine, "Climbing with Tom", timed(at(5, 9)), timed(at(5, 11, 30)), location: "Boulder Bar Holešovice")
        add(mine, "Lunch at Lokál", timed(at(5, 12, 30)), timed(at(5, 14)), location: "Lokál Dlouhá")
        add(mine, "Boiler service", timed(at(2, 8)), timed(at(2, 10)), notes: "Technician, someone must be home.")
        add(mine, "Dentist", timed(at(8, 8)), timed(at(8, 8, 45)), location: "Kovac Dental")
        add(family, "Sunday lunch at Mom's", timed(at(6, 12)), timed(at(6, 15)))
        add(family, "Lisbon trip", allDay(at(10, 0)), allDay(at(13, 0)), notes: "Booking ZK4P2Q")
        add(family, "Mom's birthday", allDay(at(16, 0)), allDay(at(17, 0)), rrule: "FREQ=YEARLY")

        let year = calendar.component(.year, from: now)
        for (month, dayOfMonth, title) in [(10, 28, "Independence Day"), (11, 17, "Freedom and Democracy Day"),
                                           (12, 24, "Christmas Eve"), (12, 25, "Christmas Day"), (12, 26, "St. Stephen's Day")] {
            for offset in [0, 1] {
                guard let date = calendar.date(from: DateComponents(year: year + offset, month: month, day: dayOfMonth)) else { continue }
                add(holidays, title, allDay(date), allDay(calendar.date(byAdding: .day, value: 1, to: date)!))
            }
        }
    }
}
