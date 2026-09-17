// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import SwiftUI
import XCTest
@testable import Agent_Notch

/// Offline visual fixtures, never registered with SessionStore or the bridge.
/// Attachments supplement (not replace) installed-app interaction acceptance.
@MainActor
final class SessionRowRenderingTests: XCTestCase {
    func testChineseRowsAtMinimumPanelWidth() async throws {
        try await render(language: .simplifiedChinese, width: 456)
    }

    func testEnglishRowsAtMinimumPanelWidth() async throws {
        try await render(language: .english, width: 456)
    }

    private func render(language: AppLanguage, width: CGFloat) async throws {
        let phases: [SessionPhase] = [
            .processing,
            approval("Bash"),
            approval("AskUserQuestion"),
            approval("ExitPlanMode"),
            .waitingForInput,
            .idle
        ]
        let fixtures = phases.enumerated().map { index, phase in
            SessionState(
                sessionId: "offline-row-fixture-\(index)",
                cwd: "/tmp/agent-notch-visual-fixture/long-project-name-for-layout-testing",
                source: index == 0 ? .codex : .claude,
                phase: phase,
                conversationInfo: ConversationInfo(
                    summary: language.text(
                        "Review the expanded notch layout and preserve existing task routing",
                        "优化刘海展开页布局，保留完整任务标题与现有会话跳转行为"
                    ),
                    lastMessage: language.text(
                        "Checking layout, accessibility labels and request-specific actions.",
                        "正在检查布局、辅助功能标签，以及不同请求对应的操作。"
                    ),
                    lastMessageRole: "assistant", lastToolName: nil,
                    firstUserMessage: nil, lastUserMessageDate: nil
                ),
                completedAt: index == 4 ? Date(timeIntervalSince1970: 100) : nil
            )
        }
        var actionCount = 0
        let action = { actionCount += 1 }
        let rows = VStack(spacing: 0) {
            ForEach(fixtures) { session in
                InstanceRow(
                    session: session, language: language,
                    focusFailed: session.sessionId == "offline-row-fixture-5",
                    onFocus: action, onChat: action, onArchive: action,
                    onApprove: action, onReject: action
                )
            }
        }
        .frame(width: width)
        .background(Color.black)
        .preferredColorScheme(.dark)

        let height = SessionListMetrics.rowHeight * CGFloat(fixtures.count)
        // Give the tree one rendering owner. Hosting it in an offscreen window
        // as well can reuse incomplete cached display regions in snapshots.
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        let rendered = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(CGFloat(rendered.height) / renderer.scale, height, accuracy: 1)
        XCTAssertEqual(CGFloat(rendered.width) / renderer.scale, width, accuracy: 1)
        XCTAssertEqual(actionCount, 0, "Rendering must never execute an action")
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "task-rows-\(language.rawValue)-minimum-width"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func approval(_ tool: String) -> SessionPhase {
        .waitingForApproval(PermissionContext(
            toolUseId: "offline-\(tool)", toolName: tool,
            toolInput: ["command": AnyCodable("swift test --filter SessionRowPresentationTests")],
            receivedAt: Date(timeIntervalSince1970: 100)
        ))
    }
}
