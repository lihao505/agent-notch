//
//  LifecycleDiagnosticsCoordinatorTests.swift
//  Agent Notch
//

import XCTest
@testable import Agent_Notch

private actor SlowDiagnosticsReader {
    private var calls = 0

    func read() async -> SessionStoreDiagnosticsInput {
        calls += 1
        if calls > 1 {
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        return SessionStoreDiagnosticsInput(sessions: [], decisions: [])
    }
}

@MainActor
final class LifecycleDiagnosticsCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        readSessions: @escaping LifecycleDiagnosticsCoordinator.SessionReader = {
            SessionStoreDiagnosticsInput(sessions: [], decisions: [])
        }
    ) -> LifecycleDiagnosticsCoordinator {
        LifecycleDiagnosticsCoordinator(
            readSessions: readSessions,
            readBridge: {
                DiagnosticsBridgeInput(
                    isRunning: true,
                    socketExists: true,
                    ownsSocket: true,
                    pendingPermissionSessionIds: [],
                    lastEventAt: nil
                )
            },
            readWatchers: { [] },
            now: { Date(timeIntervalSince1970: 2_000) },
            appVersion: { "test" },
            macOSMajorVersion: { 26 }
        )
    }

    func testManualRefreshProducesOnlySafeSnapshot() async throws {
        let coordinator = makeCoordinator(readSessions: {
            SessionStoreDiagnosticsInput(
                sessions: [DiagnosticsSessionInput(
                    sessionId: "raw-secret-session",
                    source: .codex,
                    phase: .processing,
                    hasProcess: true,
                    waitingForPermission: false,
                    lastActivity: Date(timeIntervalSince1970: 1_999)
                )],
                decisions: []
            )
        })

        await coordinator.refresh()

        let snapshot = try XCTUnwrap(coordinator.snapshot)
        XCTAssertEqual(snapshot.health, .healthy)
        XCTAssertEqual(snapshot.sessions.first?.label, "S1")
        XCTAssertEqual(snapshot.sessions.first?.lastActivityAgeMs, 1_000)
        XCTAssertEqual(coordinator.lastRefreshedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertFalse(coordinator.isRefreshing)
        XCTAssertFalse(try DiagnosticsReportFormatter.json(snapshot).contains("raw-secret-session"))
    }

    func testSlowRefreshKeepsPriorSnapshotAndStopDropsLateResult() async throws {
        let reader = SlowDiagnosticsReader()
        let coordinator = makeCoordinator(readSessions: { await reader.read() })
        await coordinator.refresh()
        let first = try XCTUnwrap(coordinator.snapshot)

        let second = Task { await coordinator.refresh() }
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertTrue(coordinator.refreshDelayed)
        XCTAssertEqual(coordinator.snapshot, first)

        coordinator.stop()
        await second.value
        XCTAssertFalse(coordinator.refreshDelayed)
        XCTAssertFalse(coordinator.isRefreshing)
        XCTAssertEqual(coordinator.snapshot, first)
    }

    func testPollingStartIsIdempotentAndStopsAfterLeavingPage() async throws {
        let coordinator = makeCoordinator()
        coordinator.start()
        coordinator.start()
        XCTAssertTrue(coordinator.isPolling)

        let deadline = Date().addingTimeInterval(2)
        while coordinator.snapshot == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(coordinator.snapshot)
        let refreshedAt = coordinator.lastRefreshedAt

        coordinator.stop()
        XCTAssertFalse(coordinator.isPolling)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(coordinator.lastRefreshedAt, refreshedAt)
    }
}
