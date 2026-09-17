// Modified by lihao505 for Agent Notch, 2026.
import CoreGraphics
import XCTest
@testable import Agent_Notch

@MainActor
final class SessionRowPresentationTests: XCTestCase {
    private func request(
        _ tool: String,
        input: [String: AnyCodable]? = nil
    ) -> SessionPhase {
        .waitingForApproval(PermissionContext(
            toolUseId: "row-request", toolName: tool, toolInput: input,
            receivedAt: Date(timeIntervalSince1970: 100)
        ))
    }

    private func presentation(
        phase: SessionPhase = .processing,
        completedAt: Date? = nil,
        message: String? = nil,
        role: String? = nil,
        tool: String? = nil
    ) -> SessionRowPresentation {
        SessionRowPresentation(session: SessionState(
            sessionId: "row-session", cwd: "/tmp/row-presentation", phase: phase,
            conversationInfo: ConversationInfo(
                summary: nil, lastMessage: message, lastMessageRole: role,
                lastToolName: tool, firstUserMessage: nil, lastUserMessageDate: nil
            ),
            completedAt: completedAt
        ))
    }

    func testNonApprovalPhasesNeverExposeApprovalInteractions() async {
        for phase: SessionPhase in [.processing, .compacting, .waitingForInput, .idle, .ended] {
            let row = presentation(phase: phase, message: "Old question", role: "tool", tool: "AskUserQuestion")
            XCTAssertEqual(row.interaction, .none, "Phase: \(phase)")
        }
    }

    func testQuestionsAndPlansCannotBeClassifiedAsOrdinaryApproval() async {
        let question = presentation(phase: request("AskUserQuestion"))
        let plan = presentation(phase: request("ExitPlanMode"))
        XCTAssertEqual(question.interaction, .question)
        XCTAssertEqual(plan.interaction, .plan)
        XCTAssertNotEqual(question.interaction, .toolApproval)
        XCTAssertNotEqual(plan.interaction, .toolApproval)

        for tool in ["Bash", "Read", "mcp__service__custom_tool", "UnknownTool"] {
            XCTAssertEqual(presentation(phase: request(tool)).interaction, .toolApproval, tool)
        }
    }

    func testEveryPhaseHasAnExplicitStatus() async {
        let cases: [(SessionPhase, SessionRowPresentation.Status)] = [
            (.processing, .working),
            (.compacting, .compacting),
            (request("Bash"), .approval),
            (request("AskUserQuestion"), .question),
            (request("ExitPlanMode"), .plan),
            (.waitingForInput, .ready),
            (.idle, .idle),
            (.ended, .ended),
        ]
        for (phase, expected) in cases {
            XCTAssertEqual(presentation(phase: phase).status, expected, "Phase: \(phase)")
        }
    }

    func testCompletionEvidenceOnlyChangesWaitingForInputStatus() async {
        let completedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(presentation(phase: .waitingForInput).status, .ready)
        XCTAssertEqual(presentation(phase: .waitingForInput, completedAt: completedAt).status, .completed)

        let cases: [(SessionPhase, SessionRowPresentation.Status)] = [
            (.processing, .working), (.compacting, .compacting),
            (request("Bash"), .approval), (request("AskUserQuestion"), .question),
            (request("ExitPlanMode"), .plan), (.idle, .idle), (.ended, .ended),
        ]
        for (phase, expected) in cases {
            XCTAssertEqual(presentation(phase: phase, completedAt: completedAt).status, expected,
                           "Old completion evidence must not override \(phase)")
        }
    }

    func testOldTranscriptCannotOverrideAuthoritativeStatus() async {
        for role in ["assistant", "user", "tool"] {
            XCTAssertEqual(presentation(phase: .processing, message: "Completed", role: role).status, .working)
            XCTAssertEqual(presentation(phase: .waitingForInput, message: "Working", role: role).status, .ready)
            XCTAssertEqual(presentation(phase: request("AskUserQuestion"), message: "Approved", role: role).status, .question)
            XCTAssertEqual(presentation(phase: request("ExitPlanMode"), message: "Completed", role: role).status, .plan)
        }
    }

    func testQuestionActivityOverridesOldMessagesInBothLanguages() async {
        let row = presentation(phase: request("AskUserQuestion"), message: "Old command output", role: "tool", tool: "Bash")
        XCTAssertEqual(row.activity(language: .english), "Open the question to choose your answer")
        XCTAssertEqual(row.activity(language: .simplifiedChinese), "打开问题，选择或填写你的回答")
    }

    func testPlanActivityOverridesOldMessagesInBothLanguages() async {
        let row = presentation(phase: request("ExitPlanMode"), message: "Previous reply", role: "assistant")
        XCTAssertEqual(row.activity(language: .english), "Review the plan before allowing execution")
        XCTAssertEqual(row.activity(language: .simplifiedChinese), "查看完整计划，再决定是否执行")
    }

    func testToolApprovalActivityUsesCurrentRequestNotTranscript() async {
        let row = presentation(
            phase: request("Bash", input: ["command": AnyCodable("swift test")]),
            message: "Old search", role: "tool", tool: "WebSearch"
        )
        for language in AppLanguage.allCases {
            XCTAssertEqual(row.activity(language: language), "Bash · swift test")
            XCTAssertEqual(presentation(phase: request("Bash")).activity(language: language), "Bash")
        }
    }

    func testUserActivityTrimsWhitespaceAndLocalizesPrefix() async {
        let row = presentation(message: " \n继续优化\t ", role: "user")
        XCTAssertEqual(row.activity(language: .english), "You: 继续优化")
        XCTAssertEqual(row.activity(language: .simplifiedChinese), "你：继续优化")
    }

    func testToolActivityUsesExistingFormatterAndTrimmedMessage() async {
        let row = presentation(message: "  awaiting result\n", role: "tool", tool: "AgentOutputTool")
        XCTAssertEqual(row.activity(language: .english), "Await Agent · awaiting result")
        XCTAssertEqual(row.activity(language: .simplifiedChinese), "Await Agent · awaiting result")
    }

    func testAssistantUnknownAndMissingRolesPreserveMessageText() async {
        for role: String? in ["assistant", "unknown", nil] {
            let row = presentation(message: " \nA useful answer\n ", role: role)
            XCTAssertEqual(row.activity(language: .english), "A useful answer")
            XCTAssertEqual(row.activity(language: .simplifiedChinese), "A useful answer")
        }
    }

    func testBlankOrMissingActivityHasLocalizedFallback() async {
        for message: String? in [nil, "", " \n\t "] {
            let row = presentation(message: message, role: "tool", tool: "Bash")
            XCTAssertEqual(row.activity(language: .english), "Open the conversation to continue")
            XCTAssertEqual(row.activity(language: .simplifiedChinese), "打开原会话继续")
        }
    }

    func testAllStatusesHaveDistinctEnglishAndChineseTitles() async {
        let cases: [(SessionRowPresentation.Status, String, String)] = [
            (.working, "Working", "工作中"),
            (.compacting, "Compacting", "整理上下文"),
            (.approval, "Approval needed", "待审批"),
            (.question, "Answer needed", "等待回答"),
            (.plan, "Plan review", "待审阅计划"),
            (.ready, "Ready", "等待输入"),
            (.completed, "Completed", "已完成"),
            (.idle, "Idle", "空闲"),
            (.ended, "Ended", "已结束"),
        ]
        for (status, english, chinese) in cases {
            XCTAssertEqual(status.title(language: .english), english)
            XCTAssertEqual(status.title(language: .simplifiedChinese), chinese)
        }
        XCTAssertEqual(Set(cases.map { $0.0.title(language: .english) }).count, cases.count)
        XCTAssertEqual(Set(cases.map { $0.0.title(language: .simplifiedChinese) }).count, cases.count)
    }

    func testArchivingRemainsLimitedToIdleAndWaitingForInput() async {
        let completedAt = Date(timeIntervalSince1970: 200)
        for completion: Date? in [nil, completedAt] {
            XCTAssertTrue(presentation(phase: .idle, completedAt: completion).canArchive)
            XCTAssertTrue(presentation(phase: .waitingForInput, completedAt: completion).canArchive)
            for phase: SessionPhase in [
                .processing, .compacting, .ended,
                request("Bash"), request("AskUserQuestion"), request("ExitPlanMode"),
            ] {
                XCTAssertFalse(presentation(phase: phase, completedAt: completion).canArchive,
                               "Phase: \(phase)")
            }
        }
    }

    func testEmptyAndInvalidListCountsUseEmptyHeight() async {
        XCTAssertEqual(SessionListMetrics.emptyHeight, 110)
        XCTAssertEqual(SessionListMetrics.contentHeight(sessionCount: 0), SessionListMetrics.emptyHeight)
        XCTAssertEqual(SessionListMetrics.contentHeight(sessionCount: -1), SessionListMetrics.emptyHeight)
    }

    func testListHeightIncludesHeadingInsetsAndEveryRow() async {
        XCTAssertGreaterThan(SessionListMetrics.rowHeight, 0)
        let chrome = SessionListMetrics.headingHeight + 2 * SessionListMetrics.verticalInset
        XCTAssertEqual(SessionListMetrics.contentHeight(sessionCount: 1), chrome + SessionListMetrics.rowHeight)
        XCTAssertGreaterThan(SessionListMetrics.contentHeight(sessionCount: 1), SessionListMetrics.emptyHeight)
        for count in [2, 3, 10, 100] {
            let height = SessionListMetrics.contentHeight(sessionCount: count)
            let previous = SessionListMetrics.contentHeight(sessionCount: count - 1)
            XCTAssertEqual(height - previous, SessionListMetrics.rowHeight)
            XCTAssertEqual(height, chrome + CGFloat(count) * SessionListMetrics.rowHeight)
        }
    }
}
