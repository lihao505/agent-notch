//
//  Modified by lihao505 for Agent Notch, 2026.
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Readable task list with explicit status and request-specific actions.
//

import AppKit
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var preferences = NotchPreferences.shared
    @State private var focusFailureSessionId: String?
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.65))
                .accessibilityHidden(true)
            Text(t("Your tasks appear here", "任务会在这里出现"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(t("Start a conversation in a connected agent.", "在已连接的 Agent 中开始一段会话。"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        SessionNavigationPolicy.ordered(sessionMonitor.instances)
    }

    private var instancesList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(t("Tasks", "任务"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(sortedInstances.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: SessionListMetrics.headingHeight)
            .accessibilityElement(children: .combine)

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(sortedInstances) { session in
                        InstanceRow(
                            session: session,
                            language: preferences.language,
                            focusFailed: focusFailureSessionId == session.sessionId,
                            onFocus: { focusSession(session) },
                            onChat: { openChat(session) },
                            onArchive: { archiveSession(session) },
                            onApprove: { approveSession(session) },
                            onReject: { rejectSession(session) }
                        )
                        .id(session.stableId)
                    }
                }
                .padding(.vertical, SessionListMetrics.verticalInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func t(_ english: String, _ chinese: String) -> String {
        preferences.language.text(english, chinese)
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        focusTask?.cancel()
        focusFailureSessionId = nil

        // Codex Desktop uses the hook session_id as its thread id. Opening this
        // native deep link selects the exact task instead of merely activating
        // the last Codex window.
        if session.source == .codex {
            let allowed = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-_")
            )
            if let encodedId = session.sessionId.addingPercentEncoding(
                withAllowedCharacters: allowed
            ),
               let url = URL(string: "codex://threads/\(encodedId)"),
               NSWorkspace.shared.open(url) {
                return
            }

            // Fallback for Codex builds that do not support thread deep links.
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.openai.codex" }?
                .activate(options: [.activateAllWindows])
            return
        }

        if session.source == .codebuddy {
            if let app = NSWorkspace.shared.runningApplications.first(
                where: { $0.bundleIdentifier == "com.workbuddy.workbuddy-ai" }
            ) {
                app.activate(options: [
                    .activateAllWindows,
                ])
            } else {
                let appURL = URL(fileURLWithPath: "/Applications/WorkBuddy AI.app")
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
            return
        }

        focusTask = Task { @MainActor in
            let focused = await TerminalFocusCoordinator.shared.focus(session)
            guard !Task.isCancelled else { return }

            guard !focused else {
                focusFailureSessionId = nil
                return
            }

            focusFailureSessionId = session.sessionId
            NSSound.beep()

            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  focusFailureSessionId == session.sessionId else { return }
            focusFailureSessionId = nil
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        guard SessionRowPresentation(session: session).interaction == .toolApproval,
              let toolUseId = session.pendingToolId else { return }
        sessionMonitor.approvePermission(
            sessionId: session.sessionId,
            expectedToolUseId: toolUseId
        )
    }

    private func rejectSession(_ session: SessionState) {
        guard let toolUseId = session.pendingToolId else { return }
        sessionMonitor.denyPermission(
            sessionId: session.sessionId,
            expectedToolUseId: toolUseId,
            reason: nil
        )
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let language: AppLanguage
    let focusFailed: Bool
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var isYabaiAvailable = false

    private var presentation: SessionRowPresentation {
        SessionRowPresentation(session: session)
    }

    private var activity: String {
        focusFailed
            ? t("Could not locate terminal. Try opening it directly.", "未定位到终端，请尝试手动打开。")
            : presentation.activity(language: language)
    }

    private var focusLabel: String {
        switch session.source {
        case .codex: t("Open in Codex", "在 Codex 中打开")
        case .codebuddy: t("Open in WorkBuddy", "在 WorkBuddy 中打开")
        default: t("Open in terminal", "在终端中打开")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only the title/activity region navigates externally. The footer
            // contains separate buttons; no parent gesture can approve a tool.
            Button(action: onFocus) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(session.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        statusLabel
                            .fixedSize()
                    }
                    Text(activity)
                        .font(.system(size: 12))
                        .foregroundStyle(focusFailed ? TerminalColors.amber : .white.opacity(0.65))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(focusLabel) · \(session.displayTitle)")
            .accessibilityLabel("\(focusLabel)：\(session.displayTitle)")
            .accessibilityValue("\(presentation.status.title(language: language))，\(activity)")

            HStack(spacing: 8) {
                metadata
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 12)
        .frame(height: SessionListMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(isHovered ? 0.07 : 0))
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            Image(systemName: session.source.symbolName)
                .foregroundStyle(session.source.accentColor)
                .accessibilityHidden(true)
            Text(session.source.displayName)
                .fixedSize()
            if session.projectName != session.displayTitle {
                Text("·").accessibilityHidden(true)
                Text(session.projectName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            if session.usage.totalTokens > 0 {
                Text(session.usage.formattedTotal)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(t("Tokens used", "已用 Token"))
                    .accessibilityLabel("\(t("Tokens used", "已用 Token"))：\(session.usage.formattedTotal)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.65))
        .help("\(session.source.displayName) · \(session.cwd)")
    }

    @ViewBuilder
    private var actions: some View {
        switch presentation.interaction {
        case .question, .plan:
            HStack(spacing: 6) {
                Button(action: onChat) {
                    Label(
                        presentation.interaction == .question
                            ? t("Answer", "回答问题") : t("Review plan", "审阅计划"),
                        systemImage: presentation.interaction == .question
                            ? "text.bubble" : "doc.text"
                    )
                }
                .buttonStyle(TaskRowButtonStyle(prominent: true))
                .help(t("Open inside the notch", "在刘海内查看"))
                if session.isInTmux && isYabaiAvailable {
                    TaskRowIconButton(icon: "arrow.up.forward", label: focusLabel, action: onFocus)
                }
            }
            .id(session.pendingToolId)
        case .toolApproval:
            InlineApprovalButtons(
                language: language,
                onChat: onChat,
                onApprove: onApprove,
                onReject: onReject
            )
            .id(session.pendingToolId)
        case .none:
            HStack(spacing: 6) {
                Button(action: onChat) {
                    Label(t("Details", "详情"), systemImage: "bubble.left")
                }
                .buttonStyle(TaskRowButtonStyle())
                .help(t("View conversation inside the notch", "在刘海内查看会话"))
                if session.isInTmux && isYabaiAvailable {
                    TaskRowIconButton(
                        icon: "arrow.up.forward",
                        label: focusLabel,
                        action: onFocus
                    )
                }
                if presentation.canArchive {
                    TaskRowIconButton(
                        icon: "archivebox",
                        label: t("Archive task", "归档任务"),
                        action: onArchive
                    )
                }
            }
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 5) {
            if presentation.status == .working || presentation.status == .compacting {
                ProcessingSpinner(color: session.source.accentColor)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(presentation.status.title(language: language))
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(statusColor)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch presentation.status {
        case .approval, .question, .plan: TerminalColors.amber
        case .completed: TerminalColors.green
        default: .white.opacity(0.7)
        }
    }

    private var statusSymbol: String {
        switch presentation.status {
        case .approval: "hand.raised"
        case .question: "questionmark.bubble"
        case .plan: "doc.text"
        case .completed: "checkmark.circle"
        case .ready: "bubble.left"
        case .ended: "stop.circle"
        case .idle: "circle.dotted"
        case .working, .compacting: "circle"
        }
    }

    private func t(_ english: String, _ chinese: String) -> String {
        language.text(english, chinese)
    }
}

// MARK: - Task Actions

/// Requests are immediately actionable, without stagger or scale transitions.
/// Identity is supplied by the row so a new request cannot inherit old UI state.
private struct InlineApprovalButtons: View {
    let language: AppLanguage
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TaskRowIconButton(
                icon: "text.magnifyingglass",
                label: language.text("Review request", "查看请求"),
                action: onChat
            )
            Button(language.text("Deny", "拒绝"), action: onReject)
                .buttonStyle(TaskRowButtonStyle())
            Button(language.text("Allow", "允许"), action: onApprove)
                .buttonStyle(TaskRowButtonStyle(prominent: true))
        }
    }
}

private struct TaskRowIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 12)
        }
        .buttonStyle(TaskRowButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct TaskRowButtonStyle: ButtonStyle {
    var prominent = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? .black : .white.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(prominent
                        ? .white.opacity(configuration.isPressed ? 0.7 : 0.94)
                        : .white.opacity(configuration.isPressed ? 0.22 : (isHovered ? 0.17 : 0.09)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
    }
}
