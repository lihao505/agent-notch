//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchQuietHoursPolicyTests.swift
//  ClaudeIslandTests
//

import XCTest
@testable import Agent_Notch

final class NotchQuietHoursPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 10,
            hour: hour,
            minute: minute
        ))!
    }

    private func isQuiet(
        enabled: Bool = true,
        start: Int,
        end: Int,
        hour: Int,
        minute: Int = 0
    ) -> Bool {
        NotchQuietHoursPolicy.isQuiet(
            enabled: enabled,
            startMinute: start,
            endMinute: end,
            at: date(hour: hour, minute: minute),
            calendar: calendar
        )
    }

    func testDisabledScheduleNeverMutes() {
        XCTAssertFalse(isQuiet(
            enabled: false,
            start: 9 * 60,
            end: 17 * 60,
            hour: 12
        ))
    }

    func testSameDayScheduleUsesInclusiveStartAndExclusiveEnd() {
        XCTAssertFalse(isQuiet(start: 9 * 60, end: 17 * 60, hour: 8, minute: 59))
        XCTAssertTrue(isQuiet(start: 9 * 60, end: 17 * 60, hour: 9))
        XCTAssertTrue(isQuiet(start: 9 * 60, end: 17 * 60, hour: 16, minute: 59))
        XCTAssertFalse(isQuiet(start: 9 * 60, end: 17 * 60, hour: 17))
    }

    func testOvernightScheduleSpansMidnight() {
        XCTAssertTrue(isQuiet(start: 22 * 60, end: 8 * 60, hour: 23))
        XCTAssertTrue(isQuiet(start: 22 * 60, end: 8 * 60, hour: 7, minute: 59))
        XCTAssertFalse(isQuiet(start: 22 * 60, end: 8 * 60, hour: 8))
        XCTAssertFalse(isQuiet(start: 22 * 60, end: 8 * 60, hour: 12))
    }

    func testEqualBoundariesMuteAllDay() {
        XCTAssertTrue(isQuiet(start: 10 * 60, end: 10 * 60, hour: 3))
        XCTAssertTrue(isQuiet(start: 10 * 60, end: 10 * 60, hour: 15))
    }

    func testStoredMinutesAreClampedToOneDay() {
        XCTAssertEqual(NotchQuietHoursPolicy.sanitizedMinute(-1), 0)
        XCTAssertEqual(
            NotchQuietHoursPolicy.sanitizedMinute(24 * 60),
            24 * 60 - 1
        )
    }
}
