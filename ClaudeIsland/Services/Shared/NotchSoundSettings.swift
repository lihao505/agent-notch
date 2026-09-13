// Modified by lihao505 for Agent Notch, 2026.
import Foundation

enum NotchSoundEvent: String, CaseIterable, Identifiable {
    case completion, approval, question, followUp
    var id: String { rawValue }
    var key: String {
        self == .completion ? "notificationSound" : "notchSound.\(rawValue)"
    }
}

enum NotchSoundSource: Equatable {
    case system(NotificationSound)
    case file(NotchImportedSound)
}

enum NotchSoundSettings {
    static let enabledKey = "notchAutomaticSoundsEnabled"
    static let volumeKey = "notchSoundVolume"

    /// App-local gain, independent of system volume. Preserve the previous
    /// full-volume behavior until the user explicitly changes it.
    static func volume(defaults: UserDefaults = .standard) -> Double {
        normalizedVolume(defaults.object(forKey: volumeKey) as? Double ?? 1)
    }

    static func normalizedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }

    static func source(
        for event: NotchSoundEvent,
        defaults: UserDefaults = .standard,
        directory: URL = NotchCustomSoundStore.directory
    ) -> NotchSoundSource? {
        let value = defaults.string(forKey: event.key) ?? ""
        if value.hasPrefix("custom:") {
            guard let record = NotchImportedSound.decode(value),
                  NotchCustomSoundStore.isAvailable(record, in: directory) else { return nil }
            return .file(record)
        }
        if let sound = NotificationSound(rawValue: value) {
            return sound == .none ? nil : .system(sound)
        }
        switch event {
        case .approval, .question: return nil
        case .completion: return .system(.pop)
        case .followUp:
            // Preserve the previous completion/follow-up shared choice until
            // the user explicitly chooses a separate follow-up sound.
            return source(for: .completion, defaults: defaults, directory: directory)
        }
    }

    static func automaticSource(
        for event: NotchSoundEvent,
        defaults: UserDefaults = .standard,
        directory: URL = NotchCustomSoundStore.directory
    ) -> NotchSoundSource? {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true,
              volume(defaults: defaults) > 0 else {
            return nil
        }
        return source(for: event, defaults: defaults, directory: directory)
    }

    /// Filter before selecting so a newer silent question cannot mask an
    /// audible approval. The caller records all identities, even while muted,
    /// so changing sound preferences never replays an observed request.
    static func newestInteractionEvent(
        in sessions: [SessionState],
        excluding previousTokens: Set<NotchInteractionToken>,
        trackingStartedAt: Date,
        defaults: UserDefaults = .standard
    ) -> NotchSoundEvent? {
        sessions.compactMap { session -> (NotchSoundEvent, Date)? in
            guard let token = NotchAttentionPolicy.interactionToken(for: session),
                  !previousTokens.contains(token),
                  let context = session.activePermission,
                  context.receivedAt >= trackingStartedAt else { return nil }
            let event: NotchSoundEvent = context.toolName == "AskUserQuestion"
                ? .question : .approval
            guard automaticSource(for: event, defaults: defaults) != nil else {
                return nil
            }
            return (event, context.receivedAt)
        }
        .max(by: { $0.1 < $1.1 })?.0
    }
}
