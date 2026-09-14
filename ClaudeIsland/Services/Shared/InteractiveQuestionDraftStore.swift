// Modified by lihao505 for Agent Notch, 2026.
import Combine
import Foundation

enum InteractiveQuestionSubmissionPolicy {
    static func canSubmit(
        _ answers: [String: String],
        expectedQuestions: [InteractiveQuestion],
        currentQuestions: [InteractiveQuestion]
    ) -> Bool {
        let keys = Set(expectedQuestions.map(\.question))
        return !expectedQuestions.isEmpty && expectedQuestions == currentQuestions &&
            keys.count == expectedQuestions.count && Set(answers.keys) == keys &&
            answers.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// User-entered answers live in memory, separately from transient card views.
/// A draft's schema is immutable so refreshed questions cannot inherit answers
/// intended for a different question or option set.
@MainActor
final class InteractiveQuestionDraft: ObservableObject {
    let questions: [InteractiveQuestion]
    @Published private(set) var selectedAnswers: [Int: Set<String>] = [:]
    @Published private(set) var customAnswers: [Int: String] = [:]
    @Published private(set) var currentQuestionIndex = 0

    init(questions: [InteractiveQuestion]) { self.questions = questions }

    func move(by offset: Int) {
        currentQuestionIndex = min(max(0, currentQuestionIndex + offset), max(0, questions.count - 1))
    }

    func toggleOption(_ label: String, at index: Int) {
        guard questions.indices.contains(index),
              questions[index].options.contains(where: { $0.label == label }) else { return }
        var selected = selectedAnswers[index, default: []]
        if questions[index].multiSelect {
            if selected.contains(label) { selected.remove(label) }
            else { selected.insert(label) }
        } else {
            selected = [label]
        }
        selectedAnswers[index] = selected
        customAnswers[index] = ""
    }

    func setCustomAnswer(_ value: String, at index: Int) {
        guard questions.indices.contains(index) else { return }
        customAnswers[index] = value
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedAnswers[index] = []
        }
    }

    func answer(at index: Int) -> String {
        guard questions.indices.contains(index) else { return "" }
        let custom = customAnswers[index, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        // Follow the option order rather than alphabetically rearranging it.
        return questions[index].options.map(\.label)
            .filter { selectedAnswers[index, default: []].contains($0) }
            .joined(separator: ", ")
    }

    var compiledAnswers: [String: String]? {
        guard !questions.isEmpty,
              Set(questions.map(\.question)).count == questions.count else { return nil }
        var result: [String: String] = [:]
        for index in questions.indices {
            let value = answer(at: index)
            guard !value.isEmpty else { return nil }
            result[questions[index].question] = value
        }
        return result
    }
}

@MainActor
final class InteractiveQuestionDraftStore {
    static let shared = InteractiveQuestionDraftStore()
    private var drafts: [NotchInteractionToken: InteractiveQuestionDraft] = [:]

    func draft(sessionId: String, context: PermissionContext) -> InteractiveQuestionDraft {
        let token = NotchInteractionToken(sessionId: sessionId, toolUseId: context.toolUseId)
        let questions = context.interactiveQuestions
        if let draft = drafts[token], draft.questions == questions { return draft }
        let draft = InteractiveQuestionDraft(questions: questions)
        drafts[token] = draft
        return draft
    }

    /// Use the full authoritative queue, not only the visible head or selected
    /// card. A queued question retains its draft until that request is resolved.
    func reconcile(sessions: [SessionState]) {
        var pending: [NotchInteractionToken: [InteractiveQuestion]] = [:]
        for session in sessions {
            var contexts = session.pendingInteractions.items
            if let active = session.activePermission { contexts.append(active) }
            for context in contexts where context.toolName == "AskUserQuestion" {
                pending[NotchInteractionToken(sessionId: session.sessionId, toolUseId: context.toolUseId)] = context.interactiveQuestions
            }
        }
        drafts = drafts.filter { token, draft in pending[token] == draft.questions }
    }
}
