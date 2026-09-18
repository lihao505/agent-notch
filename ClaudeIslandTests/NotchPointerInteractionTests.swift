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
