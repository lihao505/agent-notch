// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchPointerInteractionTests: XCTestCase {
    func testHostedTestsCannotPersistApprovalPolicy() async {
        XCTAssertFalse(NotchPreferences.shouldPersistApprovalPolicy(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        ))
        XCTAssertFalse(NotchPreferences.shouldPersistApprovalPolicy(
            environment: Foundation.ProcessInfo.processInfo.environment
        ))
    }

    func testNormalAppRetainsApprovalPolicyPersistence() async {
        XCTAssertTrue(NotchPreferences.shouldPersistApprovalPolicy(environment: [:]))
    }

    private func makeViewModel(_ events: EventMonitors) -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 650, y: 0, width: 212, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750, hasPhysicalNotch: true, events: events
        )
    }

    private func drainEvents() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testClickUsesEventPositionAfterPointerMovesAway() async throws {
        let events = EventMonitors(startMonitors: false)
        let model = makeViewModel(events)
        events.mouseDown.send(CGPoint(x: 756, y: 968))
        events.mouseLocation.send(CGPoint(x: 30, y: 30))
        try await drainEvents()
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.openReason, .click)
    }

    func testOutsideClickClosesOpenedPanel() async throws {
        let events = EventMonitors(startMonitors: false)
        let model = makeViewModel(events)
        model.notchOpen(reason: .click)
        events.mouseDown.send(CGPoint(x: 30, y: 30))
        try await drainEvents()
        XCTAssertEqual(model.status, .closed)
    }

    func testExcludedFullScreenSpaceRejectsOpensAndPreservesChatForReturn() async throws {
        let events = EventMonitors(startMonitors: false)
        let model = makeViewModel(events)
        let session = SessionState(sessionId: "full-screen-return", cwd: "/tmp/test")
        model.notchOpen(reason: .click)
        model.contentType = .chat(session)
        model.notchClose()
        let generation = model.presentationGeneration

        model.canPresentOnCurrentSpace = { false }
        events.mouseDown.send(CGPoint(x: 756, y: 968))
        try await drainEvents()
        model.toggleFromKeyboard()
        model.openFromAccessibility()
        model.notchOpen(reason: .notification)
        XCTAssertEqual(model.status, .closed)
        XCTAssertEqual(model.presentationGeneration, generation)

        model.canPresentOnCurrentSpace = { true }
        model.openFromAccessibility()
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.contentType, .chat(session))
    }

    func testExcludedSpaceRejectsApprovalWithoutReplacingSavedChat() async {
        let model = makeViewModel(EventMonitors(startMonitors: false))
        let original = SessionState(sessionId: "original-chat", cwd: "/tmp/original")
        let approval = SessionState(
            sessionId: "incoming-approval", cwd: "/tmp/approval",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "approval-in-excluded-space", toolName: "Bash",
                toolInput: nil, receivedAt: Date()
            ))
        )
        model.notchOpen(reason: .click)
        model.showChat(for: original)
        model.notchClose()
        let generation = model.presentationGeneration
        let reason = model.openReason
        model.canPresentOnCurrentSpace = { false }

        model.showApproval(for: approval)

        XCTAssertEqual(model.status, .closed)
        XCTAssertEqual(model.contentType, .instances)
        XCTAssertEqual(model.openReason, reason)
        XCTAssertEqual(model.presentationGeneration, generation)
        model.canPresentOnCurrentSpace = { true }
        model.openFromAccessibility()
        XCTAssertEqual(model.contentType, .chat(original))
        // A fresh eligible approval must still use its actionable conversation.
        model.showApproval(for: approval)
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.contentType, .chat(approval))
    }

    func testExcludedSpaceRejectsCompactPop() async {
        let model = makeViewModel(EventMonitors(startMonitors: false))
        model.canPresentOnCurrentSpace = { false }
        let generation = model.presentationGeneration
        model.notchPop()
        XCTAssertEqual(model.status, .closed)
        XCTAssertEqual(model.presentationGeneration, generation)
        model.canPresentOnCurrentSpace = { true }
        model.notchPop()
        XCTAssertEqual(model.status, .popping)
    }

    func testInsideClickClaimsHoverPreviewBeforePointerExit() async throws {
        let events = EventMonitors(startMonitors: false)
        let model = makeViewModel(events)
        model.notchOpen(reason: .hover)
        events.mouseDown.send(CGPoint(x: 756, y: 900))
        events.mouseLocation.send(CGPoint(x: 30, y: 30))
        try await drainEvents()
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.openReason, .click)
        XCTAssertFalse(NotchViewModel.shouldAutoCollapseOnPointerExit(
            isHovering: false, status: model.status,
            openReason: model.openReason, collapseOnMouseLeave: true
        ))
    }

    func testAccessibilityOpenIsIdempotentAndPreservesSettings() async {
        let model = makeViewModel(EventMonitors(startMonitors: false))
        model.openFromAccessibility()
        XCTAssertEqual(model.status, .opened)
        XCTAssertTrue(model.openReason.isUserInitiated)
        model.contentType = .menu
        model.openFromAccessibility()
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.contentType, .menu)
    }

    func testAccessibilityOpenRestoresChatWithoutChangingItOnSecondOpen() async {
        let model = makeViewModel(EventMonitors(startMonitors: false))
        let session = SessionState(sessionId: "ax-restore", cwd: "/tmp/ax-restore")
        model.notchOpen(reason: .click)
        model.contentType = .chat(session)
        model.notchClose()
        model.openFromAccessibility()
        XCTAssertEqual(model.contentType, .chat(session))
        model.openFromAccessibility()
        XCTAssertEqual(model.contentType, .chat(session))
    }

    func testAccessibilityOpenFromPoppingIsExplicit() async {
        let model = makeViewModel(EventMonitors(startMonitors: false))
        model.status = .popping
        model.openFromAccessibility()
        XCTAssertEqual(model.status, .opened)
        XCTAssertTrue(model.openReason.isUserInitiated)
    }

    func testEventLocationUsesQuartzSnapshotAcrossDisplayOrigins() async throws {
        // Construct isolated events; never post them to the user's desktop.
        for point in [CGPoint(x: -600, y: 120), CGPoint(x: 2100, y: -400)] {
            let cgEvent = try XCTUnwrap(CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left
            ))
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            XCTAssertEqual(EventMonitors.screenLocation(of: event), cgEvent.unflippedLocation)
        }
    }
}
