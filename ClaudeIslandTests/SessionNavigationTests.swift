// Modified by lihao505 for Agent Notch, 2026.
import CoreGraphics
import XCTest
@testable import Agent_Notch

@MainActor
final class SessionNavigationTests: XCTestCase {
    private func session(_ id: String, phase: SessionPhase = .processing,
                         date: TimeInterval = 100) -> SessionState {
        SessionState(sessionId: id, cwd: "/tmp/project", phase: phase,
                     lastActivity: Date(timeIntervalSince1970: date))
    }

    private func model(_ sessions: [SessionState]) -> NotchViewModel {
        let model = NotchViewModel(
            deviceNotchRect: CGRect(x: 650, y: 0, width: 212, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750, hasPhysicalNotch: true
        )
        model.navigationSessions = { sessions }
        return model
    }

    func testListOrderHasStableIdentityTieBreaker() async {
        let a = session("a"), b = session("b"), c = session("c")
        XCTAssertEqual(SessionNavigationPolicy.ordered([b, c, a]).map(\.sessionId), ["a", "b", "c"])
        XCTAssertEqual(SessionNavigationPolicy.ordered([c, a, b]).map(\.sessionId), ["a", "b", "c"])
    }

    func testOrderPreservesPriorityAndUserPromptRecency() async {
        var active = session("active", date: 999)
        active.conversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil,
            lastUserMessageDate: Date(timeIntervalSince1970: 1)
        )
        let newerPrompt = session("newer", date: 10)
        let complete = session("done", phase: .waitingForInput, date: 2000)
        let idle = session("idle", phase: .idle, date: 3000)
        XCTAssertEqual(SessionNavigationPolicy.ordered([idle, active, complete, newerPrompt])
            .map(\.sessionId), ["newer", "active", "done", "idle"])
    }

    func testNextAndPreviousWrapAtListEnds() async {
        let sessions = [session("b"), session("a"), session("c")]
        XCTAssertEqual(SessionNavigationPolicy.target(in: sessions, currentID: "c", direction: .next)?.sessionId, "a")
        XCTAssertEqual(SessionNavigationPolicy.target(in: sessions, currentID: "a", direction: .previous)?.sessionId, "c")
    }

    func testMissingOrUnselectedSessionUsesDirectionalBoundary() async {
        let sessions = [session("b"), session("a")]
        for current: String? in [nil, "removed"] {
            XCTAssertEqual(SessionNavigationPolicy.target(in: sessions, currentID: current, direction: .next)?.sessionId, "a")
            XCTAssertEqual(SessionNavigationPolicy.target(in: sessions, currentID: current, direction: .previous)?.sessionId, "b")
        }
    }

    func testEndedSessionsAreNeverNavigationTargets() async {
        let ended = session("ended", phase: .ended)
        XCTAssertNil(SessionNavigationPolicy.target(in: [ended], currentID: nil, direction: .next))
        XCTAssertEqual(SessionNavigationPolicy.target(in: [ended, session("live")], currentID: "ended", direction: .previous)?.sessionId, "live")
    }

    func testEmptyAndSingleSessionCases() async {
        for direction in [SessionNavigationDirection.next, .previous] {
            XCTAssertNil(SessionNavigationPolicy.target(in: [], currentID: "old", direction: direction))
            XCTAssertEqual(SessionNavigationPolicy.target(in: [session("one")], currentID: "one", direction: direction)?.sessionId, "one")
        }
    }

    func testNavigationOpensChatAndClaimsKeyboardOwnership() async {
        let a = session("a"), b = session("b")
        let viewModel = model([b, a])
        viewModel.navigateSessionFromKeyboard(.next)
        XCTAssertEqual(viewModel.status, .opened)
        XCTAssertEqual(viewModel.contentType, .chat(a))
        XCTAssertEqual(viewModel.openReason, .keyboard)
        let oldFocusGeneration = viewModel.presentationGeneration
        viewModel.navigateSessionFromKeyboard(.next)
        XCTAssertEqual(viewModel.contentType, .chat(b))
        XCTAssertFalse(viewModel.canDeliverDeferredFocus(generation: oldFocusGeneration))
    }

    func testCloseThenNavigateDoesNotRestoreOldChatOverTarget() async {
        let a = session("a"), b = session("b")
        let viewModel = model([a, b])
        viewModel.navigateSessionFromKeyboard(.next)
        viewModel.toggleFromKeyboard()
        viewModel.navigateSessionFromKeyboard(.next)
        XCTAssertEqual(viewModel.contentType, .chat(b))
        viewModel.toggleFromKeyboard()
        viewModel.toggleFromKeyboard()
        XCTAssertEqual(viewModel.contentType, .chat(b))
    }

    func testLatestProviderStateWinsOverRegistrationSnapshot() async {
        let a = session("a"), b = session("b"), c = session("c")
        let viewModel = model([a, b])
        viewModel.navigateSessionFromKeyboard(.next)
        viewModel.navigationSessions = { [c, b] }
        viewModel.navigateSessionFromKeyboard(.next)
        XCTAssertEqual(viewModel.contentType, .chat(b))
        viewModel.navigateSessionFromKeyboard(.previous)
        XCTAssertEqual(viewModel.contentType, .chat(c))
    }

    func testEmptyProviderLeavesExistingPresentationUnchanged() async {
        let viewModel = model([])
        viewModel.navigateSessionFromKeyboard(.next)
        XCTAssertEqual(viewModel.status, .closed)
        viewModel.notchOpen(reason: .click)
        viewModel.toggleMenu()
        let generation = viewModel.presentationGeneration
        viewModel.navigateSessionFromKeyboard(.previous)
        XCTAssertEqual(viewModel.contentType, .menu)
        XCTAssertEqual(viewModel.openReason, .click)
        XCTAssertEqual(viewModel.presentationGeneration, generation)
    }
}
