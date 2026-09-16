// Modified by lihao505 for Agent Notch, 2026.
import Foundation

enum SessionNavigationDirection { case previous, next }

/// One order for the visible list and keyboard navigation. Stable identity is
/// the final tie-breaker; dictionary publication order must never choose a tab.
enum SessionNavigationPolicy {
    static func ordered(_ sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { left, right in
            let lhs = priority(left.phase), rhs = priority(right.phase)
            if lhs != rhs { return lhs < rhs }
            let leftDate = left.lastUserMessageDate ?? left.lastActivity
            let rightDate = right.lastUserMessageDate ?? right.lastActivity
            if leftDate != rightDate { return leftDate > rightDate }
            return left.sessionId < right.sessionId
        }
    }

    static func target(
        in sessions: [SessionState], currentID: String?,
        direction: SessionNavigationDirection
    ) -> SessionState? {
        let candidates = ordered(sessions.filter { $0.phase != .ended })
        guard !candidates.isEmpty else { return nil }
        guard let currentID,
              let index = candidates.firstIndex(where: { $0.sessionId == currentID }) else {
            return direction == .next ? candidates.first : candidates.last
        }
        let offset = direction == .next ? 1 : -1
        return candidates[(index + offset + candidates.count) % candidates.count]
    }

    private static func priority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }
}
