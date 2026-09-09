//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchPresentationTimingTests.swift
//  ClaudeIslandTests
//

import CoreGraphics
import XCTest
@testable import Agent_Notch

final class NotchPresentationTimingTests: XCTestCase {
    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 650, y: 0, width: 212, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750,
            hasPhysicalNotch: true
        )
    }

    func testDeferredHoverCannotReplaceAlreadyOpenedClickPresentation() {
        XCTAssertFalse(
            NotchViewModel.shouldPerformDeferredHoverOpen(
                isHovering: true,
                status: .opened,
                expandOnHover: true
            )
        )
    }

    func testDeferredHoverRequiresPointerAndPreference() {
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

    func testMouseLeaveOnlyCollapsesHoverOwnedPresentation() {
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

    func testInteractionClaimsAnAlreadyHoverOpenedPanel() {
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
}
