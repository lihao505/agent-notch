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
}
