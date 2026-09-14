//
//  StructuredInteractivePromptBar.swift
//  Modified by lihao505 for Agent Notch, 2026.
//  ClaudeIsland
//
//  Native question answering and plan review inside the notch.
//

import SwiftUI

struct StructuredInteractivePromptBar: View {
    let context: PermissionContext
    @ObservedObject var draft: InteractiveQuestionDraft
    let isInTmux: Bool
    let focusErrorMessage: String?
    let onSubmitAnswers: ([String: String]) -> Void
    let onApprovePlan: () -> Void
    let onDeny: () -> Void
    let onGoToTerminal: () -> Void

    private var currentQuestionIndex: Int { draft.currentQuestionIndex }

    private var questions: [InteractiveQuestion] {
        draft.questions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if context.toolName == "AskUserQuestion", !questions.isEmpty {
                    questionContent
                } else if context.toolName == "ExitPlanMode" {
                    planContent
                } else {
                    terminalFallback
                }
            }

            if let focusErrorMessage {
                Label(focusErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.28))
        .id(context.toolName == "AskUserQuestion" ? ObjectIdentifier(draft) : nil)
    }

    private var questionContent: some View {
        let question = questions[min(currentQuestionIndex, questions.count - 1)]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                AgentInteractionLabel(
                    title: question.header,
                    subtitle: "\(currentQuestionIndex + 1) / \(questions.count)"
                )
                Spacer()
                Text(question.options.isEmpty ? "自定义" : (question.multiSelect ? "可多选" : "单选"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }

            Text(question.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(question.options) { option in
                    optionButton(option, for: question)
                }

                TextField(
                    "其他答案…",
                    text: customAnswerBinding,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("自定义答案")
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                if currentQuestionIndex > 0 {
                    actionButton("上一步", systemImage: "chevron.left", primary: false) {
                        draft.move(by: -1)
                    }
                }
                Spacer()
                actionButton(
                    currentQuestionIndex == questions.count - 1 ? "提交" : "下一步",
                    systemImage: currentQuestionIndex == questions.count - 1
                        ? "paperplane.fill"
                        : "chevron.right",
                    primary: true
                ) {
                    if currentQuestionIndex == questions.count - 1 {
                        if let answers = draft.compiledAnswers { onSubmitAnswers(answers) }
                    } else {
                        draft.move(by: 1)
                    }
                }
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.4)
            }
        }
    }

    private var planContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentInteractionLabel(
                title: "计划审查",
                subtitle: context.planFilePath.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? "Claude Code"
            )

            ScrollView(.vertical, showsIndicators: true) {
                if let plan = context.planContent {
                    MarkdownText(plan, color: .white.opacity(0.88), fontSize: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("计划已准备好。可在终端查看完整内容后批准。")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)

            HStack(spacing: 8) {
                if isInTmux {
                    actionButton("终端", systemImage: "terminal", primary: false) {
                        onGoToTerminal()
                    }
                }
                Spacer()
                actionButton("退回", systemImage: "xmark", primary: false) {
                    onDeny()
                }
                actionButton("批准计划", systemImage: "checkmark", primary: true) {
                    onApprovePlan()
                }
            }
        }
    }

    private var terminalFallback: some View {
        HStack(spacing: 12) {
            AgentInteractionLabel(
                title: context.toolName,
                subtitle: "需要你的输入"
            )
            Spacer()
            actionButton("终端", systemImage: "terminal", primary: true) {
                onGoToTerminal()
            }
            .disabled(!isInTmux)
            .opacity(isInTmux ? 1 : 0.4)
        }
    }

    private func optionButton(
        _ option: InteractiveQuestion.Option,
        for question: InteractiveQuestion
    ) -> some View {
        let isSelected = draft.selectedAnswers[currentQuestionIndex, default: []]
            .contains(option.label)

        return Button {
            draft.toggleOption(option.label, at: currentQuestionIndex)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected
                    ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                    : (question.multiSelect ? "square" : "circle"))
                    .foregroundColor(isSelected ? TerminalColors.green : .white.opacity(0.35))

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected
                ? TerminalColors.green.opacity(0.14)
                : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var customAnswerBinding: Binding<String> {
        let index = currentQuestionIndex
        return Binding(
            get: { draft.customAnswers[index, default: ""] },
            set: { draft.setCustomAnswer($0, at: index) }
        )
    }

    private var canContinue: Bool {
        if currentQuestionIndex == questions.count - 1 { return draft.compiledAnswers != nil }
        return !draft.answer(at: currentQuestionIndex).isEmpty
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary ? .black : .white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(primary ? Color.white.opacity(0.95) : Color.white.opacity(0.09))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct AgentInteractionLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(TerminalColors.amber)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
    }
}
