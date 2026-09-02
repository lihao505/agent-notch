import XCTest
@testable import Agent_Notch

final class AgentTransportTests: XCTestCase {
    func testSourceRoutesToExpectedTransport() {
        XCTAssertEqual(AgentTransportRouter.kind(for: .codex), .codexCLI)
        XCTAssertEqual(
            AgentTransportRouter.kind(for: .codebuddy),
            .codeBuddyCLI
        )
        XCTAssertEqual(AgentTransportRouter.kind(for: .claude), .tmux)
        XCTAssertEqual(AgentTransportRouter.kind(for: .gemini), .tmux)
        XCTAssertEqual(AgentTransportRouter.kind(for: .cursor), .tmux)
        XCTAssertEqual(AgentTransportRouter.kind(for: .unknown), .tmux)
    }

    func testCodexResumeArgumentsKeepExactSessionIdentity() {
        XCTAssertEqual(
            CodexCLITransport.arguments(sessionId: "codex-session-A"),
            [
                "exec", "resume",
                "--all",
                "--skip-git-repo-check",
                "codex-session-A",
                "-"
            ]
        )
    }

    func testCodeBuddyResumeArgumentsKeepExactSessionIdentity() {
        XCTAssertEqual(
            CodeBuddyCLITransport.arguments(sessionId: "codebuddy-session-B"),
            [
                "--resume", "codebuddy-session-B",
                "--print",
                "--output-format", "text"
            ]
        )
    }
}
