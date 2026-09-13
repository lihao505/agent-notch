// Modified by lihao505 for Agent Notch, 2026.
import AVFoundation
import AppKit
import XCTest
@testable import Agent_Notch

@MainActor
final class NotchCustomSoundTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NotchCustomSoundTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func wave(at url: URL, seconds: Double = 0.1) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 8_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { samples[index] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testImportOwnsPrivateCopyAndOriginalCanMove() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("测试提醒.wav")
        try wave(at: source)
        let original = try Data(contentsOf: source)
        let directory = root.appendingPathComponent("sounds")
        let record = try NotchCustomSoundStore.importSound(from: source, into: directory)
        XCTAssertEqual(record.displayName, "测试提醒.wav")
        XCTAssertEqual(try NotchImportedSound.decode(record.rawValue), record)
        let copy = NotchCustomSoundStore.fileURL(for: record, in: directory)
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertNotNil(NSSound(contentsOf: copy, byReference: false))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int, 0o600)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("moved.wav"))
        XCTAssertTrue(NotchCustomSoundStore.isAvailable(record, in: directory))
    }

    func testCustomChoiceRestoresAndFollowUpInheritsIt() async throws {
        let root = try temporaryDirectory()
        let suite = "NotchCustomSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("tone.wav")
        try wave(at: source)
        let directory = root.appendingPathComponent("sounds")
        let record = try NotchCustomSoundStore.importSound(from: source, into: directory)
        defaults.set(try record.rawValue, forKey: NotchSoundEvent.completion.key)
        let restored = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(NotchSoundSettings.source(for: .completion, defaults: restored, directory: directory), .file(record))
        XCTAssertEqual(NotchSoundSettings.source(for: .followUp, defaults: restored, directory: directory), .file(record))
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        XCTAssertNil(NotchSoundSettings.automaticSource(for: .completion, defaults: defaults, directory: directory))
        XCTAssertEqual(NotchSoundSettings.source(for: .completion, defaults: defaults, directory: directory), .file(record))
        // Missing files stay silent, rather than changing the user's choice to Pop.
        try FileManager.default.removeItem(at: NotchCustomSoundStore.fileURL(for: record, in: directory))
        XCTAssertNil(NotchSoundSettings.source(for: .completion, defaults: defaults, directory: directory))
        XCTAssertNil(NotchSoundSettings.source(for: .followUp, defaults: defaults, directory: directory))
        XCTAssertEqual(defaults.string(forKey: NotchSoundEvent.completion.key), try record.rawValue)
    }

    func testCorruptAndOverlongAudioLeaveNoCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sounds")
        let corrupt = root.appendingPathComponent("corrupt.wav")
        try Data("not an audio file".utf8).write(to: corrupt)
        XCTAssertThrowsError(try NotchCustomSoundStore.importSound(from: corrupt, into: directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        let long = root.appendingPathComponent("long.wav")
        try wave(at: long, seconds: 31)
        XCTAssertThrowsError(try NotchCustomSoundStore.importSound(from: long, into: directory)) { error in
            guard case NotchSoundImportError.tooLong = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: long.path))
    }

    func testSizeTypeAndSymlinkBoundaries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sounds")
        let large = root.appendingPathComponent("large.wav")
        try Data(repeating: 0, count: NotchCustomSoundStore.maximumBytes + 1).write(to: large)
        XCTAssertThrowsError(try NotchCustomSoundStore.importSound(from: large, into: directory)) { error in
            guard case NotchSoundImportError.tooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try NotchCustomSoundStore.importSound(from: root, into: directory))
        let source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try NotchCustomSoundStore.importSound(from: link, into: directory))
        let redirected = root.appendingPathComponent("redirected")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: root)
        XCTAssertThrowsError(try NotchCustomSoundStore.importSound(from: source, into: redirected))
    }

    func testCleanupPreservesSharedReferencesAndOnlyRemovesOwnedCopy() async throws {
        let root = try temporaryDirectory()
        let suite = "NotchCustomSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let directory = root.appendingPathComponent("sounds")
        let record = try NotchCustomSoundStore.importSound(from: source, into: directory)
        defaults.set(try record.rawValue, forKey: NotchSoundEvent.question.key)
        NotchCustomSoundStore.removeIfUnreferenced(record, defaults: defaults, in: directory)
        XCTAssertTrue(NotchCustomSoundStore.isAvailable(record, in: directory))
        defaults.set("None", forKey: NotchSoundEvent.question.key)
        NotchCustomSoundStore.removeIfUnreferenced(record, defaults: defaults, in: directory)
        XCTAssertFalse(NotchCustomSoundStore.isAvailable(record, in: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMalformedMetadataCannotAddressArbitraryPaths() async throws {
        XCTAssertNil(NotchImportedSound.decode("custom:invalid json"))
        let record = NotchImportedSound(id: UUID(), displayName: "forged", fileExtension: "../../private")
        XCTAssertNil(try NotchImportedSound.decode(record.rawValue))
        let suite = "NotchCustomSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("custom:invalid json", forKey: NotchSoundEvent.completion.key)
        XCTAssertNil(NotchSoundSettings.source(for: .completion, defaults: defaults))
    }

    func testActualMP3CanBeImportedWithoutAnExternalDecoder() async throws {
        // Original synthetic 660 Hz fixture, generated once using FFmpeg.
        // Tests use only Apple's built-in decoder; no FFmpeg dependency.
        let encoded = "/+MoxAAdaNaQX08QAAGTblAAve973ve9KUpSlKave973vf+lKUpT/5ve+4CcJwJuGrCPhqxDyXqOPggc+nlwxwG/SGOXflwQDEEATB96wfBAMRAAwfw+CBzAYf4Y6fd5cHwfD4IAgCAIAMHwffcCHlwfD4IAgCAIAMHwfB+MBAENYPrBOIAACCwWigUoWBsT/+MoxA0gejqtuYigAP/+SKlC3/NvAKhBBqAL/0juUiLBkYBw8ESIXNOmgBgoFjR43MB4AosFlFQxLpdSSSWj/lRbpqZlkVMi8XjEul1JJL/zcnzA0KhmmbmDLRRUkktFFSSX/5om5ugxom58MCU6Hf/gM2GAGk4A///0nAGk4A0nEyAwKAGGBgMBgMBr/5qZ/+MoxA4g6zKqWY1oABwpf4nomocIRb/Jw8hAQIMK4jOYosl+COiQC9CTDeOUT0gf/+FWCbCdhzQqInAlQW4ZYwP//+HJHgMoOUOcZIlo9CEJcPcg////iej0I4nxJkYT0kCOOIkyAOEkP////KY4ieUBwkwpjiJ5KDhJhLjiKyUHqVJMQU1FMy4xMDCqqqqq/+MoxA0AAANIAcAAAKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tone.mp3")
        try XCTUnwrap(Data(base64Encoded: encoded)).write(to: source)
        let directory = root.appendingPathComponent("sounds")
        let record = try NotchCustomSoundStore.importSound(from: source, into: directory)
        XCTAssertEqual(record.fileExtension, "mp3")
        XCTAssertTrue(NotchCustomSoundStore.isAvailable(record, in: directory))
        XCTAssertNotNil(NSSound(contentsOf: NotchCustomSoundStore.fileURL(for: record, in: directory), byReference: false))
    }

    func testCustomPlaybackUsesSameMuteAndVolumePolicy() async throws {
        final class FakeSound: NotchSoundPlayback {
            var volume: Float = 1
            func play() -> Bool { true }
            func stop() -> Bool { true }
        }
        let root = try temporaryDirectory()
        let suite = "NotchCustomSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let directory = root.appendingPathComponent("sounds")
        let record = try NotchCustomSoundStore.importSound(from: source, into: directory)
        defaults.set(try record.rawValue, forKey: NotchSoundEvent.question.key)
        defaults.set(0.17, forKey: NotchSoundSettings.volumeKey)
        let sound = FakeSound()
        var loaded: [NotchSoundSource] = []
        let player = NotchSoundPlayer(defaults: defaults, observeChanges: false, directory: directory) {
            loaded.append($0)
            return sound
        }
        XCTAssertTrue(player.playAutomatic(for: .question))
        XCTAssertEqual(loaded, [.file(record)])
        XCTAssertEqual(sound.volume, 0.17, accuracy: 0.0001)
        defaults.set(false, forKey: NotchSoundSettings.enabledKey)
        XCTAssertFalse(player.playAutomatic(for: .question))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(player.preview(for: .question))
        defaults.set(0, forKey: NotchSoundSettings.volumeKey)
        XCTAssertFalse(player.preview(for: .question))
        XCTAssertEqual(loaded.count, 2)
    }
}
