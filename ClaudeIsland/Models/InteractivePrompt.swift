//
//  InteractivePrompt.swift
//  ClaudeIsland
//
//  Structured input models for Claude Code's interactive tools.
//

import Foundation

struct InteractiveQuestion: Identifiable, Equatable, Sendable {
    struct Option: Identifiable, Equatable, Sendable {
        let label: String
        let description: String?

        var id: String { label }
    }

    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool

    var id: String { question }
}

extension PermissionContext {
    var interactiveQuestions: [InteractiveQuestion] {
        guard toolName == "AskUserQuestion",
              let rawQuestions = toolInput?["questions"]?.value as? [Any] else {
            return []
        }

        return rawQuestions.compactMap { rawQuestion in
            guard let question = rawQuestion as? [String: Any],
                  let text = question["question"] as? String,
                  !text.isEmpty else {
                return nil
            }

            let rawOptions = question["options"] as? [Any] ?? []
            let options = rawOptions.compactMap { rawOption -> InteractiveQuestion.Option? in
                guard let option = rawOption as? [String: Any],
                      let label = option["label"] as? String,
                      !label.isEmpty else {
                    return nil
                }
                return InteractiveQuestion.Option(
                    label: label,
                    description: option["description"] as? String
                )
            }

            return InteractiveQuestion(
                question: text,
                header: (question["header"] as? String) ?? "Question",
                options: options,
                multiSelect: (question["multiSelect"] as? Bool) ?? false
            )
        }
    }

    var planContent: String? {
        guard toolName == "ExitPlanMode", let input = toolInput else {
            return nil
        }
        for key in ["plan", "planContent", "plan_content"] {
            if let content = input[key]?.value as? String, !content.isEmpty {
                return content
            }
        }
        return nil
    }

    var planFilePath: String? {
        guard toolName == "ExitPlanMode", let input = toolInput else {
            return nil
        }
        for key in ["plan_file_path", "planFilePath"] {
            if let path = input[key]?.value as? String, !path.isEmpty {
                return path
            }
        }
        return nil
    }
}
