// Modified by lihao505 for Agent Notch, 2026.
import AVFoundation
import Foundation

nonisolated struct NotchImportedSound: Codable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let fileExtension: String

    nonisolated var filename: String { "\(id.uuidString).\(fileExtension)" }
    nonisolated var rawValue: String {
        get throws { "custom:" + String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    }

    nonisolated static func decode(_ raw: String) -> Self? {
        guard raw.hasPrefix("custom:"), raw.utf8.count < 2_048,
              let record = try? JSONDecoder().decode(Self.self, from: Data(raw.dropFirst(7).utf8)),
              NotchCustomSoundStore.extensions.contains(record.fileExtension),
              !record.displayName.isEmpty, record.displayName.count <= 128 else { return nil }
        return record
    }
}

enum NotchSoundImportError: Error {
    case invalidFile, tooLarge, tooLong, unsupportedAudio, unsafeDirectory

    func message(language: AppLanguage) -> String {
        switch self {
        case .invalidFile:
            return language.text("Choose a local WAV, MP3 or AIFF file.", "请选择本地 WAV、MP3 或 AIFF 音频文件。")
        case .tooLarge:
            return language.text("Choose an audio file smaller than 10 MB.", "请选择不超过 10 MB 的音频文件。")
        case .tooLong:
            return language.text("Alert sounds must be between 0 and 30 seconds long.", "提醒音需有有效内容，且时长不超过 30 秒。")
        case .unsupportedAudio:
            return language.text("This audio could not be decoded. Try another file.", "无法解码此音频，请选择其他文件。")
        case .unsafeDirectory:
            return language.text("The sound storage folder is unavailable or redirected.", "声音存储目录不可用或被重定向。")
        }
    }
}

/// Copies only user-selected files. Preferences store UUIDs, never arbitrary
/// playback paths. Decoding/copying runs off the main actor via the importer.
enum NotchCustomSoundStore {
    nonisolated static let extensions: Set<String> = ["wav", "mp3", "aiff", "aif"]
    nonisolated static let maximumBytes = 10 * 1_024 * 1_024
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Notch/Sounds", isDirectory: true)
    }

    nonisolated static func fileURL(for record: NotchImportedSound, in directory: URL = directory) -> URL {
        directory.appendingPathComponent(record.filename)
    }

    nonisolated static func isAvailable(_ record: NotchImportedSound, in directory: URL = directory) -> Bool {
        guard extensions.contains(record.fileExtension),
              directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            return false
        }
        return (try? validateFile(fileURL(for: record, in: directory))) != nil
    }

    nonisolated static func importSound(from source: URL, into directory: URL = directory) throws -> NotchImportedSound {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try validateFile(source)
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw NotchSoundImportError.unsafeDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let name = String(String.UnicodeScalarView(source.lastPathComponent.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).prefix(128))
        let record = NotchImportedSound(id: UUID(), displayName: name.isEmpty ? "Audio" : name,
                                        fileExtension: source.pathExtension.lowercased())
        let target = fileURL(for: record, in: directory)
        try FileManager.default.copyItem(at: source, to: target)
        do {
            try validateFile(target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let audio: AVAudioFile
            do { audio = try AVAudioFile(forReading: target) }
            catch { throw NotchSoundImportError.unsupportedAudio }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            guard duration.isFinite, duration > 0, duration <= 30 else {
                throw NotchSoundImportError.tooLong
            }
            let format = audio.processingFormat
            guard format.channelCount > 0, format.channelCount <= 8,
                  format.sampleRate <= 384_000,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
                throw NotchSoundImportError.unsupportedAudio
            }
            // Validate actual frames, not just a plausible container header.
            // A fixed buffer keeps decoding bounded and off the UI thread.
            var decodedFrames: Int64 = 0
            while audio.framePosition < audio.length {
                do { try audio.read(into: buffer) }
                catch { throw NotchSoundImportError.unsupportedAudio }
                guard buffer.frameLength > 0 else { throw NotchSoundImportError.unsupportedAudio }
                decodedFrames += Int64(buffer.frameLength)
                guard Double(decodedFrames) / format.sampleRate <= 30 else {
                    throw NotchSoundImportError.tooLong
                }
            }
            guard decodedFrames > 0 else { throw NotchSoundImportError.unsupportedAudio }
            return record
        } catch {
            // Only this attempt's unique copy can be removed, never the input.
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    nonisolated private static func validateFile(_ url: URL) throws {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else {
            throw NotchSoundImportError.invalidFile
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw NotchSoundImportError.invalidFile }
        guard size <= maximumBytes else { throw NotchSoundImportError.tooLarge }
    }

    /// Called only for the old record of a changed setting (or a cancelled
    /// import), not a broad sweep of the sound directory.
    static func removeIfUnreferenced(_ record: NotchImportedSound, defaults: UserDefaults = .standard,
                                     in directory: URL = directory) {
        guard !NotchSoundEvent.allCases.contains(where: {
            defaults.string(forKey: $0.key).flatMap(NotchImportedSound.decode)?.id == record.id
        }), isAvailable(record, in: directory) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: record, in: directory))
    }
}
