// Modified by lihao505 for Agent Notch, 2026.
import Foundation

/// Presentation only: never infer lifecycle from the last transcript message.
struct SessionRowPresentation {
    enum Interaction: Equatable {
        case none, toolApproval, question, plan
    }

    enum Status: Equatable {
        case working, compacting, approval, question, plan, ready, completed, idle, ended

        func title(language: AppLanguage) -> String {
            switch self {
            case .working: language.text("Working", "工作中")
            case .compacting: language.text("Compacting", "整理上下文")
            case .approval: language.text("Approval needed", "待审批")
            case .question: language.text("Answer needed", "等待回答")
            case .plan: language.text("Plan review", "待审阅计划")
            case .ready: language.text("Ready", "等待输入")
            case .completed: language.text("Completed", "已完成")
            case .idle: language.text("Idle", "空闲")
            case .ended: language.text("Ended", "已结束")
            }
        }
    }

    let session: SessionState

    var interaction: Interaction {
        guard case .waitingForApproval(let request) = session.phase else { return .none }
        switch request.toolName {
        case "AskUserQuestion": return .question
        case "ExitPlanMode": return .plan
        default: return .toolApproval
        }
    }

    var status: Status {
        switch session.phase {
        case .processing: return .working
        case .compacting: return .compacting
        case .waitingForApproval:
            switch interaction {
            case .question: return .question
            case .plan: return .plan
            default: return .approval
            }
        case .waitingForInput: return session.completedAt == nil ? .ready : .completed
        case .idle: return .idle
        case .ended: return .ended
        }
    }

    var canArchive: Bool {
        session.phase == .idle || session.phase == .waitingForInput
    }

    func activity(language: AppLanguage) -> String {
        switch interaction {
        case .question:
            return language.text("Open the question to choose your answer", "打开问题，选择或填写你的回答")
        case .plan:
            return language.text("Review the plan before allowing execution", "查看完整计划，再决定是否执行")
        case .toolApproval:
            let tool = MCPToolFormatter.formatToolName(session.pendingToolName ?? "Tool")
            return [tool, session.pendingToolInput].compactMap { $0 }.joined(separator: " · ")
        case .none:
            let message = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                if session.lastMessageRole == "tool", let tool = session.lastToolName {
                    return "\(MCPToolFormatter.formatToolName(tool)) · \(message)"
                }
                if session.lastMessageRole == "user" {
                    return language.text("You: ", "你：") + message
                }
                return message
            }
            return language.text("Open the conversation to continue", "打开原会话继续")
        }
    }
}

/// Shared with the window sizing policy so taller, readable rows remain inside
/// the hit-test surface; overflowing sessions scroll instead of being clipped.
enum SessionListMetrics {
    static let rowHeight: CGFloat = 96
    static let headingHeight: CGFloat = 28
    static let verticalInset: CGFloat = 4
    static let emptyHeight: CGFloat = 110

    static func contentHeight(sessionCount: Int) -> CGFloat {
        guard sessionCount > 0 else { return emptyHeight }
        return headingHeight + 2 * verticalInset + CGFloat(sessionCount) * rowHeight
    }
}
