// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import Combine
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchQuietHoursMonitorTests: XCTestCase {
    private final class Clock {
        var date: Date
        var calendar: Calendar
        init(_ date: Date, zone: String = "UTC") {
            self.date = date
            calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
        }
    }

    private final class Sleeper {
        var continuations: [CheckedContinuation<Void, Error>] = []
        var onWait: (() -> Void)?
        func wait(_ seconds: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                let callback = onWait
                onWait = nil
                callback?()
            }
        }
        func resumeFirst() { continuations.removeFirst().resume() }
        func releaseAll() {
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testNextBoundaryAcrossMidnightAndExactEdges() async {
        let clock = Clock(date("2026-09-14T21:59:59Z"))
        func next(_ instant: String) -> Date? {
            NotchQuietHoursPolicy.nextRecheckDate(
                enabled: true, startMinute: 22 * 60, endMinute: 8 * 60,
                after: date(instant), calendar: clock.calendar
            )
        }
        XCTAssertEqual(next("2026-09-14T21:59:59Z"), date("2026-09-14T22:00:00Z"))
        XCTAssertEqual(next("2026-09-14T22:00:00Z"), date("2026-09-15T08:00:00Z"))
        XCTAssertEqual(next("2026-09-15T08:00:00Z"), date("2026-09-15T22:00:00Z"))
        XCTAssertNil(NotchQuietHoursPolicy.nextRecheckDate(
            enabled: false, startMinute: 0, endMinute: 60, after: clock.date, calendar: clock.calendar
        ))
        XCTAssertNil(NotchQuietHoursPolicy.nextRecheckDate(
            enabled: true, startMinute: 60, endMinute: 60, after: clock.date, calendar: clock.calendar
        ))
    }

    func testDSTGapAndRepeatedHourHaveRecheckDeadlines() async {
        let clock = Clock(date("2026-03-08T06:59:59Z"), zone: "America/New_York")
        XCTAssertEqual(NotchQuietHoursPolicy.nextRecheckDate(
            enabled: true, startMinute: 150, endMinute: 210,
            after: clock.date, calendar: clock.calendar
        ), date("2026-03-08T07:00:00Z"))
        XCTAssertTrue(NotchQuietHoursPolicy.isQuiet(
            enabled: true, startMinute: 150, endMinute: 210,
            at: date("2026-03-08T07:00:00Z"), calendar: clock.calendar
        ))
        // The first 01:45 boundary has passed; the offset rollback itself
        // exits this interval, then the second 01:45 enters it again.
        XCTAssertEqual(NotchQuietHoursPolicy.nextRecheckDate(
            enabled: true, startMinute: 105, endMinute: 135,
            after: date("2026-11-01T05:50:00Z"), calendar: clock.calendar
        ), date("2026-11-01T06:00:00Z"))
        XCTAssertEqual(NotchQuietHoursPolicy.nextRecheckDate(
            enabled: true, startMinute: 105, endMinute: 135,
            after: date("2026-11-01T06:00:00Z"), calendar: clock.calendar
        ), date("2026-11-01T06:45:00Z"))
    }

    func testBoundaryStopsPlayingAudioWithoutSessionPublicationAndNeverReplays() async {
        final class Sound: NotchSoundPlayback {
            var volume: Float = 1
            var plays = 0
            var stops = 0
            func play() -> Bool { plays += 1; return true }
            func stop() -> Bool { stops += 1; return true }
        }
        let clock = Clock(date("2026-09-14T08:59:59Z"))
        let sleeper = Sleeper()
        let monitor = NotchQuietHoursMonitor(
            systemNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter(),
            now: { clock.date }, calendar: { clock.calendar }, sleep: { try await sleeper.wait($0) }
        )
        let suite = "NotchQuietHoursMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { monitor.stop(); sleeper.releaseAll(); defaults.removePersistentDomain(forName: suite) }
        let sound = Sound()
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in sound }
        let observation = monitor.$isQuiet.dropFirst().sink { quiet in
            player.revalidateAutomaticPlayback(in: [], sceneSuppressed: quiet)
        }
        defer { observation.cancel() }
        let firstWait = expectation(description: "Waiting for start boundary")
        sleeper.onWait = { firstWait.fulfill() }
        monitor.configure(NotchQuietHoursSchedule(enabled: true, startMinute: 540, endMinute: 600))
        await fulfillment(of: [firstWait], timeout: 2)
        XCTAssertTrue(player.playAutomatic(for: .completion))
        let secondWait = expectation(description: "Waiting for end boundary")
        sleeper.onWait = { secondWait.fulfill() }
        clock.date = date("2026-09-14T09:00:00Z")
        sleeper.resumeFirst()
        await fulfillment(of: [secondWait], timeout: 2)
        XCTAssertTrue(monitor.isQuiet)
        XCTAssertEqual(sound.stops, 1)
        XCTAssertEqual(monitor.nextCheckAt, date("2026-09-14T10:00:00Z"))
        let nextDay = expectation(description: "Waiting for next day")
        sleeper.onWait = { nextDay.fulfill() }
        clock.date = date("2026-09-14T10:00:00Z")
        sleeper.resumeFirst()
        await fulfillment(of: [nextDay], timeout: 2)
        XCTAssertFalse(monitor.isQuiet)
        XCTAssertEqual(sound.plays, 1)
    }

    func testClockTimezoneAndWakeNotificationsRecomputeSchedule() async {
        let clock = Clock(date("2026-09-14T08:00:00Z"))
        let system = NotificationCenter()
        let workspace = NotificationCenter()
        let monitor = NotchQuietHoursMonitor(
            systemNotifications: system, workspaceNotifications: workspace,
            now: { clock.date }, calendar: { clock.calendar }
        )
        defer { monitor.stop() }
        monitor.configure(NotchQuietHoursSchedule(enabled: true, startMinute: 540, endMinute: 600))
        XCTAssertFalse(monitor.isQuiet)
        clock.date = date("2026-09-14T09:30:00Z")
        system.post(name: .NSSystemClockDidChange, object: nil)
        XCTAssertTrue(monitor.isQuiet)
        clock.calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        system.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertFalse(monitor.isQuiet)
        XCTAssertEqual(monitor.nextCheckAt, date("2026-09-15T01:00:00Z"))
        clock.date = date("2026-09-15T01:30:00Z")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(monitor.isQuiet)
        monitor.stop()
        clock.date = date("2026-09-15T03:00:00Z")
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertNil(monitor.nextCheckAt)
    }

    func testDisablingCancelsOldBoundaryAndAllDayNeedsNoTimer() async {
        let clock = Clock(date("2026-09-14T08:00:00Z"))
        let sleeper = Sleeper()
        let monitor = NotchQuietHoursMonitor(
            systemNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter(),
            now: { clock.date }, calendar: { clock.calendar }, sleep: { try await sleeper.wait($0) }
        )
        defer { monitor.stop(); sleeper.releaseAll() }
        let waiting = expectation(description: "Old boundary scheduled")
        sleeper.onWait = { waiting.fulfill() }
        monitor.configure(NotchQuietHoursSchedule(enabled: true, startMinute: 540, endMinute: 600))
        await fulfillment(of: [waiting], timeout: 2)
        monitor.configure(NotchQuietHoursSchedule(enabled: false, startMinute: 540, endMinute: 600))
        clock.date = date("2026-09-14T09:30:00Z")
        sleeper.resumeFirst()
        await Task.yield()
        XCTAssertFalse(monitor.isQuiet)
        XCTAssertNil(monitor.nextCheckAt)
        monitor.configure(NotchQuietHoursSchedule(enabled: true, startMinute: 540, endMinute: 540))
        XCTAssertTrue(monitor.isQuiet)
        XCTAssertNil(monitor.nextCheckAt)
    }

    func testRealBoundaryTimerPublishesWithoutExternalEvents() async {
        let clock = Clock(date("2026-09-14T08:59:59Z").addingTimeInterval(0.9))
        var startedAt: Date?
        let monitor = NotchQuietHoursMonitor(
            systemNotifications: NotificationCenter(), workspaceNotifications: NotificationCenter(),
            now: {
                let current = Date()
                if startedAt == nil { startedAt = current }
                return clock.date.addingTimeInterval(current.timeIntervalSince(startedAt!))
            }, calendar: { clock.calendar }
        )
        defer { monitor.stop() }
        let entered = expectation(description: "Actual timer enters quiet interval")
        let observation = monitor.$isQuiet.dropFirst().sink { quiet in
            if quiet { entered.fulfill() }
        }
        defer { observation.cancel() }
        monitor.configure(NotchQuietHoursSchedule(enabled: true, startMinute: 540, endMinute: 600))
        XCTAssertFalse(monitor.isQuiet)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(monitor.isQuiet)
        XCTAssertEqual(monitor.nextCheckAt, date("2026-09-14T10:00:00Z"))
    }
}
