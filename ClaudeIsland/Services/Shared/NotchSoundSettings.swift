// Modified by lihao505 for Agent Notch, 2026.
import Foundation

enum NotchSoundEvent: String, CaseIterable, Identifiable {
    case completion, approval, question, followUp
    var id: String { rawValue }
    var key: String {
        self == .completion ? "notificationSound" : "notchSound.\(rawValue)"
    }
}

enum NotchSoundSettings {
    static let enabledKey = "notchAutomaticSoundsEnabled"

    static func sound(
        for event: NotchSoundEvent,
        defaults: UserDefaults = .standard
    ) -> NotificationSound {
        if let value = defaults.string(forKey: event.key),
           let sound = NotificationSound(rawValue: value) {
            return sound
        }
        switch event {
        case .approval, .question: return .none
        case .completion: return .pop
        case .followUp:
            // Preserve the previous completion/follow-up shared choice until
            // the user explicitly chooses a separate follow-up sound.
            return sound(for: .completion, defaults: defaults)
        }
    }

    static func automaticSound(
        for event: NotchSoundEvent,
        defaults: UserDefaults = .standard
    ) -> NotificationSound {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else {
            return .none
        }
        return sound(for: event, defaults: defaults)
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
            guard automaticSound(for: event, defaults: defaults) != .none else {
                return nil
            }
            return (event, context.receivedAt)
        }
        .max(by: { $0.1 < $1.1 })?.0
    }
}
