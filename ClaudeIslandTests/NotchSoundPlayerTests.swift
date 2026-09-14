// Modified by lihao505 for Agent Notch, 2026.
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchSoundPlayerTests: XCTestCase {
    private final class FakeSound: NotchSoundPlayback {
        var volume: Float = 1
        var plays = 0
        var stops = 0
        var succeeds = true
        var onStop: (() -> Void)?
        func play() -> Bool { plays += 1; return succeeds }
        func stop() -> Bool { stops += 1; onStop?(); return true }
    }

    func testVolumeDefaultsClampsAndPreservesQuietLevels() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NotchSoundSettings.volume(defaults: defaults), 1)
        for (stored, expected) in [(-1.0, 0.0), (0, 0), (0.01, 0.01), (0.37, 0.37), (2, 1)] {
            defaults.set(stored, forKey: NotchSoundSettings.volumeKey)
            XCTAssertEqual(NotchSoundSettings.volume(defaults: defaults), expected)
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(NotchSoundSettings.normalizedVolume(value), 1)
        }
        defaults.set("invalid", forKey: NotchSoundSettings.volumeKey)
        XCTAssertEqual(NotchSoundSettings.volume(defaults: defaults), 1)
    }

    func testMutedEventsAndZeroVolumeNeverLoadAudio() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var loads = 0
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in
            loads += 1
            return FakeSound()
        }
        XCTAssertFalse(player.preview(.none))
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        XCTAssertFalse(player.playAutomatic(for: .completion))
        defaults.set(0, forKey: NotchSoundSettings.volumeKey)
        XCTAssertFalse(player.preview(.pop))
        defaults.set(true, forKey: NotchSoundSettings.enabledKey)
        XCTAssertFalse(player.playAutomatic(for: .completion))
        XCTAssertEqual(loads, 0)
    }

    func testAutomaticAndPreviewShareGainAndReplacePreviousPlayback() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.12, forKey: NotchSoundSettings.volumeKey)
        var sounds: [FakeSound] = []
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in
            let sound = FakeSound()
            sounds.append(sound)
            return sound
        }
        XCTAssertTrue(player.playAutomatic(for: .completion))
        XCTAssertEqual(sounds[0].volume, 0.12, accuracy: 0.0001)
        XCTAssertTrue(player.preview(.ping))
        XCTAssertEqual(sounds[0].stops, 1)
        XCTAssertEqual(sounds[1].volume, sounds[0].volume)
        XCTAssertEqual(sounds[1].plays, 1)
        XCTAssertTrue(player.preview(.ping))
        XCTAssertEqual(sounds[1].stops, 1)
        XCTAssertEqual(sounds.count, 3)
    }

    func testLiveVolumeAndMasterMuteNeverReplayStoppedAlerts() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sound = FakeSound()
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in sound }
        XCTAssertTrue(player.playAutomatic(for: .completion))
        defaults.set(0.05, forKey: NotchSoundSettings.volumeKey)
        player.refreshSettings()
        XCTAssertEqual(sound.volume, 0.05, accuracy: 0.0001)
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        player.refreshSettings()
        XCTAssertEqual(sound.stops, 1)
        defaults.set(true, forKey: NotchSoundSettings.enabledKey)
        player.refreshSettings()
        XCTAssertEqual(sound.plays, 1)
    }

    func testExplicitPreviewSurvivesAutomaticMuteButStopsAtZero() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sound = FakeSound()
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in sound }
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        XCTAssertTrue(player.preview(.ping))
        player.refreshSettings()
        XCTAssertEqual(sound.stops, 0)
        defaults.set(0, forKey: NotchSoundSettings.volumeKey)
        player.refreshSettings()
        XCTAssertEqual(sound.stops, 1)
        defaults.set(0.5, forKey: NotchSoundSettings.volumeKey)
        player.refreshSettings()
        XCTAssertEqual(sound.plays, 1)
    }

    func testMissingOrFailedPlaybackDoesNotPretendToStart() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let missing = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in nil }
        XCTAssertFalse(missing.preview(.pop))
        let sound = FakeSound()
        sound.succeeds = false
        let failed = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in sound }
        XCTAssertFalse(failed.preview(.pop))
        failed.refreshSettings()
        XCTAssertEqual(sound.plays, 1)
    }

    func testSettingsNotificationStopsAutomaticPlaybackOutsideEditor() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stopped = expectation(description: "Preference observer stops playback")
        let sound = FakeSound()
        sound.onStop = { stopped.fulfill() }
        let player = NotchSoundPlayer(defaults: defaults) { _ in sound }
        XCTAssertTrue(player.playAutomatic(for: .completion))
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(sound.stops, 1)
        XCTAssertEqual(sound.plays, 1)
    }

    func testResumedCompletionStopsWithoutReplayingOnOldSnapshot() async throws {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sound = FakeSound()
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in sound }
        var session = SessionState(sessionId: "task", cwd: "/tmp/sound-tests", phase: .waitingForInput)
        session.completedAt = Date(timeIntervalSince1970: 100)
        let token = try XCTUnwrap(NotchAttentionPolicy.completionToken(for: session))
        let completed = session
        XCTAssertTrue(player.playAutomatic(for: .completion, targets: [.completion(token)]))
        session.pid = 42
        player.revalidateAutomaticPlayback(in: [session])
        XCTAssertEqual(sound.stops, 0)
        // Even if SwiftUI coalesces away the intervening working state, a new
        // completion boundary must not keep the previous turn's audio alive.
        session.completedAt = Date(timeIntervalSince1970: 200)
        player.revalidateAutomaticPlayback(in: [session])
        XCTAssertEqual(sound.stops, 1)
        player.revalidateAutomaticPlayback(in: [completed])
        XCTAssertEqual(sound.plays, 1)
        XCTAssertEqual(sound.stops, 1)
        XCTAssertTrue(player.playAutomatic(for: .completion, targets: [.completion(token)]))
        session.phase = .processing
        player.revalidateAutomaticPlayback(in: [session])
        XCTAssertEqual(sound.stops, 2)
    }

    func testInteractionPlaybackRequiresExactSessionAndRequest() async throws {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Ping", forKey: NotchSoundEvent.approval.key)
        let sound = FakeSound()
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in sound }
        let context = PermissionContext(toolUseId: "same-tool", toolName: "Bash", toolInput: nil, receivedAt: Date())
        let taskA = SessionState(sessionId: "A", cwd: "/tmp/sound-tests", phase: .waitingForApproval(context))
        let taskB = SessionState(sessionId: "B", cwd: "/tmp/sound-tests", phase: .waitingForApproval(context))
        let selected = try XCTUnwrap(NotchSoundSettings.newestInteractionSound(
            in: [taskA], excluding: [], trackingStartedAt: .distantPast, defaults: defaults
        ))
        XCTAssertEqual(selected.target, .interaction(NotchInteractionToken(sessionId: "A", toolUseId: "same-tool")))
        XCTAssertTrue(player.playAutomatic(for: selected.event, targets: [selected.target]))
        player.revalidateAutomaticPlayback(in: [taskA, taskB])
        XCTAssertEqual(sound.stops, 0)
        player.revalidateAutomaticPlayback(in: [taskB])
        XCTAssertEqual(sound.stops, 1)
        XCTAssertTrue(player.playAutomatic(for: selected.event, targets: [selected.target]))
        let replacement = PermissionContext(toolUseId: "next-tool", toolName: "Bash", toolInput: nil, receivedAt: Date())
        let resumedA = SessionState(sessionId: "A", cwd: "/tmp/sound-tests", phase: .waitingForApproval(replacement))
        player.revalidateAutomaticPlayback(in: [resumedA, taskB])
        XCTAssertEqual(sound.stops, 2)
    }

    func testFollowUpRetainsOnlyCurrentUnsilencedTargets() async throws {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sound = FakeSound()
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in sound }
        let context = PermissionContext(toolUseId: "tool", toolName: "AskUserQuestion", toolInput: nil, receivedAt: Date())
        let sessions = ["A", "B"].map {
            SessionState(sessionId: $0, cwd: "/tmp/sound-tests", phase: .waitingForApproval(context))
        }
        let targets = Set(sessions.compactMap(NotchAttentionPolicy.interactionToken).map(NotchFollowUpTarget.interaction))
        XCTAssertTrue(player.playAutomatic(for: .followUp, targets: targets))
        player.revalidateAutomaticPlayback(in: sessions, silencedSessionIds: ["A"])
        XCTAssertEqual(sound.stops, 0)
        // Removing the rule cannot re-add an already consumed target A.
        player.revalidateAutomaticPlayback(in: [sessions[0]])
        XCTAssertEqual(sound.stops, 1)
        player.revalidateAutomaticPlayback(in: sessions)
        XCTAssertEqual(sound.plays, 1)
    }

    func testQuietSceneStopsAutomaticAudioButNotExplicitPreview() async {
        let suite = "NotchSoundPlayerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var sounds: [FakeSound] = []
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false) { _ in
            let sound = FakeSound()
            sounds.append(sound)
            return sound
        }
        XCTAssertTrue(player.playAutomatic(for: .completion))
        player.revalidateAutomaticPlayback(in: [], sceneSuppressed: true)
        XCTAssertEqual(sounds[0].stops, 1)
        player.revalidateAutomaticPlayback(in: [], sceneSuppressed: false)
        XCTAssertEqual(sounds.count, 1)
        XCTAssertTrue(player.preview(.ping))
        player.revalidateAutomaticPlayback(in: [], sceneSuppressed: true)
        XCTAssertEqual(sounds[1].stops, 0)
    }
}
