//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchSilenceRuleTests.swift
//  ClaudeIslandTests
//

import XCTest
@testable import Agent_Notch

final class NotchSilenceRuleMatcherTests: XCTestCase {
    func testProjectRuleMatchesNameOrFullPathCaseInsensitively() {
        let context = NotchSilenceContext(
            projectName: ".Codex",
            projectPath: "/Users/test/Project/Vibe-Notch"
        )

        XCTAssertTrue(isSilenced(.project, pattern: ".codex", context: context))
        XCTAssertTrue(isSilenced(.project, pattern: "vibe-notch", context: context))
        XCTAssertFalse(isSilenced(.project, pattern: "another", context: context))
    }

    func testPromptRuleMatchesTitleOrInitialPrompt() {
        let context = NotchSilenceContext(
            title: "Refresh generated snapshots",
            initialPrompt: "Please run the nightly benchmark suite"
        )

        XCTAssertTrue(isSilenced(.prompt, pattern: "snapshots", context: context))
        XCTAssertTrue(isSilenced(.prompt, pattern: "NIGHTLY benchmark", context: context))
        XCTAssertFalse(isSilenced(.project, pattern: "benchmark", context: context))
    }

    func testAgentAndToolRulesStayWithinTheirScopes() {
        let context = NotchSilenceContext(
            agentKey: "codex",
            agentName: "Codex",
            lastToolName: "Bash",
            pendingToolName: "AskUserQuestion"
        )

        XCTAssertTrue(isSilenced(.agent, pattern: "CODEX", context: context))
        XCTAssertTrue(isSilenced(.tool, pattern: "bash", context: context))
        XCTAssertTrue(isSilenced(.tool, pattern: "userquestion", context: context))
        XCTAssertFalse(isSilenced(.prompt, pattern: "codex", context: context))
    }

    func testDisabledAndBlankRulesNeverMatch() {
        let context = NotchSilenceContext(projectName: "vibe-notch")
        let rules = [
            NotchSilenceRule(
                scope: .project,
                pattern: "vibe",
                isEnabled: false
            ),
            NotchSilenceRule(scope: .project, pattern: "   "),
        ]

        XCTAssertNil(
            NotchSilenceRuleMatcher.matchingRule(in: rules, for: context)
        )
    }

    func testMatcherReturnsFirstEnabledRuleInUserOrder() {
        let first = NotchSilenceRule(scope: .project, pattern: "vibe")
        let second = NotchSilenceRule(scope: .project, pattern: "notch")
        let context = NotchSilenceContext(projectName: "vibe-notch")

        XCTAssertEqual(
            NotchSilenceRuleMatcher.matchingRule(
                in: [first, second],
                for: context
            )?.id,
            first.id
        )
    }

    func testMatchCountKeepsConcurrentSessionsIndependent() {
        let rule = NotchSilenceRule(scope: .project, pattern: "generated")
        let contexts = [
            NotchSilenceContext(projectName: "generated-snapshots"),
            NotchSilenceContext(projectName: "customer-app"),
        ]

        XCTAssertEqual(
            NotchSilenceRuleMatcher.matchCount(for: rule, in: contexts),
            1
        )
    }

    private func isSilenced(
        _ scope: NotchSilenceRuleScope,
        pattern: String,
        context: NotchSilenceContext
    ) -> Bool {
        NotchSilenceRuleMatcher.isSilenced(
            by: [NotchSilenceRule(scope: scope, pattern: pattern)],
            context: context
        )
    }
}

@MainActor
final class NotchSilenceRuleStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NotchSilenceRuleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRulesPersistAndReloadWithStableIdentity() throws {
        let key = "rules"
        let store = NotchSilenceRuleStore(defaults: defaults, key: key)

        XCTAssertTrue(store.addRule(scope: .project, pattern: "  vibe-notch  "))
        let id = try XCTUnwrap(store.rules.first?.id)
        store.setEnabled(false, for: id)

        let restored = NotchSilenceRuleStore(defaults: defaults, key: key)
        XCTAssertEqual(restored.rules.count, 1)
        XCTAssertEqual(restored.rules[0].id, id)
        XCTAssertEqual(restored.rules[0].pattern, "vibe-notch")
        XCTAssertFalse(restored.rules[0].isEnabled)
    }

    func testDuplicateRulesAreRejectedCaseAndDiacriticInsensitively() {
        let store = NotchSilenceRuleStore(defaults: defaults, key: "rules")

        XCTAssertTrue(store.addRule(scope: .prompt, pattern: "Résumé"))
        XCTAssertFalse(store.addRule(scope: .prompt, pattern: "resume"))
        XCTAssertTrue(store.addRule(scope: .project, pattern: "resume"))
        XCTAssertEqual(store.rules.count, 2)
    }

    func testRemovalUpdatesPersistedRules() throws {
        let key = "rules"
        let store = NotchSilenceRuleStore(defaults: defaults, key: key)
        XCTAssertTrue(store.addRule(scope: .agent, pattern: "Codex"))
        let id = try XCTUnwrap(store.rules.first?.id)

        store.removeRule(id: id)

        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(
            NotchSilenceRuleStore(defaults: defaults, key: key).rules.isEmpty
        )
    }

    func testCorruptStoredDataFallsBackToNoRules() {
        defaults.set(Data("not-json".utf8), forKey: "rules")

        let store = NotchSilenceRuleStore(defaults: defaults, key: "rules")

        XCTAssertTrue(store.rules.isEmpty)
    }

    func testLoadedRulesAreTrimmedDeduplicatedAndBounded() throws {
        let key = "rules"
        var encoded: [NotchSilenceRule] = [
            NotchSilenceRule(scope: .tool, pattern: "  Bash  "),
            NotchSilenceRule(scope: .tool, pattern: "bash"),
            NotchSilenceRule(scope: .tool, pattern: "   "),
        ]
        encoded.append(contentsOf: (0..<60).map {
            NotchSilenceRule(scope: .project, pattern: "project-\($0)")
        })
        defaults.set(try JSONEncoder().encode(encoded), forKey: key)

        let store = NotchSilenceRuleStore(defaults: defaults, key: key)

        XCTAssertEqual(
            store.rules.count,
            NotchSilenceRuleStore.maximumRuleCount
        )
        XCTAssertEqual(store.rules.first?.pattern, "Bash")
    }

    func testPatternLengthAndRuleCountAreBounded() {
        let store = NotchSilenceRuleStore(defaults: defaults, key: "rules")
        let longPattern = String(repeating: "x", count: 400)
        XCTAssertFalse(store.addRule(scope: .project, pattern: longPattern))
        XCTAssertTrue(store.rules.isEmpty)
        XCTAssertTrue(store.addRule(
            scope: .project,
            pattern: String(repeating: "x", count: 256)
        ))
        XCTAssertEqual(
            store.rules[0].pattern.count,
            NotchSilenceRuleStore.maximumPatternLength
        )

        for index in 1..<NotchSilenceRuleStore.maximumRuleCount {
            XCTAssertTrue(
                store.addRule(scope: .project, pattern: "project-\(index)")
            )
        }
        XCTAssertFalse(store.addRule(scope: .project, pattern: "overflow"))
        XCTAssertEqual(
            store.rules.count,
            NotchSilenceRuleStore.maximumRuleCount
        )
    }

    func testOverlongRuleCannotMatchOnlyItsShortenedPrefix() {
        let prefix = String(repeating: "x", count: 256)
        XCTAssertFalse(NotchSilenceRuleMatcher.isSilenced(
            by: [NotchSilenceRule(scope: .project, pattern: prefix + "specific")],
            context: NotchSilenceContext(projectName: prefix)
        ))
    }

    func testRestoredDuplicateIdsRemainIndependentlyEditable() throws {
        let id = UUID()
        let rules = [
            NotchSilenceRule(id: id, scope: .project, pattern: "first"),
            NotchSilenceRule(id: id, scope: .project, pattern: "second"),
        ]
        defaults.set(try JSONEncoder().encode(rules), forKey: "rules")
        let store = NotchSilenceRuleStore(defaults: defaults, key: "rules")
        XCTAssertEqual(store.rules.count, 2)
        XCTAssertNotEqual(store.rules[0].id, store.rules[1].id)
        let secondId = store.rules[1].id
        store.setEnabled(false, for: secondId)
        XCTAssertTrue(store.rules[0].isEnabled)
        XCTAssertFalse(store.rules[1].isEnabled)
        let restored = NotchSilenceRuleStore(defaults: defaults, key: "rules")
        XCTAssertEqual(restored.rules, store.rules)
        restored.removeRule(id: secondId)
        XCTAssertEqual(restored.rules.map(\.pattern), ["first"])
    }

    func testEditingPreservesIdentityDisabledStateAndPersists() throws {
        let store = NotchSilenceRuleStore(defaults: defaults, key: "rules")
        XCTAssertTrue(store.addRule(scope: .project, pattern: "first"))
        let id = try XCTUnwrap(store.rules.first?.id)
        store.setEnabled(false, for: id)
        XCTAssertTrue(store.updateRule(id: id, scope: .tool, pattern: " Bash "))
        XCTAssertEqual(store.rules[0].id, id)
        XCTAssertEqual(store.rules[0].scope, .tool)
        XCTAssertEqual(store.rules[0].pattern, "Bash")
        XCTAssertFalse(store.rules[0].isEnabled)
        XCTAssertEqual(
            NotchSilenceRuleStore(defaults: defaults, key: "rules").rules,
            store.rules
        )
    }

    func testInvalidEditsLeaveOriginalRulesUntouched() throws {
        let store = NotchSilenceRuleStore(defaults: defaults, key: "rules")
        XCTAssertTrue(store.addRule(scope: .project, pattern: "first"))
        XCTAssertTrue(store.addRule(scope: .tool, pattern: "Bash"))
        let id = try XCTUnwrap(store.rules.first?.id)
        let original = store.rules
        XCTAssertFalse(store.updateRule(id: id, scope: .tool, pattern: "bash"))
        XCTAssertFalse(store.updateRule(id: id, scope: .project, pattern: " "))
        XCTAssertFalse(store.updateRule(id: UUID(), scope: .project, pattern: "valid"))
        XCTAssertEqual(store.rules, original)
        XCTAssertTrue(store.updateRule(id: id, scope: .project, pattern: "first"))
        XCTAssertEqual(store.rules, original)
    }

    func testRuleLimitDoesNotPreventEditing() throws {
        let store = NotchSilenceRuleStore(defaults: defaults, key: "rules")
        for index in 0..<NotchSilenceRuleStore.maximumRuleCount {
            XCTAssertTrue(store.addRule(scope: .project, pattern: "project-\(index)"))
        }
        let id = try XCTUnwrap(store.rules.first?.id)
        XCTAssertTrue(store.updateRule(id: id, scope: .project, pattern: "updated"))
        XCTAssertEqual(store.rules.count, NotchSilenceRuleStore.maximumRuleCount)
    }
}
