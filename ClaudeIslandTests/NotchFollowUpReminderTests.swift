//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchFollowUpReminderTests.swift
//  ClaudeIslandTests
//

import XCTest
@testable import Agent_Notch

@MainActor
final class NotchFollowUpReminderTests: XCTestCase {
    private func interactionSession(
        sessionId: String = "interaction",
        toolUseId: String = "tool",
        receivedAt: Date = Date()
    ) -> SessionState {
        SessionState(
            sessionId: sessionId,
            cwd: "/tmp/\(sessionId)",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: toolUseId,
                toolName: "Bash",
                toolInput: nil,
                receivedAt: receivedAt
            ))
        )
    }

    private func completionSession(
        sessionId: String = "completion",
        completedAt: Date = Date()
    ) -> SessionState {
        SessionState(
            sessionId: sessionId,
            cwd: "/tmp/\(sessionId)",
            phase: .waitingForInput,
            completedAt: completedAt
        )
    }

    func testCandidatesKeepPendingStartupInteractionButRejectOldCompletion() {
        let trackingStartedAt = Date()
        let oldDate = trackingStartedAt.addingTimeInterval(-60)
        let newDate = trackingStartedAt.addingTimeInterval(1)

        let candidates = NotchAttentionPolicy.followUpCandidates(
            in: [
                interactionSession(receivedAt: oldDate),
                completionSession(
                    sessionId: "old-completion",
                    completedAt: oldDate
                ),
                completionSession(
                    sessionId: "new-completion",
                    completedAt: newDate
                )
            ],
            completionTrackingStartedAt: trackingStartedAt
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.contains {
            if case .interaction = $0.target { return true }
            return false
        })
        XCTAssertTrue(candidates.contains {
            $0.target.sessionId == "new-completion"
        })
    }

    func testEnablingStartsFullDelayInsteadOfBurstingOldRequest() async throws {
        let coordinator = NotchFollowUpReminderCoordinator()
        let now = Date()
        let session = interactionSession(
            receivedAt: now.addingTimeInterval(-3_600)
        )

        coordinator.reconcile(
            sessions: [session],
            enabled: true,
            delay: 0.1,
            trackingStartedAt: now.addingTimeInterval(-3_600),
            now: now
        )

        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(coordinator.pendingTargets.isEmpty)
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertEqual(coordinator.pendingTargets.count, 1)
        coordinator.cancelAll()
    }

    func testResolvedRequestCancelsScheduledReminder() async throws {
        let coordinator = NotchFollowUpReminderCoordinator()
        let now = Date()
        coordinator.reconcile(
            sessions: [interactionSession(receivedAt: now)],
            enabled: true,
            delay: 0.1,
            trackingStartedAt: now,
            now: now
        )

        coordinator.reconcile(
            sessions: [],
            enabled: true,
            delay: 0.1,
            trackingStartedAt: now,
            now: now.addingTimeInterval(0.02)
        )
        try await Task.sleep(for: .milliseconds(130))

        XCTAssertTrue(coordinator.pendingTargets.isEmpty)
        coordinator.cancelAll()
    }

    func testOpenedCompletionCannotProduceDelayedReminder() async throws {
        let coordinator = NotchFollowUpReminderCoordinator()
        let now = Date()
        let session = completionSession(completedAt: now)
        let token = try XCTUnwrap(
            NotchAttentionPolicy.completionToken(for: session)
        )

        coordinator.reconcile(
            sessions: [session],
            enabled: true,
            delay: 0.1,
            trackingStartedAt: now,
            now: now
        )
        coordinator.acknowledgeCompletions([token])
        try await Task.sleep(for: .milliseconds(130))

        XCTAssertTrue(coordinator.pendingTargets.isEmpty)
        coordinator.cancelAll()
    }

    func testReminderIsDeliveredOncePerExactGeneration() async throws {
        let coordinator = NotchFollowUpReminderCoordinator()
        let now = Date()
        let session = interactionSession(receivedAt: now)

        coordinator.reconcile(
            sessions: [session],
            enabled: true,
            delay: 0.05,
            trackingStartedAt: now,
            now: now
        )
        try await Task.sleep(for: .milliseconds(80))
        let firstDelivery = coordinator.pendingTargets
        XCTAssertEqual(firstDelivery.count, 1)

        coordinator.consume(firstDelivery)
        coordinator.reconcile(
            sessions: [session],
            enabled: true,
            delay: 0.05,
            trackingStartedAt: now,
            now: Date()
        )
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(coordinator.pendingTargets.isEmpty)
        coordinator.cancelAll()
    }

    func testSilencingThenUnmutingDoesNotReplayButNextTurnReminds() async throws {
        let coordinator = NotchFollowUpReminderCoordinator()
        defer { coordinator.cancelAll() }
        let now = Date()
        let muted = completionSession(sessionId: "muted", completedAt: now)
        let normal = completionSession(sessionId: "normal", completedAt: now)
        let rule = NotchSilenceRule(scope: .project, pattern: "muted")
        coordinator.reconcile(
            sessions: [muted, normal], enabled: true, delay: 0.02,
            trackingStartedAt: now, silenceRules: [rule], now: now
        )
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(Set(coordinator.pendingTargets.map(\.sessionId)), ["normal"])
        coordinator.consume(coordinator.pendingTargets)
        coordinator.reconcile(
            sessions: [muted, normal], enabled: true, delay: 0.02,
            trackingStartedAt: now
        )
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(coordinator.pendingTargets.isEmpty)
        let next = completionSession(sessionId: "muted", completedAt: Date())
        coordinator.reconcile(
            sessions: [next, normal], enabled: true, delay: 0.02,
            trackingStartedAt: now
        )
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(Set(coordinator.pendingTargets.map(\.sessionId)), ["muted"])
    }
}
