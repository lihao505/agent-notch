//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchQuietHoursPolicy.swift
//  ClaudeIsland
//
//  Pure local-time policy for muting automatic attention sounds.
//

import Foundation

enum NotchQuietHoursPolicy {
    static let minutesPerDay = 24 * 60

    static func sanitizedMinute(_ minute: Int) -> Int {
        min(max(0, minute), minutesPerDay - 1)
    }

    /// Start is inclusive and end is exclusive. An equal start/end represents
    /// an intentional all-day quiet schedule; the separate enable switch is
    /// the unambiguous way to disable it.
    static func isQuiet(
        enabled: Bool,
        startMinute: Int,
        endMinute: Int,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard enabled else { return false }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour,
              let minute = components.minute else {
            return false
        }

        let currentMinute = hour * 60 + minute
        let start = sanitizedMinute(startMinute)
        let end = sanitizedMinute(endMinute)

        if start == end {
            return true
        }
        if start < end {
            return currentMinute >= start && currentMinute < end
        }
        return currentMinute >= start || currentMinute < end
    }
}
