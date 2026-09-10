//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchAttentionPolicy.swift
//  ClaudeIsland
//
//  Stable identities and presentation policy for user-attention events.
//

import Foundation

/// A completion is an event generation, not merely a session that currently
/// happens to be idle. Keeping the authoritative completion boundary in the
/// identity prevents PID/title refreshes from replaying the same alert and
/// still lets a very fast next turn surface even if SwiftUI coalesces the
/// intermediate processing snapshot.
struct NotchCompletionToken: Hashable, Sendable {
    let sessionId: String
    let completedAt: Date
}

/// Presentation deduplication uses the same complete identity as permission
/// routing. Tool-use ids are scoped to a session and cannot safely suppress an
/// interaction arriving from a different concurrent agent.
struct NotchInteractionToken: Hashable, Sendable {
    let sessionId: String
    let toolUseId: String
}

enum NotchFollowUpTarget: Hashable, Sendable {
    case interaction(NotchInteractionToken)
    case completion(NotchCompletionToken)

    var sessionId: String {
        switch self {
        case .interaction(let token): token.sessionId
        case .completion(let token): token.sessionId
        }
    }
}

struct NotchFollowUpCandidate: Equatable, Sendable {
    let target: NotchFollowUpTarget
    let occurredAt: Date
}

enum NotchAttentionPolicy {
    static func interactionToken(
        for session: SessionState
    ) -> NotchInteractionToken? {
        guard let toolUseId = session.pendingToolId else { return nil }
        return NotchInteractionToken(
            sessionId: session.sessionId,
            toolUseId: toolUseId
        )
    }

    /// Compact-question mode suppresses only automatic panel expansion. The
    /// session remains pending and visible in the compact notch/list, while
    /// risk-bearing approvals and plan reviews keep their urgent behavior.
    static func shouldAutoExpandInteraction(
        _ context: PermissionContext,
        expandQuestionsAutomatically: Bool
    ) -> Bool {
        context.toolName != "AskUserQuestion" ||
            expandQuestionsAutomatically
    }

    /// Select after applying compact-question policy so a newer quiet question
    /// cannot mask an older risk-bearing approval that arrived in the same
    /// published update.
    static func newestSessionToAutoExpand(
        from sessions: [SessionState],
        excluding previousTokens: Set<NotchInteractionToken>,
        expandQuestionsAutomatically: Bool
    ) -> SessionState? {
        sessions.filter { session in
            guard let token = interactionToken(for: session),
                  !previousTokens.contains(token),
                  let interaction = session.activePermission else {
                return false
            }
            return shouldAutoExpandInteraction(
                interaction,
                expandQuestionsAutomatically: expandQuestionsAutomatically
            )
        }
        .max(by: { $0.lastActivity < $1.lastActivity })
    }

    static func completionToken(
        for session: SessionState
    ) -> NotchCompletionToken? {
        guard session.phase == .waitingForInput,
              let completedAt = session.completedAt else {
            return nil
        }
        return NotchCompletionToken(
            sessionId: session.sessionId,
            completedAt: completedAt
        )
    }

    static func shouldPresent(
        _ token: NotchCompletionToken,
        presentationStartedAt: Date,
        duration: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        let age = now.timeIntervalSince(token.completedAt)
        return token.completedAt >= presentationStartedAt &&
            age >= -5 &&
            age < duration
    }

    static func isStillCurrent(
        _ token: NotchCompletionToken,
        in sessions: [SessionState]
    ) -> Bool {
        sessions.contains {
            completionToken(for: $0) == token
        }
    }

    /// Pending interactions survive app startup, so they are eligible after a
    /// full reminder delay. Completions deliberately start at this launch's
    /// observation boundary to avoid a burst of historical "done" alerts.
    static func followUpCandidates(
        in sessions: [SessionState],
        completionTrackingStartedAt: Date
    ) -> [NotchFollowUpCandidate] {
        sessions.compactMap { session in
            if let context = session.activePermission,
               let token = interactionToken(for: session) {
                return NotchFollowUpCandidate(
                    target: .interaction(token),
                    occurredAt: context.receivedAt
                )
            }

            guard let token = completionToken(for: session),
                  token.completedAt >= completionTrackingStartedAt else {
                return nil
            }
            return NotchFollowUpCandidate(
                target: .completion(token),
                occurredAt: token.completedAt
            )
        }
    }

    static func isStillCurrent(
        _ target: NotchFollowUpTarget,
        in sessions: [SessionState],
        completionTrackingStartedAt: Date
    ) -> Bool {
        followUpCandidates(
            in: sessions,
            completionTrackingStartedAt: completionTrackingStartedAt
        ).contains { $0.target == target }
    }
}
