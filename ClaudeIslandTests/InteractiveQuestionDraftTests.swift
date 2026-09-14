// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import SwiftUI
import XCTest
@testable import Agent_Notch

@MainActor
final class InteractiveQuestionDraftTests: XCTestCase {
    private func context(id: String = "question-1", text: String = "选择方案？", options: [String] = ["B", "A"], multi: Bool = false) -> PermissionContext {
        PermissionContext(
            toolUseId: id, toolName: "AskUserQuestion",
            toolInput: ["questions": AnyCodable([
                ["question": text, "header": "方案", "multiSelect": multi,
                 "options": options.map { ["label": $0] }] as [String: Any],
                ["question": "补充说明？", "header": "说明", "options": []] as [String: Any]
            ])], receivedAt: Date(timeIntervalSince1970: 100)
        )
    }

    func testReopeningKeepsCustomTextSelectionsAndPage() async {
        let store = InteractiveQuestionDraftStore()
        let prompt = context()
        var card: InteractiveQuestionDraft? = store.draft(sessionId: "session", context: prompt)
        card?.toggleOption("A", at: 0)
        card?.move(by: 1)
        card?.setCustomAnswer("第一行\n第二行 👋", at: 1)
        let originalId = card.map { ObjectIdentifier($0) }
        card = nil // The card is removed when collapsing or switching tasks.
        let reopened = store.draft(sessionId: "session", context: prompt)
        XCTAssertEqual(ObjectIdentifier(reopened), originalId)
        XCTAssertEqual(reopened.currentQuestionIndex, 1)
        XCTAssertEqual(reopened.compiledAnswers, ["选择方案？": "A", "补充说明？": "第一行\n第二行 👋"])
    }

    func testSameToolIdInDifferentSessionsAndNewRequestsAreIsolated() async {
        let store = InteractiveQuestionDraftStore()
        let first = store.draft(sessionId: "A", context: context())
        first.setCustomAnswer("仅属于 A", at: 0)
        let otherSession = store.draft(sessionId: "B", context: context())
        let otherRequest = store.draft(sessionId: "A", context: context(id: "question-2"))
        XCTAssertFalse(first === otherSession)
        XCTAssertFalse(first === otherRequest)
        XCTAssertEqual(otherSession.answer(at: 0), "")
        XCTAssertEqual(otherRequest.answer(at: 0), "")
    }

    func testChangedQuestionOrOptionsCannotReusePriorAnswers() async {
        let store = InteractiveQuestionDraftStore()
        let first = store.draft(sessionId: "A", context: context())
        first.toggleOption("A", at: 0)
        first.move(by: 1)
        let changedOptions = store.draft(sessionId: "A", context: context(options: ["B", "C"]))
        XCTAssertFalse(first === changedOptions)
        XCTAssertEqual(changedOptions.currentQuestionIndex, 0)
        XCTAssertEqual(changedOptions.answer(at: 0), "")
        changedOptions.setCustomAnswer("旧题答案", at: 0)
        let changedQuestion = store.draft(sessionId: "A", context: context(text: "选择部署环境？"))
        XCTAssertEqual(changedQuestion.answer(at: 0), "")
        XCTAssertNil(changedQuestion.compiledAnswers)
    }

    func testQueueRetentionAndResolvedRequestCleanup() async {
        let store = InteractiveQuestionDraftStore()
        let first = context()
        let second = context(id: "question-2")
        let firstDraft = store.draft(sessionId: "A", context: first)
        let queuedDraft = store.draft(sessionId: "A", context: second)
        queuedDraft.setCustomAnswer("排队中的草稿", at: 0)
        var queue = PendingInteractionQueue()
        queue.enqueue(first)
        queue.enqueue(second)
        var session = SessionState(sessionId: "A", cwd: "/tmp/draft-tests", phase: .waitingForApproval(first), pendingInteractions: queue)
        store.reconcile(sessions: [session])
        XCTAssertTrue(store.draft(sessionId: "A", context: second) === queuedDraft)
        session.pendingInteractions.remove(toolUseId: first.toolUseId)
        session.phase = .waitingForApproval(second)
        store.reconcile(sessions: [session])
        XCTAssertTrue(store.draft(sessionId: "A", context: second) === queuedDraft)
        XCTAssertFalse(store.draft(sessionId: "A", context: first) === firstDraft)
        store.reconcile(sessions: [])
        XCTAssertFalse(store.draft(sessionId: "A", context: second) === queuedDraft)
    }

    func testSingleMultiAndCustomAnswersRemainMutuallyExclusive() async {
        let single = InteractiveQuestionDraft(questions: context().interactiveQuestions)
        single.toggleOption("A", at: 0)
        single.toggleOption("B", at: 0)
        XCTAssertEqual(single.answer(at: 0), "B")
        single.setCustomAnswer("  自定义\n下一行  ", at: 0)
        XCTAssertEqual(single.answer(at: 0), "自定义\n下一行")
        XCTAssertEqual(single.selectedAnswers[0], [])
        single.toggleOption("A", at: 0)
        XCTAssertEqual(single.customAnswers[0], "")
        XCTAssertEqual(single.answer(at: 0), "A")
        let multi = InteractiveQuestionDraft(questions: context(multi: true).interactiveQuestions)
        multi.toggleOption("A", at: 0)
        multi.toggleOption("B", at: 0)
        XCTAssertEqual(multi.answer(at: 0), "B, A")
        multi.toggleOption("B", at: 0)
        XCTAssertEqual(multi.answer(at: 0), "A")
        multi.toggleOption("forged", at: 0)
        XCTAssertEqual(multi.answer(at: 0), "A")
    }

    func testCompilationRequiresAllAnswersAndRejectsAmbiguousQuestions() async {
        let questions = context().interactiveQuestions
        let draft = InteractiveQuestionDraft(questions: questions)
        draft.setCustomAnswer(" \n", at: 0)
        XCTAssertNil(draft.compiledAnswers)
        draft.toggleOption("A", at: 0)
        XCTAssertNil(draft.compiledAnswers)
        draft.setCustomAnswer("完成", at: 1)
        XCTAssertNotNil(draft.compiledAnswers)
        let duplicate = InteractiveQuestionDraft(questions: [questions[0], questions[0]])
        duplicate.toggleOption("A", at: 0)
        duplicate.toggleOption("B", at: 1)
        XCTAssertNil(duplicate.compiledAnswers) // No duplicate-key dictionary trap.
        draft.move(by: 50)
        XCTAssertEqual(draft.currentQuestionIndex, 1)
        draft.move(by: -50)
        XCTAssertEqual(draft.currentQuestionIndex, 0)
    }

    func testSubmissionRevalidatesCurrentSchemaAfterAsyncLookup() async {
        let questions = context().interactiveQuestions
        let answers = ["选择方案？": "A", "补充说明？": "完成"]
        XCTAssertTrue(InteractiveQuestionSubmissionPolicy.canSubmit(
            answers, expectedQuestions: questions, currentQuestions: questions
        ))
        XCTAssertFalse(InteractiveQuestionSubmissionPolicy.canSubmit(
            answers, expectedQuestions: questions, currentQuestions: context(options: ["C", "D"]).interactiveQuestions
        ))
        XCTAssertFalse(InteractiveQuestionSubmissionPolicy.canSubmit(
            ["选择方案？": "A"], expectedQuestions: questions, currentQuestions: questions
        ))
        XCTAssertFalse(InteractiveQuestionSubmissionPolicy.canSubmit(
            ["选择方案？": "A", "补充说明？": " \n"], expectedQuestions: questions, currentQuestions: questions
        ))
    }

    func testNativeCardRendersRestoredMultilineDraft() async throws {
        let store = InteractiveQuestionDraftStore()
        let prompt = context()
        let draft = store.draft(sessionId: "render-fixture", context: prompt)
        draft.toggleOption("B", at: 0)
        draft.move(by: 1)
        draft.setCustomAnswer("优先保留现有功能。\n切换任务后继续编辑，不需要重新输入。\n验证多行答案与提交按钮布局。", at: 1)
        let reopened = store.draft(sessionId: "render-fixture", context: prompt)
        let card = StructuredInteractivePromptBar(
            context: prompt, draft: reopened, isInTmux: false,
            focusErrorMessage: nil, onSubmitAnswers: { _ in },
            onApprovePlan: {}, onDeny: {}, onGoToTerminal: {}
        ).frame(width: 440).background(Color.black).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 260)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "question-draft-multiline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
