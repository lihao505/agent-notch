//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchAttentionSilencePolicy.swift
//  ClaudeIsland
//
//  One pure decision point for automatic attention sound suppression.
//

import Foundation

enum NotchAttentionSilenceReason: String, Equatable, Sendable {
    case screenLocked = "screen_locked"
    case displayAsleep = "display_asleep"
    case systemAsleep = "system_asleep"
    case sessionInactive = "session_inactive"
    case scheduledQuietHours = "scheduled_quiet_hours"
}

enum NotchAttentionSilencePolicy {
    static func suppressionReason(
        quietScenesEnabled: Bool,
        sceneState: NotchQuietSceneState,
        quietHoursEnabled: Bool,
        quietHoursStartMinute: Int,
        quietHoursEndMinute: Int,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> NotchAttentionSilenceReason? {
        if quietScenesEnabled {
            if sceneState.isScreenLocked {
                return .screenLocked
            }
            if sceneState.isDisplayAsleep {
                return .displayAsleep
            }
            if sceneState.isSystemAsleep {
                return .systemAsleep
            }
            if !sceneState.isSessionActive {
                return .sessionInactive
            }
        }

        if NotchQuietHoursPolicy.isQuiet(
            enabled: quietHoursEnabled,
            startMinute: quietHoursStartMinute,
            endMinute: quietHoursEndMinute,
            at: date,
            calendar: calendar
        ) {
            return .scheduledQuietHours
        }

        return nil
    }
}
