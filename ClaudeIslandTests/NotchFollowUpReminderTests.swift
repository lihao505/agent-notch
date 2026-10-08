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

    func testPanelOpenedDuringLaterFocusProbeSuppressesEntireBatch() async {
        let coordinator = NotchFollowUpReminderCoordinator()
        defer { coordinator.cancelAll() }
        let now = Date()
        var first = interactionSession(sessionId: "a", receivedAt: now)
        first.pid = 101
        var second = interactionSession(sessionId: "b", receivedAt: now)
        second.pid = 102
        var third = interactionSession(sessionId: "c", receivedAt: now)
        third.pid = 103
        let sessions = [first, second, third]
        coordinator.reconcile(sessions: sessions, enabled: true, delay: 60,
                              trackingStartedAt: now, now: now)
        let targets = Set(NotchAttentionPolicy.followUpCandidates(
            in: sessions, completionTrackingStartedAt: now
        ).map(\.target))
        var panelOpen = false
        var probes: [Int] = []
        let eligible = await coordinator.eligibleTargetsForDelivery(
            targets, trackingStartedAt: now, sessions: { sessions },
            isPanelOpen: { panelOpen }, isSilenced: { _ in false },
            isFocused: { pid in
                probes.append(pid)
                await Task.yield()
                if pid == 102 { panelOpen = true }
                return false
            }
        )
        XCTAssertEqual(probes, [101, 102])
        XCTAssertTrue(eligible.isEmpty)
    }

    private func deliveryFixture(
        now: Date,
        firstIsCompletion: Bool = false
    ) -> (NotchFollowUpReminderCoordinator, [SessionState], Set<NotchFollowUpTarget>) {
        let coordinator = NotchFollowUpReminderCoordinator()
        var first = firstIsCompletion
            ? completionSession(sessionId: "a", completedAt: now)
            : interactionSession(sessionId: "a", receivedAt: now)
        first.pid = 101
        var second = interactionSession(sessionId: "b", receivedAt: now)
        second.pid = 102
        let sessions = [first, second]
        coordinator.reconcile(sessions: sessions, enabled: true, delay: 60,
                              trackingStartedAt: now, now: now)
        let targets = Set(NotchAttentionPolicy.followUpCandidates(
            in: sessions, completionTrackingStartedAt: now
        ).map(\.target))
        return (coordinator, sessions, targets)
    }

    func testDeliveryKeepsUnfocusedTargetsAndSkipsOpenPanelWithoutProbing() async {
        let now = Date()
        let (coordinator, sessions, targets) = deliveryFixture(now: now)
        defer { coordinator.cancelAll() }
        var probes: [Int] = []
        let eligible = await coordinator.eligibleTargetsForDelivery(
            targets, trackingStartedAt: now, sessions: { sessions },
            isPanelOpen: { false }, isSilenced: { _ in false },
            isFocused: { pid in
                probes.append(pid)
                await Task.yield()
                return pid == 101
            }
        )
        XCTAssertEqual(probes, [101, 102])
        XCTAssertEqual(Set(eligible.map(\.sessionId)), ["b"])
        probes.removeAll()
        let suppressed = await coordinator.eligibleTargetsForDelivery(
            targets, trackingStartedAt: now, sessions: { sessions },
            isPanelOpen: { true }, isSilenced: { _ in false },
            isFocused: { pid in probes.append(pid); return false }
        )
        XCTAssertTrue(suppressed.isEmpty)
        XCTAssertTrue(probes.isEmpty)
    }

    func testLaterProbeRevalidatesEarlierTargetStateAndSilence() async {
        for silencing in [false, true] {
            let now = Date()
            let (coordinator, initial, targets) = deliveryFixture(now: now)
            var sessions = initial
            var silencedIds: Set<String> = []
            let eligible = await coordinator.eligibleTargetsForDelivery(
                targets, trackingStartedAt: now, sessions: { sessions },
                isPanelOpen: { false },
                isSilenced: { silencedIds.contains($0.sessionId) },
                isFocused: { pid in
                    await Task.yield()
                    if pid == 102 {
                        if silencing {
                            silencedIds.insert("a")
                        } else {
                            // The provider may advance before the coordinator
                            // receives the next reconciliation publication.
                            sessions[0].phase = .processing
                        }
                    }
                    return false
                }
            )
            XCTAssertEqual(Set(eligible.map(\.sessionId)), ["b"])
            coordinator.cancelAll()
        }
    }

    func testAcknowledgingEarlierCompletionDuringLaterProbeSuppressesIt() async throws {
        let now = Date()
        let (coordinator, sessions, targets) = deliveryFixture(now: now, firstIsCompletion: true)
        defer { coordinator.cancelAll() }
        let token = try XCTUnwrap(NotchAttentionPolicy.completionToken(for: sessions[0]))
        let eligible = await coordinator.eligibleTargetsForDelivery(
            targets, trackingStartedAt: now, sessions: { sessions },
            isPanelOpen: { false }, isSilenced: { _ in false },
            isFocused: { pid in
                await Task.yield()
                if pid == 102 { coordinator.acknowledgeCompletions([token]) }
                return false
            }
        )
        XCTAssertEqual(Set(eligible.map(\.sessionId)), ["b"])
    }

    func testDisableDuringLaterProbeSuppressesEntireBatch() async {
        let now = Date()
        let (coordinator, sessions, targets) = deliveryFixture(now: now)
        defer { coordinator.cancelAll() }
        let eligible = await coordinator.eligibleTargetsForDelivery(
            targets, trackingStartedAt: now, sessions: { sessions },
            isPanelOpen: { false }, isSilenced: { _ in false },
            isFocused: { pid in
                await Task.yield()
                if pid == 102 {
                    coordinator.reconcile(sessions: sessions, enabled: false, delay: 60,
                                          trackingStartedAt: now)
                }
                return false
            }
        )
        XCTAssertTrue(eligible.isEmpty)
    }

    func testCancelledLaterProbeDiscardsEarlierQualifiedTargets() async {
        let now = Date()
        let (coordinator, sessions, targets) = deliveryFixture(now: now)
        defer { coordinator.cancelAll() }
        let task = Task { @MainActor in
            await coordinator.eligibleTargetsForDelivery(
                targets, trackingStartedAt: now, sessions: { sessions },
                isPanelOpen: { false }, isSilenced: { _ in false },
                isFocused: { pid in
                    await Task.yield()
                    if pid == 102 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                    return false
                }
            )
        }
        let eligible = await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(eligible.isEmpty)
    }

    func testFinalSynchronousCheckRejectsPanelOpenedAfterResolution() async {
        let now = Date()
        let (coordinator, sessions, targets) = deliveryFixture(now: now)
        defer { coordinator.cancelAll() }
        let resolved = await coordinator.eligibleTargetsForDelivery(
            targets, trackingStartedAt: now, sessions: { sessions },
            isPanelOpen: { false }, isSilenced: { _ in false },
            isFocused: { _ in false }
        )
        XCTAssertEqual(resolved, targets)
        XCTAssertTrue(coordinator.currentDeliveryTargets(
            resolved, trackingStartedAt: now, sessions: sessions,
            isPanelOpen: true, isSilenced: { _ in false }
        ).isEmpty)
        XCTAssertEqual(coordinator.currentDeliveryTargets(
            resolved, trackingStartedAt: now, sessions: sessions,
            isPanelOpen: false, isSilenced: { _ in false }
        ), targets)
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
