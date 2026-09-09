//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchPresentationTimingTests.swift
//  ClaudeIslandTests
//

import CoreGraphics
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchPresentationTimingTests: XCTestCase {
    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 650, y: 0, width: 212, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750,
            hasPhysicalNotch: true
        )
    }

    func testDeferredHoverCannotReplaceAlreadyOpenedClickPresentation() async {
        XCTAssertFalse(
            NotchViewModel.shouldPerformDeferredHoverOpen(
                isHovering: true,
                status: .opened,
                expandOnHover: true
            )
        )
    }

    func testDeferredHoverRequiresPointerAndPreference() async {
        XCTAssertFalse(
            NotchViewModel.shouldPerformDeferredHoverOpen(
                isHovering: false,
                status: .closed,
                expandOnHover: true
            )
        )
        XCTAssertFalse(
            NotchViewModel.shouldPerformDeferredHoverOpen(
                isHovering: true,
                status: .closed,
                expandOnHover: false
            )
        )
        XCTAssertTrue(
            NotchViewModel.shouldPerformDeferredHoverOpen(
                isHovering: true,
                status: .closed,
                expandOnHover: true
            )
        )
    }

    func testMouseLeaveOnlyCollapsesHoverOwnedPresentation() async {
        XCTAssertTrue(
            NotchViewModel.shouldAutoCollapseOnPointerExit(
                isHovering: false,
                status: .opened,
                openReason: .hover,
                collapseOnMouseLeave: true
            )
        )
        XCTAssertFalse(
            NotchViewModel.shouldAutoCollapseOnPointerExit(
                isHovering: false,
                status: .opened,
                openReason: .click,
                collapseOnMouseLeave: true
            )
        )
        XCTAssertFalse(
            NotchViewModel.shouldAutoCollapseOnPointerExit(
                isHovering: false,
                status: .opened,
                openReason: .notification,
                collapseOnMouseLeave: true
            )
        )
        XCTAssertFalse(
            NotchViewModel.shouldAutoCollapseOnPointerExit(
                isHovering: true,
                status: .opened,
                openReason: .hover,
                collapseOnMouseLeave: true
            )
        )
    }

    func testInteractionClaimsAnAlreadyHoverOpenedPanel() async {
        let viewModel = makeViewModel()
        viewModel.status = .opened
        viewModel.openReason = .hover

        viewModel.claimOpenedPanelInteraction()

        XCTAssertEqual(viewModel.status, .opened)
        XCTAssertEqual(viewModel.openReason, .click)
        XCTAssertFalse(
            NotchViewModel.shouldAutoCollapseOnPointerExit(
                isHovering: false,
                status: viewModel.status,
                openReason: viewModel.openReason,
                collapseOnMouseLeave: true
            )
        )
    }

    func testCompletionIdentityIgnoresMutableProcessMetadata() async {
        let completedAt = Date()
        let first = SessionState(
            sessionId: "completion-generation",
            cwd: "/tmp/project",
            pid: 111,
            phase: .waitingForInput,
            completedAt: completedAt
        )
        let refreshed = SessionState(
            sessionId: "completion-generation",
            cwd: "/tmp/project",
            pid: 222,
            phase: .waitingForInput,
            completedAt: completedAt
        )

        XCTAssertEqual(
            NotchAttentionPolicy.completionToken(for: first),
            NotchAttentionPolicy.completionToken(for: refreshed)
        )
    }

    func testNewCompletionBoundaryCreatesNewAttentionGeneration() async throws {
        let first = SessionState(
            sessionId: "rapid-next-turn",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let second = SessionState(
            sessionId: "rapid-next-turn",
            cwd: "/tmp/project",
            phase: .waitingForInput,
            completedAt: Date(timeIntervalSince1970: 101)
        )

        XCTAssertNotEqual(
            try XCTUnwrap(NotchAttentionPolicy.completionToken(for: first)),
            try XCTUnwrap(NotchAttentionPolicy.completionToken(for: second))
        )
    }

    func testCompletionPresentationRejectsStartupHistoryAndExpiredEvents() async {
        let presentationStartedAt = Date(timeIntervalSince1970: 100)
        let oldToken = NotchCompletionToken(
            sessionId: "old",
            completedAt: Date(timeIntervalSince1970: 99)
        )
        let expiredToken = NotchCompletionToken(
            sessionId: "expired",
            completedAt: Date(timeIntervalSince1970: 101)
        )
        let freshToken = NotchCompletionToken(
            sessionId: "fresh",
            completedAt: Date(timeIntervalSince1970: 109)
        )

        XCTAssertFalse(NotchAttentionPolicy.shouldPresent(
            oldToken,
            presentationStartedAt: presentationStartedAt,
            duration: 8,
            now: Date(timeIntervalSince1970: 102)
        ))
        XCTAssertFalse(NotchAttentionPolicy.shouldPresent(
            expiredToken,
            presentationStartedAt: presentationStartedAt,
            duration: 8,
            now: Date(timeIntervalSince1970: 110)
        ))
        XCTAssertTrue(NotchAttentionPolicy.shouldPresent(
            freshToken,
            presentationStartedAt: presentationStartedAt,
            duration: 8,
            now: Date(timeIntervalSince1970: 110)
        ))
    }

    func testSoundRevalidationRejectsSupersededCompletion() async throws {
        let completedAt = Date()
        let token = NotchCompletionToken(
            sessionId: "sound-race",
            completedAt: completedAt
        )
        let completed = SessionState(
            sessionId: token.sessionId,
            cwd: "/tmp/project",
            phase: .waitingForInput,
            completedAt: completedAt
        )
        let resumed = SessionState(
            sessionId: token.sessionId,
            cwd: "/tmp/project",
            phase: .processing,
            completedAt: nil
        )

        XCTAssertTrue(NotchAttentionPolicy.isStillCurrent(
            token,
            in: [completed]
        ))
        XCTAssertFalse(NotchAttentionPolicy.isStillCurrent(
            token,
            in: [resumed]
        ))
    }
}
