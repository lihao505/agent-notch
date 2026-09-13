// Modified by lihao505 for Agent Notch, 2026.
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchSoundSettingsTests: XCTestCase {
    private func session(
        id: String = "session",
        tool: String = "Bash",
        at: TimeInterval = 101
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/sound-tests",
            phase: .waitingForApproval(PermissionContext(
                toolUseId: "shared-tool-id",
                toolName: tool,
                toolInput: nil,
                receivedAt: Date(timeIntervalSince1970: at)
            ))
        )
    }

    func testLegacyChoiceIsPreservedAndNewEventsDefaultSilent() async {
        let suite = "NotchSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Glass", forKey: "notificationSound")
        XCTAssertEqual(NotchSoundSettings.source(for: .completion, defaults: defaults), .system(.glass))
        XCTAssertEqual(NotchSoundSettings.source(for: .followUp, defaults: defaults), .system(.glass))
        XCTAssertEqual(NotchSoundSettings.source(for: .approval, defaults: defaults), nil)
        XCTAssertEqual(NotchSoundSettings.source(for: .question, defaults: defaults), nil)
        defaults.set("None", forKey: NotchSoundEvent.followUp.key)
        defaults.set("Ping", forKey: NotchSoundEvent.question.key)
        XCTAssertEqual(NotchSoundSettings.source(for: .followUp, defaults: defaults), nil)
        XCTAssertEqual(NotchSoundSettings.source(for: .question, defaults: defaults), .system(.ping))
        XCTAssertEqual(NotchSoundSettings.source(for: .completion, defaults: defaults), .system(.glass))
    }

    func testInvalidStoredChoicesUseCompatibleDefaults() async {
        let suite = "NotchSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for event in NotchSoundEvent.allCases {
            defaults.set("missing-sound", forKey: event.key)
        }
        XCTAssertEqual(NotchSoundSettings.source(for: .completion, defaults: defaults), .system(.pop))
        XCTAssertEqual(NotchSoundSettings.source(for: .followUp, defaults: defaults), .system(.pop))
        XCTAssertEqual(NotchSoundSettings.source(for: .approval, defaults: defaults), nil)
    }

    func testMasterMutePreservesChoicesAndExplicitPreview() async {
        let suite = "NotchSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for event in NotchSoundEvent.allCases {
            defaults.set("Ping", forKey: event.key)
            XCTAssertEqual(NotchSoundSettings.automaticSource(for: event, defaults: defaults), .system(.ping))
        }
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        for event in NotchSoundEvent.allCases {
            XCTAssertEqual(NotchSoundSettings.automaticSource(for: event, defaults: defaults), nil)
            XCTAssertEqual(NotchSoundSettings.source(for: event, defaults: defaults), .system(.ping))
        }
        defaults.set(true, forKey: NotchSoundSettings.enabledKey)
        defaults.set("Glass", forKey: NotchSoundEvent.completion.key)
        XCTAssertEqual(NotchSoundSettings.automaticSource(for: .completion, defaults: defaults), .system(.glass))
    }

    func testFollowUpCanResumeFollowingCompletion() async {
        let suite = "NotchSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("None", forKey: NotchSoundEvent.followUp.key)
        defaults.set("Glass", forKey: NotchSoundEvent.completion.key)
        XCTAssertEqual(NotchSoundSettings.source(for: .followUp, defaults: defaults), nil)
        defaults.set("", forKey: NotchSoundEvent.followUp.key)
        XCTAssertEqual(NotchSoundSettings.source(for: .followUp, defaults: defaults), .system(.glass))
        defaults.set("Ping", forKey: NotchSoundEvent.completion.key)
        XCTAssertEqual(NotchSoundSettings.source(for: .followUp, defaults: defaults), .system(.ping))
    }

    func testSilentQuestionCannotMaskApprovalAndNewestAudibleEventWins() async {
        let suite = "NotchSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = [session(tool: "ExitPlanMode"), session(id: "question", tool: "AskUserQuestion", at: 102)]
        let startedAt = Date(timeIntervalSince1970: 100)
        defaults.set("Glass", forKey: NotchSoundEvent.approval.key)
        XCTAssertEqual(NotchSoundSettings.newestInteractionEvent(
            in: sessions, excluding: [], trackingStartedAt: startedAt, defaults: defaults
        ), .approval)
        defaults.set("Ping", forKey: NotchSoundEvent.question.key)
        XCTAssertEqual(NotchSoundSettings.newestInteractionEvent(
            in: sessions, excluding: [], trackingStartedAt: startedAt, defaults: defaults
        ), .question)
    }

    func testStartupAndObservedInteractionsDoNotReplayAfterUnmuting() async throws {
        let suite = "NotchSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let startedAt = Date(timeIntervalSince1970: 100)
        defaults.set("Glass", forKey: NotchSoundEvent.approval.key)
        XCTAssertNil(NotchSoundSettings.newestInteractionEvent(
            in: [session(at: 99)], excluding: [], trackingStartedAt: startedAt, defaults: defaults
        ))
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        let pending = session()
        XCTAssertNil(NotchSoundSettings.newestInteractionEvent(
            in: [pending], excluding: [], trackingStartedAt: startedAt, defaults: defaults
        ))
        let observed = try XCTUnwrap(NotchAttentionPolicy.interactionToken(for: pending))
        defaults.set(true, forKey: NotchSoundSettings.enabledKey)
        XCTAssertNil(NotchSoundSettings.newestInteractionEvent(
            in: [pending], excluding: [observed], trackingStartedAt: startedAt, defaults: defaults
        ))
        // Tool ids are not globally unique: a second session must still sound.
        XCTAssertEqual(NotchSoundSettings.newestInteractionEvent(
            in: [pending, session(id: "another")], excluding: [observed],
            trackingStartedAt: startedAt, defaults: defaults
        ), .approval)
        var resolved = pending
        resolved.phase = .processing
        XCTAssertNil(NotchSoundSettings.newestInteractionEvent(
            in: [resolved], excluding: [], trackingStartedAt: startedAt, defaults: defaults
        ))
    }
}
