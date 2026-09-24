//
//  Modified by lihao505 for Agent Notch, 2026.
//  LifecycleReducerTests.swift
//  ClaudeIslandTests
//

import XCTest
@testable import Agent_Notch

final class LifecycleReducerTests: XCTestCase {
    private let staleInterval: TimeInterval = 600
    private let missingGrace: TimeInterval = 30

    private func observation(
        _ evidence: LifecycleEvidence,
        observedAt: Date,
        receivedAt: Date,
        origin: LifecycleObservationOrigin = .codexPolling
    ) -> SessionLifecycleObservation {
        SessionLifecycleObservation(
            sessionId: "codex-session",
            cwd: "/tmp/project",
            source: .codex,
            origin: origin,
            evidence: evidence,
            observedAt: observedAt,
            receivedAt: receivedAt
        )
    }

    private func snapshot(
        phase: SessionPhase = .processing,
        lastActivity: Date,
        lastHookEventAt: Date? = nil,
        turnStartedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> SessionLifecycleSnapshot {
        SessionLifecycleSnapshot(
            source: .codex,
            phase: phase,
            lastActivity: lastActivity,
            createdAt: lastActivity,
            lastHookEventAt: lastHookEventAt,
            turnStartedAt: turnStartedAt,
            completedAt: completedAt
        )
    }

    private func reduce(
        current: SessionLifecycleSnapshot?,
        observation: SessionLifecycleObservation,
        allowCreation: Bool = false
    ) -> LifecycleTransition {
        LifecycleReducer.reduce(
            current: current,
            observation: observation,
            allowCreation: allowCreation,
            activeStaleInterval: staleInterval,
            missingGracePeriod: missingGrace
        )
    }

    func testFreshDiscoveryCreatesProcessingGeneration() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let startedAt = now.addingTimeInterval(-2)
        let transition = reduce(
            current: nil,
            observation: observation(
                .active(
                    turnStartedAt: startedAt,
                    lastEvidenceAt: now.addingTimeInterval(-1)
                ),
                observedAt: now,
                receivedAt: now,
                origin: .codexDiscovery
            ),
            allowCreation: true
        )

        XCTAssertEqual(transition.reason, .discoveredActiveTurn)
        guard case .create(let next) = transition.mutation else {
            return XCTFail("Expected a created lifecycle snapshot")
        }
        XCTAssertEqual(next.phase, .processing)
        XCTAssertEqual(next.turnStartedAt, startedAt)
        XCTAssertNil(next.completedAt)
    }

    func testStaleDiscoveryCannotCreatePhantomWorkingCard() {
        let now = Date(timeIntervalSince1970: 2_000)
        let transition = reduce(
            current: nil,
            observation: observation(
                .active(
                    turnStartedAt: now.addingTimeInterval(-601),
                    lastEvidenceAt: nil
                ),
                observedAt: now.addingTimeInterval(-601),
                receivedAt: now,
                origin: .codexDiscovery
            ),
            allowCreation: true
        )

        XCTAssertEqual(transition.mutation, .none)
        XCTAssertEqual(transition.reason, .staleDiscovery)
    }

    func testCompletedTurnRequiresNewerGenerationToResume() throws {
        let completedAt = Date(timeIntervalSince1970: 3_000)
        let current = snapshot(
            phase: .waitingForInput,
            lastActivity: completedAt,
            turnStartedAt: completedAt.addingTimeInterval(-10),
            completedAt: completedAt
        )

        let delayedEvidence = reduce(
            current: current,
            observation: observation(
                .active(
                    turnStartedAt: completedAt.addingTimeInterval(-10),
                    lastEvidenceAt: completedAt.addingTimeInterval(1)
                ),
                observedAt: completedAt.addingTimeInterval(1),
                receivedAt: completedAt.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(delayedEvidence.mutation, .none)
        XCTAssertEqual(delayedEvidence.reason, .activeWithoutNewGeneration)

        let nextTurnAt = completedAt.addingTimeInterval(3)
        let resumed = reduce(
            current: current,
            observation: observation(
                .active(
                    turnStartedAt: nextTurnAt,
                    lastEvidenceAt: nextTurnAt
                ),
                observedAt: nextTurnAt,
                receivedAt: nextTurnAt
            )
        )
        XCTAssertEqual(resumed.reason, .newerTurnStarted)
        guard case .update(let next) = resumed.mutation else {
            return XCTFail("Expected the new generation to resume")
        }
        XCTAssertEqual(next.phase, .processing)
        XCTAssertEqual(next.turnStartedAt, nextTurnAt)
        XCTAssertNil(next.completedAt)
    }

    func testLateCompletionCannotCrossNewerHookBoundary() {
        let now = Date(timeIntervalSince1970: 4_000)
        let current = snapshot(
            lastActivity: now,
            lastHookEventAt: now,
            turnStartedAt: now
        )
        let transition = reduce(
            current: current,
            observation: observation(
                .completed(now.addingTimeInterval(-1)),
                observedAt: now,
                receivedAt: now
            )
        )

        XCTAssertEqual(transition.mutation, .none)
        XCTAssertEqual(transition.reason, .completionOlderThanHook)
    }

    func testLateCompletionCannotCrossNewerNativeTurnBoundary() {
        let now = Date(timeIntervalSince1970: 5_000)
        let current = snapshot(
            lastActivity: now,
            turnStartedAt: now
        )
        let transition = reduce(
            current: current,
            observation: observation(
                .completed(now.addingTimeInterval(-1)),
                observedAt: now,
                receivedAt: now
            )
        )

        XCTAssertEqual(transition.mutation, .none)
        XCTAssertEqual(transition.reason, .completionOlderThanTurn)
    }

    func testNativeCompletionProducesExactBoundary() throws {
        let startedAt = Date(timeIntervalSince1970: 6_000)
        let completedAt = startedAt.addingTimeInterval(5)
        let transition = reduce(
            current: snapshot(
                lastActivity: startedAt,
                turnStartedAt: startedAt
            ),
            observation: observation(
                .completed(completedAt),
                observedAt: completedAt,
                receivedAt: completedAt.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(transition.reason, .nativeCompletion)
        guard case .update(let next) = transition.mutation else {
            return XCTFail("Expected a completed snapshot")
        }
        XCTAssertEqual(next.phase, .waitingForInput)
        XCTAssertEqual(next.completedAt, completedAt)
        XCTAssertEqual(next.lastActivity, completedAt)
    }

    func testPendingInteractionKeepsPriorityWhileActivityMetadataAdvances() throws {
        let requestAt = Date(timeIntervalSince1970: 7_000)
        let context = PermissionContext(
            toolUseId: "approval",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: requestAt
        )
        let evidenceAt = requestAt.addingTimeInterval(1)
        let transition = reduce(
            current: snapshot(
                phase: .waitingForApproval(context),
                lastActivity: requestAt,
                turnStartedAt: requestAt
            ),
            observation: observation(
                .active(
                    turnStartedAt: requestAt,
                    lastEvidenceAt: evidenceAt
                ),
                observedAt: evidenceAt,
                receivedAt: evidenceAt
            )
        )

        XCTAssertEqual(transition.reason, .interactionHasPriority)
        guard case .update(let next) = transition.mutation else {
            return XCTFail("Expected metadata to advance")
        }
        XCTAssertEqual(next.phase, .waitingForApproval(context))
        XCTAssertEqual(next.lastActivity, evidenceAt)
    }

    func testStaleActiveAndUnknownEvidenceStopInfiniteWorkingState() throws {
        let lastActivity = Date(timeIntervalSince1970: 8_000)
        let now = lastActivity.addingTimeInterval(600)
        let current = snapshot(
            lastActivity: lastActivity,
            turnStartedAt: lastActivity
        )

        let staleActive = reduce(
            current: current,
            observation: observation(
                .active(
                    turnStartedAt: lastActivity,
                    lastEvidenceAt: lastActivity
                ),
                observedAt: lastActivity,
                receivedAt: now
            )
        )
        XCTAssertEqual(staleActive.reason, .staleActiveTimedOut)
        guard case .update(let staleNext) = staleActive.mutation else {
            return XCTFail("Expected stale active state to complete")
        }
        XCTAssertEqual(staleNext.phase, .waitingForInput)
        XCTAssertEqual(staleNext.completedAt, now)

        let unknown = reduce(
            current: current,
            observation: observation(
                .unknown,
                observedAt: now,
                receivedAt: now
            )
        )
        XCTAssertEqual(unknown.reason, .unknownActiveTimedOut)
        guard case .update(let unknownNext) = unknown.mutation else {
            return XCTFail("Expected unknown stale state to complete")
        }
        XCTAssertEqual(unknownNext.phase, .waitingForInput)
        XCTAssertEqual(unknownNext.completedAt, now)
    }

    func testMissingSourceHonorsGraceBeforeRemoval() {
        let lastActivity = Date(timeIntervalSince1970: 9_000)
        let current = snapshot(lastActivity: lastActivity)

        let withinGrace = reduce(
            current: current,
            observation: observation(
                .missing,
                observedAt: lastActivity.addingTimeInterval(10),
                receivedAt: lastActivity.addingTimeInterval(29)
            )
        )
        XCTAssertEqual(withinGrace.mutation, .none)
        XCTAssertEqual(withinGrace.reason, .missingWithinGrace)

        let expired = reduce(
            current: current,
            observation: observation(
                .missing,
                observedAt: lastActivity.addingTimeInterval(31),
                receivedAt: lastActivity.addingTimeInterval(30)
            )
        )
        XCTAssertEqual(expired.mutation, .remove)
        XCTAssertEqual(expired.reason, .sourceMissingBeyondGrace)
    }

    func testTraceCapturesDecisionWithoutConversationContent() {
        let now = Date(timeIntervalSince1970: 10_000)
        let current = snapshot(lastActivity: now)
        let source = observation(
            .completed(now),
            observedAt: now,
            receivedAt: now,
            origin: .codexDiscovery
        )
        let transition = reduce(current: current, observation: source)
        let trace = LifecycleTraceEntry(
            observation: source,
            previous: current,
            transition: transition
        )

        XCTAssertEqual(trace.origin, .codexDiscovery)
        XCTAssertEqual(trace.reason, .nativeCompletion)
        XCTAssertTrue(trace.didMutate)
        XCTAssertEqual(trace.previousPhase, .processing)
        XCTAssertEqual(trace.nextPhase, .waitingForInput)
    }
}
