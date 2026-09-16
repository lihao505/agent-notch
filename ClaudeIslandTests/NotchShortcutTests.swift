// Modified by lihao505 for Agent Notch, 2026.
import CoreGraphics
import KeyboardShortcuts
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchShortcutTests: XCTestCase {
    @MainActor
    private final class LiveState {
        var allowed = false
        var current: NotchViewModel?
        var conflicts: Set<NotchShortcutAction> = []
    }

    private func makeViewModel() -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: CGRect(x: 650, y: 0, width: 212, height: 32),
            screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowHeight: 750, hasPhysicalNotch: true
        )
    }

    private func drainEvents() async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func testShortcutHasNoDefaultCombination() async {
        for action in NotchShortcutAction.allCases {
            XCTAssertNil(action.name.defaultShortcut)
        }
    }

    func testOneListenerAndOneToggleOnRelease() async throws {
        let (stream, continuation) = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
        var subscriptions = 0
        var toggles = 0
        let controller = NotchShortcutController(
            actions: [.toggle], events: { _ in subscriptions += 1; return stream },
            canPerform: { _ in true }, perform: { _ in toggles += 1 }
        )
        defer { controller.stop(); continuation.finish() }
        controller.start()
        controller.start()
        continuation.yield(.keyDown)
        continuation.yield(.keyDown)
        try await drainEvents()
        XCTAssertEqual(subscriptions, 1)
        XCTAssertEqual(toggles, 0)
        continuation.yield(.keyUp)
        try await drainEvents()
        XCTAssertEqual(toggles, 1)
    }

    func testBlockedEventIsNotReplayedAfterAvailabilityReturns() async throws {
        let (stream, continuation) = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
        let state = LiveState()
        var toggles = 0
        let controller = NotchShortcutController(
            actions: [.toggle], events: { _ in stream }, canPerform: { _ in state.allowed }, perform: { _ in toggles += 1 }
        )
        defer { controller.stop(); continuation.finish() }
        controller.start()
        continuation.yield(.keyUp)
        try await drainEvents()
        state.allowed = true
        try await drainEvents()
        XCTAssertEqual(toggles, 0)
        continuation.yield(.keyUp)
        try await drainEvents()
        XCTAssertEqual(toggles, 1)
    }

    func testStopRejectsBufferedEventsAndRestartUsesNewStream() async throws {
        let first = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
        let second = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
        var subscriptions = 0
        var toggles = 0
        let controller = NotchShortcutController(
            actions: [.toggle], events: { _ in
                subscriptions += 1
                return subscriptions == 1 ? first.stream : second.stream
            }, canPerform: { _ in true }, perform: { _ in toggles += 1 }
        )
        defer { controller.stop(); first.continuation.finish(); second.continuation.finish() }
        controller.start()
        first.continuation.yield(.keyUp)
        controller.stop()
        controller.start()
        first.continuation.yield(.keyUp)
        try await drainEvents()
        XCTAssertEqual(toggles, 0)
        second.continuation.yield(.keyUp)
        try await drainEvents()
        XCTAssertEqual(subscriptions, 2)
        XCTAssertEqual(toggles, 1)
    }

    func testCallbackResolvesCurrentWindowInsteadOfRetiredViewModel() async throws {
        let first = makeViewModel()
        let second = makeViewModel()
        let state = LiveState()
        state.current = first
        let (stream, continuation) = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
        let controller = NotchShortcutController(
            actions: [.toggle], events: { _ in stream }, canPerform: { _ in true }, perform: { _ in state.current?.toggleFromKeyboard() }
        )
        defer { controller.stop(); continuation.finish() }
        controller.start()
        state.current = second
        continuation.yield(.keyUp)
        try await drainEvents()
        XCTAssertEqual(first.status, .closed)
        XCTAssertEqual(second.status, .opened)
    }

    func testKeyboardOpenIsImmediateAndNotHoverOwned() async {
        let model = makeViewModel()
        model.toggleFromKeyboard()
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.openReason, .keyboard)
        XCTAssertTrue(model.openReason.isUserInitiated)
        XCTAssertFalse(NotchViewModel.shouldAutoCollapseOnPointerExit(
            isHovering: false, status: model.status,
            openReason: model.openReason, collapseOnMouseLeave: true
        ))
        XCTAssertFalse(NotchViewModel.shouldPerformDeferredHoverOpen(
            isHovering: true, status: model.status, expandOnHover: true
        ))
    }

    func testToggleFromPoppingAndRapidCloseOpen() async {
        let model = makeViewModel()
        model.notchPop()
        model.toggleFromKeyboard()
        XCTAssertEqual(model.status, .opened)
        let oldGeneration = model.presentationGeneration
        model.toggleFromKeyboard()
        XCTAssertEqual(model.status, .closed)
        XCTAssertFalse(model.canDeliverDeferredFocus(generation: oldGeneration))
        model.toggleFromKeyboard()
        XCTAssertEqual(model.status, .opened)
        XCTAssertFalse(model.canDeliverDeferredFocus(generation: oldGeneration))
        XCTAssertTrue(model.canDeliverDeferredFocus(generation: model.presentationGeneration))
    }

    func testKeyboardToggleRestoresSameConversation() async {
        let model = makeViewModel()
        let session = SessionState(sessionId: "keyboard-draft", cwd: "/tmp/project")
        model.notchOpen(reason: .click)
        model.showChat(for: session)
        model.toggleFromKeyboard()
        XCTAssertEqual(model.contentType, .instances)
        model.toggleFromKeyboard()
        XCTAssertEqual(model.contentType, .chat(session))
        XCTAssertEqual(model.openReason, .keyboard)
    }

    func testNewApprovalDoesNotDowngradeKeyboardOwnership() async {
        let model = makeViewModel()
        model.toggleFromKeyboard()
        let generation = model.presentationGeneration
        model.showApproval(for: SessionState(sessionId: "approval", cwd: "/tmp/project"))
        XCTAssertEqual(model.openReason, .keyboard)
        XCTAssertFalse(model.canDeliverDeferredFocus(generation: generation))
    }

    func testLateBootCannotOverrideKeyboardOpenOrExplicitClose() async {
        let model = makeViewModel()
        model.toggleFromKeyboard()
        model.performBootAnimation()
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.openReason, .keyboard)
        model.toggleFromKeyboard()
        model.performBootAnimation()
        XCTAssertEqual(model.status, .closed)
    }

    func testConflictDetectionOnlyPausesSharedCombinations() async {
        let shared = KeyboardShortcuts.Shortcut(.a, modifiers: [.command, .control])
        let different = KeyboardShortcuts.Shortcut(.b, modifiers: [.command, .control])
        XCTAssertTrue(NotchShortcutConflictPolicy.conflictingActions(in: [:]).isEmpty)
        XCTAssertTrue(NotchShortcutConflictPolicy.conflictingActions(in: [.toggle: shared]).isEmpty)
        XCTAssertEqual(NotchShortcutConflictPolicy.conflictingActions(in: [
            .toggle: shared, .nextSession: shared, .previousSession: different
        ]), [.toggle, .nextSession])
        XCTAssertTrue(NotchShortcutConflictPolicy.conflictingActions(in: [
            .toggle: shared, .previousSession: different
        ]).isEmpty)
    }

    func testAllActionsDispatchIndependentlyAndStopTogether() async throws {
        var continuations: [NotchShortcutAction: AsyncStream<KeyboardShortcuts.EventType>.Continuation] = [:]
        var performed: [NotchShortcutAction] = []
        let state = LiveState()
        state.conflicts = [.toggle, .nextSession]
        let controller = NotchShortcutController(events: { action in
            let (stream, continuation) = AsyncStream<KeyboardShortcuts.EventType>.makeStream()
            continuations[action] = continuation
            return stream
        }, canPerform: { !state.conflicts.contains($0) }, perform: { performed.append($0) })
        defer { controller.stop(); continuations.values.forEach { $0.finish() } }
        controller.start()
        controller.start()
        XCTAssertEqual(continuations.count, 3)
        for continuation in continuations.values { continuation.yield(.keyUp) }
        try await drainEvents()
        XCTAssertEqual(performed, [.previousSession])
        state.conflicts = []
        continuations[.nextSession]?.yield(.keyDown)
        continuations[.nextSession]?.yield(.keyUp)
        try await drainEvents()
        XCTAssertEqual(performed, [.previousSession, .nextSession])
        controller.stop()
        for continuation in continuations.values { continuation.yield(.keyUp) }
        try await drainEvents()
        XCTAssertEqual(performed, [.previousSession, .nextSession])
    }
}
