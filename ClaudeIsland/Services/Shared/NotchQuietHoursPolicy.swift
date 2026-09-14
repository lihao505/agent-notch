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

    /// Schedule only boundaries, including offset changes that can jump into
    /// or out of a local-time interval. Repeated hours need both occurrences.
    static func nextRecheckDate(
        enabled: Bool,
        startMinute: Int,
        endMinute: Int,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let start = sanitizedMinute(startMinute)
        let end = sanitizedMinute(endMinute)
        guard enabled, start != end else { return nil }
        var candidates: [Date] = []
        for minute in [start, end] {
            let components = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
            for repeated: Calendar.RepeatedTimePolicy in [.first, .last] {
                if let next = calendar.nextDate(
                    after: date, matching: components,
                    matchingPolicy: .nextTime, repeatedTimePolicy: repeated
                ), next > date {
                    candidates.append(next)
                }
            }
        }
        if let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: date), transition > date {
            candidates.append(transition)
        }
        return candidates.min()
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
