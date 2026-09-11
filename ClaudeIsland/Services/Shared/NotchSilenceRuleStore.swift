//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchSilenceRuleStore.swift
//  ClaudeIsland
//
//  Typed, local-only rules for suppressing automatic session attention.
//

import Combine
import Foundation

nonisolated enum NotchSilenceRuleScope: String, CaseIterable, Codable, Identifiable,
    Sendable {
    case project
    case prompt
    case agent
    case tool

    var id: String { rawValue }
}

nonisolated struct NotchSilenceRule: Codable, Equatable, Identifiable,
    Sendable {
    let id: UUID
    var scope: NotchSilenceRuleScope
    var pattern: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        scope: NotchSilenceRuleScope,
        pattern: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.scope = scope
        self.pattern = pattern
        self.isEnabled = isEnabled
    }
}

/// Privacy-minimized matching input. Values are derived from the live session
/// and never written by the matcher; only a pattern explicitly saved by the
/// user is persisted in UserDefaults.
struct NotchSilenceContext: Equatable, Sendable {
    let projectName: String
    let projectPath: String
    let title: String?
    let initialPrompt: String?
    let agentKey: String
    let agentName: String
    let lastToolName: String?
    let pendingToolName: String?

    nonisolated init(session: SessionState) {
        projectName = session.projectName
        projectPath = session.cwd
        title = session.conversationInfo.summary
        initialPrompt = session.conversationInfo.firstUserMessage
        agentKey = session.source.rawValue
        agentName = session.source.displayName
        lastToolName = session.conversationInfo.lastToolName
        if case .waitingForApproval(let context) = session.phase {
            pendingToolName = context.toolName
        } else {
            pendingToolName = nil
        }
    }

    nonisolated init(
        projectName: String = "",
        projectPath: String = "",
        title: String? = nil,
        initialPrompt: String? = nil,
        agentKey: String = "",
        agentName: String = "",
        lastToolName: String? = nil,
        pendingToolName: String? = nil
    ) {
        self.projectName = projectName
        self.projectPath = projectPath
        self.title = title
        self.initialPrompt = initialPrompt
        self.agentKey = agentKey
        self.agentName = agentName
        self.lastToolName = lastToolName
        self.pendingToolName = pendingToolName
    }

    nonisolated func values(for scope: NotchSilenceRuleScope) -> [String] {
        switch scope {
        case .project:
            return [projectName, projectPath]
        case .prompt:
            return [title, initialPrompt].compactMap { $0 }
        case .agent:
            return [agentKey, agentName]
        case .tool:
            return [lastToolName, pendingToolName].compactMap { $0 }
        }
    }
}

nonisolated enum NotchSilenceRuleMatcher {
    nonisolated static func matchingRule(
        in rules: [NotchSilenceRule],
        for context: NotchSilenceContext
    ) -> NotchSilenceRule? {
        rules.first { rule in
            guard rule.isEnabled,
                  let pattern = NotchSilenceRuleStore.cleanedPattern(
                    rule.pattern
                  ) else {
                return false
            }
            return context.values(for: rule.scope).contains { value in
                value.range(
                    of: pattern,
                    options: [
                        .caseInsensitive,
                        .diacriticInsensitive,
                        .widthInsensitive,
                    ],
                    locale: Locale(identifier: "en_US_POSIX")
                ) != nil
            }
        }
    }

    nonisolated static func isSilenced(
        by rules: [NotchSilenceRule],
        context: NotchSilenceContext
    ) -> Bool {
        matchingRule(in: rules, for: context) != nil
    }

    nonisolated static func matchCount(
        for rule: NotchSilenceRule,
        in contexts: [NotchSilenceContext]
    ) -> Int {
        contexts.reduce(into: 0) { count, context in
            if matchingRule(in: [rule], for: context) != nil {
                count += 1
            }
        }
    }
}

/// Mirrors the useful parts of a typed Defaults key without adding a package
/// for one small Codable collection: one key, one default, observable updates,
/// deterministic validation, and JSON that remains inspectable while debugging.
@MainActor
final class NotchSilenceRuleStore: ObservableObject {
    static let shared = NotchSilenceRuleStore()
    nonisolated static let storageKey = "notchSilenceRules.v1"
    nonisolated static let maximumRuleCount = 50
    nonisolated static let maximumPatternLength = 256

    @Published private(set) var rules: [NotchSilenceRule]

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = NotchSilenceRuleStore.storageKey
    ) {
        self.defaults = defaults
        self.key = key

        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                [NotchSilenceRule].self,
                from: data
              ) else {
            rules = []
            return
        }

        let sanitized = Self.sanitizedRules(decoded)
        rules = sanitized
        if sanitized != decoded {
            Self.persist(sanitized, defaults: defaults, key: key)
        }
    }

    @discardableResult
    func addRule(
        scope: NotchSilenceRuleScope,
        pattern: String
    ) -> Bool {
        guard rules.count < Self.maximumRuleCount,
              let cleaned = Self.cleanedPattern(pattern),
              !contains(scope: scope, pattern: cleaned) else {
            return false
        }

        rules.append(
            NotchSilenceRule(scope: scope, pattern: cleaned)
        )
        persist()
        return true
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }),
              rules[index].isEnabled != isEnabled else {
            return
        }
        rules[index].isEnabled = isEnabled
        persist()
    }

    func removeRule(id: UUID) {
        let oldCount = rules.count
        rules.removeAll { $0.id == id }
        guard rules.count != oldCount else { return }
        persist()
    }

    func contains(
        scope: NotchSilenceRuleScope,
        pattern: String
    ) -> Bool {
        guard let cleaned = Self.cleanedPattern(pattern) else { return false }
        return rules.contains {
            $0.scope == scope &&
                $0.pattern.compare(
                    cleaned,
                    options: [
                        .caseInsensitive,
                        .diacriticInsensitive,
                        .widthInsensitive,
                    ],
                    range: nil,
                    locale: Locale(identifier: "en_US_POSIX")
                ) == .orderedSame
        }
    }

    nonisolated static func cleanedPattern(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumPatternLength else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func sanitizedRules(
        _ input: [NotchSilenceRule]
    ) -> [NotchSilenceRule] {
        var seen: Set<String> = []
        var seenIds: Set<UUID> = []
        var result: [NotchSilenceRule] = []

        for rule in input {
            guard result.count < maximumRuleCount else { break }
            guard let pattern = cleanedPattern(rule.pattern) else { continue }
            let folded = pattern.folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive,
                ],
                locale: Locale(identifier: "en_US_POSIX")
            )
            let identity = "\(rule.scope.rawValue):\(folded)"
            guard seen.insert(identity).inserted else { continue }
            var id = rule.id
            while !seenIds.insert(id).inserted {
                id = UUID()
            }
            result.append(
                NotchSilenceRule(
                    id: id,
                    scope: rule.scope,
                    pattern: pattern,
                    isEnabled: rule.isEnabled
                )
            )
        }
        return result
    }

    private func persist() {
        Self.persist(rules, defaults: defaults, key: key)
    }

    nonisolated private static func persist(
        _ rules: [NotchSilenceRule],
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }
}
