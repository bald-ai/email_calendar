import XCTest
import Foundation
@testable import EmailCalendarCore

final class AlarmTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        return calendar
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 14, minute: 0))!

    private func parse(_ text: String) -> Date? { AlarmTime.parse(text, now: now, calendar: calendar) }
    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testDurations() {
        XCTAssertEqual(parse("10"), now.addingTimeInterval(600))
        XCTAssertEqual(parse("10m"), now.addingTimeInterval(600))
        XCTAssertEqual(parse("in 20 min"), now.addingTimeInterval(1200))
        XCTAssertEqual(parse("1h"), now.addingTimeInterval(3600))
        XCTAssertEqual(parse("1h30"), now.addingTimeInterval(5400))
        XCTAssertEqual(parse("1h 30m"), now.addingTimeInterval(5400))
        XCTAssertEqual(parse("1.5h"), now.addingTimeInterval(5400))
        XCTAssertEqual(parse("90s"), now.addingTimeInterval(90))
    }

    func testClockTimesRollToTheNextOccurrence() {
        XCTAssertEqual(parse("14:30"), at(12, 14, 30))
        XCTAssertEqual(parse("14.30"), at(12, 14, 30))
        XCTAssertEqual(parse("1430"), at(12, 14, 30))
        XCTAssertEqual(parse("7pm"), at(12, 19, 0))
        XCTAssertEqual(parse("7:05 pm"), at(12, 19, 5))
        XCTAssertEqual(parse("12am"), at(13, 0, 0))
        XCTAssertEqual(parse("9:00"), at(13, 9, 0))
        XCTAssertEqual(parse("13:59"), at(13, 13, 59))
    }

    func testRejectsNonsense() {
        for text in ["", "abc", "25:00", "13pm", "0", "10x", "7:5"] { XCTAssertNil(parse(text), text) }
    }

    func testClockAlarmsChooseTheNextOccurrenceAcrossClockChanges() throws {
        let firstPass = try Date.ISO8601FormatStyle().parse("2026-10-25T00:20:00Z")
        let betweenPasses = firstPass.addingTimeInterval(20 * 60)
        let firstRing = try Date.ISO8601FormatStyle().parse("2026-10-25T00:30:00Z")
        let secondRing = firstRing.addingTimeInterval(3600)
        XCTAssertEqual(AlarmTime.parse("02:30", now: firstPass, calendar: calendar), firstRing)
        XCTAssertEqual(AlarmTime.parse("02:30", now: betweenPasses, calendar: calendar), secondRing)
        let beforeSpring = try Date.ISO8601FormatStyle().parse("2027-03-28T00:00:00Z")
        XCTAssertEqual(AlarmTime.parse("02:30", now: beforeSpring, calendar: calendar), beforeSpring.addingTimeInterval(90 * 60))
    }
}

final class EventConflictsTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func event(_ title: String, _ startMinutes: Double, _ minutes: Double, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: title, calendarID: "c", accountID: "a", title: title,
                      start: base.addingTimeInterval(startMinutes * 60), end: base.addingTimeInterval((startMinutes + minutes) * 60), isAllDay: allDay)
    }

    func testDuplicatesBeforeOverlaps() {
        let existing = [event("Standup", 0, 30), event("Dentist – Dr. Novák", 10, 60), event("Lunch", 120, 60)]
        let found = EventConflicts.find(title: "Dentist", start: base.addingTimeInterval(600), end: base.addingTimeInterval(4200),
                                        isAllDay: false, in: existing)
        XCTAssertEqual(found.map(\.kind), [.duplicate, .overlap])
        XCTAssertEqual(found.map(\.event.title), ["Dentist – Dr. Novák", "Standup"])
    }

    func testSameTitleAtAnotherTimeIsOnlyAnOverlap() {
        let found = EventConflicts.find(title: "Zubař", start: base.addingTimeInterval(45 * 60), end: base.addingTimeInterval(105 * 60),
                                        isAllDay: false, in: [event("zubar", 0, 60)])
        XCTAssertEqual(found.map(\.kind), [.overlap])
    }

    func testAllDayOnlyMatchesSimilarAllDay() {
        let existing = [event("Designblok '26", 0, 5 * 1440, allDay: true), event("Holiday", 0, 1440, allDay: true), event("Standup", 30, 30)]
        let found = EventConflicts.find(title: "Designblok 26", start: base, end: base.addingTimeInterval(5 * 86_400), isAllDay: true, in: existing)
        XCTAssertEqual(found.map(\.event.title), ["Designblok '26"])
        XCTAssertTrue(EventConflicts.find(title: "Gym", start: base.addingTimeInterval(7200), end: base.addingTimeInterval(9000),
                                          isAllDay: false, in: existing).isEmpty)
    }
}

final class RepeatRuleTests: XCTestCase {
    func testNormalizesAndRejects() {
        XCTAssertEqual(RepeatRule.normalize("freq=weekly;byday=tu;count=8"), "RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=8")
        XCTAssertEqual(RepeatRule.normalize("RRULE:FREQ=MONTHLY;BYMONTHDAY=1"), "RRULE:FREQ=MONTHLY;BYMONTHDAY=1")
        XCTAssertNil(RepeatRule.normalize("every tuesday"))
        XCTAssertNil(RepeatRule.normalize("FREQ=WEEKLY;X-EVIL=1"))
    }

    func testDescribes() {
        XCTAssertEqual(RepeatRule.describe("FREQ=WEEKLY;BYDAY=TU;COUNT=8"), "Every week on Tue, 8 times")
        XCTAssertEqual(RepeatRule.describe("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"), "Every weekday")
        XCTAssertEqual(RepeatRule.describe("FREQ=MONTHLY;BYMONTHDAY=1"), "Every month on day 1")
        XCTAssertEqual(RepeatRule.describe("FREQ=DAILY;INTERVAL=2"), "Every 2 days")
    }
}
