//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchQuietSceneTests.swift
//  ClaudeIslandTests
//


import AppKit
import Combine
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchQuietSceneTests: XCTestCase {
    private struct Harness {
        let monitor: NotchQuietSceneMonitor
        let workspace: NotificationCenter
        let distributed: NotificationCenter
    }

    private func makeHarness(initialScreenLocked: Bool = false) -> Harness {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let monitor = NotchQuietSceneMonitor(
            workspaceNotificationCenter: workspace,
            distributedNotificationCenter: distributed,
            initialScreenLocked: initialScreenLocked
        )
        return Harness(
            monitor: monitor,
            workspace: workspace,
            distributed: distributed
        )
    }

    func testInitialLockStateIsAppliedBeforeNotificationsArrive() {
        let harness = makeHarness(initialScreenLocked: true)

        XCTAssertTrue(harness.monitor.state.isScreenLocked)
        XCTAssertTrue(harness.monitor.state.shouldSuppressAttention)
    }

    func testScreenLockAndUnlockUpdateSceneState() {
        let harness = makeHarness()

        harness.distributed.post(
            name: NotchQuietSceneMonitor.screenLockedNotification,
            object: nil
        )
        XCTAssertTrue(harness.monitor.state.isScreenLocked)

        harness.distributed.post(
            name: NotchQuietSceneMonitor.screenUnlockedNotification,
            object: nil
        )
        XCTAssertEqual(harness.monitor.state, .available)
    }

    func testOverlappingSceneSignalsDoNotUnmutePrematurely() {
        let harness = makeHarness()

        harness.distributed.post(
            name: NotchQuietSceneMonitor.screenLockedNotification,
            object: nil
        )
        harness.workspace.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        harness.distributed.post(
            name: NotchQuietSceneMonitor.screenUnlockedNotification,
            object: nil
        )

        XCTAssertFalse(harness.monitor.state.isScreenLocked)
        XCTAssertTrue(harness.monitor.state.isDisplayAsleep)
        XCTAssertTrue(harness.monitor.state.shouldSuppressAttention)

        harness.workspace.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        XCTAssertEqual(harness.monitor.state, .available)
    }

    func testWakeDoesNotOverrideAnInactiveLoginSession() {
        let harness = makeHarness()

        harness.workspace.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        harness.workspace.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        harness.workspace.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        XCTAssertFalse(harness.monitor.state.isSystemAsleep)
        XCTAssertFalse(harness.monitor.state.isSessionActive)
        XCTAssertTrue(harness.monitor.state.shouldSuppressAttention)

        harness.workspace.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        XCTAssertEqual(harness.monitor.state, .available)
    }

    func testDuplicateSignalsDoNotRepublishUnchangedState() {
        let harness = makeHarness()
        var changeCount = 0
        let cancellable = harness.monitor.objectWillChange.sink {
            changeCount += 1
        }

        harness.distributed.post(
            name: NotchQuietSceneMonitor.screenLockedNotification,
            object: nil
        )
        harness.distributed.post(
            name: NotchQuietSceneMonitor.screenLockedNotification,
            object: nil
        )

        XCTAssertEqual(changeCount, 1)
        withExtendedLifetime(cancellable) {}
    }

    func testSilencePolicyHonorsSceneToggleAndReasonPriority() {
        var state = NotchQuietSceneState.available
        state.isScreenLocked = true
        state.isDisplayAsleep = true

        XCTAssertEqual(
            NotchAttentionSilencePolicy.suppressionReason(
                quietScenesEnabled: true,
                sceneState: state,
                quietHoursEnabled: false,
                quietHoursStartMinute: 0,
                quietHoursEndMinute: 0
            ),
            .screenLocked
        )
        XCTAssertNil(NotchAttentionSilencePolicy.suppressionReason(
            quietScenesEnabled: false,
            sceneState: state,
            quietHoursEnabled: false,
            quietHoursStartMinute: 0,
            quietHoursEndMinute: 0
        ))
    }

    func testSilencePolicyFallsBackToScheduledQuietHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 10,
            hour: 23
        ))!

        XCTAssertEqual(
            NotchAttentionSilencePolicy.suppressionReason(
                quietScenesEnabled: false,
                sceneState: .available,
                quietHoursEnabled: true,
                quietHoursStartMinute: 22 * 60,
                quietHoursEndMinute: 8 * 60,
                at: date,
                calendar: calendar
            ),
            .scheduledQuietHours
        )
    }
}
