//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchFollowUpReminderCoordinator.swift
//  ClaudeIsland
//
//  Schedules exactly one cancellable follow-up for each attention generation.
//

import Combine
import Foundation
import os.log

@MainActor
final class NotchFollowUpReminderCoordinator: ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: "com.agentnotch",
        category: "Attention"
    )

    @Published private(set) var pendingTargets: Set<NotchFollowUpTarget> = []

    private var currentCandidates: [
        NotchFollowUpTarget: NotchFollowUpCandidate
    ] = [:]
    private var scheduledTasks: [
        NotchFollowUpTarget: Task<Void, Never>
    ] = [:]
    private var scheduledDueDates: [NotchFollowUpTarget: Date] = [:]
    private var deliveredTargets: Set<NotchFollowUpTarget> = []
    private var acknowledgedCompletions: Set<NotchFollowUpTarget> = []
    private var isEnabled = false
    private var enabledAt: Date?

    func reconcile(
        sessions: [SessionState],
        enabled: Bool,
        delay: TimeInterval,
        trackingStartedAt: Date,
        silenceRules: [NotchSilenceRule] = [],
        now: Date = Date()
    ) {
        var candidates: [
            NotchFollowUpTarget: NotchFollowUpCandidate
        ] = [:]
        for candidate in NotchAttentionPolicy.followUpCandidates(
            in: sessions,
            completionTrackingStartedAt: trackingStartedAt
        ) {
            candidates[candidate.target] = candidate
        }
        currentCandidates = candidates

        let currentTargets = Set(candidates.keys)
        removeStaleTargets(notIn: currentTargets)

        // Keep silenced generations in the identity ledger. Removing them
        // from the input would forget delivery history and replay old alerts
        // when a rule is disabled or matching metadata changes.
        for session in sessions where NotchSilenceRuleMatcher.isSilenced(
            by: silenceRules,
            context: NotchSilenceContext(session: session)
        ) {
            for target in currentTargets where target.sessionId == session.sessionId {
                deliveredTargets.insert(target)
                cancelScheduledTask(for: target)
                pendingTargets.remove(target)
            }
        }

        guard enabled else {
            isEnabled = false
            enabledAt = nil
            cancelScheduledTasks()
            deliveredTargets.removeAll()
            pendingTargets.removeAll()
            return
        }

        if !isEnabled {
            isEnabled = true
            enabledAt = now
        }

        let activationDate = enabledAt ?? now
        for candidate in candidates.values {
            let target = candidate.target
            guard !deliveredTargets.contains(target),
                  !acknowledgedCompletions.contains(target) else {
                cancelScheduledTask(for: target)
                continue
            }

            let baseline = max(
                candidate.occurredAt,
                trackingStartedAt,
                activationDate
            )
            let dueDate = baseline.addingTimeInterval(max(0, delay))
            if scheduledDueDates[target] == dueDate {
                continue
            }
            schedule(target, dueAt: dueDate, now: now)
        }
    }

    func acknowledgeCompletions(_ tokens: [NotchCompletionToken]) {
        for token in tokens {
            let target = NotchFollowUpTarget.completion(token)
            acknowledgedCompletions.insert(target)
            cancelScheduledTask(for: target)
            pendingTargets.remove(target)
        }
    }

    func isCurrent(_ target: NotchFollowUpTarget) -> Bool {
        currentCandidates[target] != nil
    }

    func consume(_ targets: Set<NotchFollowUpTarget>) {
        pendingTargets.subtract(targets)
    }

    func cancelAll() {
        cancelScheduledTasks()
        currentCandidates.removeAll()
        deliveredTargets.removeAll()
        acknowledgedCompletions.removeAll()
        pendingTargets.removeAll()
        isEnabled = false
        enabledAt = nil
    }

    private func schedule(
        _ target: NotchFollowUpTarget,
        dueAt: Date,
        now: Date
    ) {
        cancelScheduledTask(for: target)
        scheduledDueDates[target] = dueAt
        let remaining = max(0, dueAt.timeIntervalSince(now))
        scheduledTasks[target] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.fire(target)
        }
        let remainingText = String(format: "%.1f", remaining)
        Self.logger.debug(
            "Scheduled follow-up for \(target.sessionId.prefix(8), privacy: .public) in \(remainingText, privacy: .public)s"
        )
    }

    private func fire(_ target: NotchFollowUpTarget) {
        scheduledTasks.removeValue(forKey: target)
        scheduledDueDates.removeValue(forKey: target)
        guard isEnabled,
              currentCandidates[target] != nil,
              !acknowledgedCompletions.contains(target),
              !deliveredTargets.contains(target) else {
            return
        }
        deliveredTargets.insert(target)
        pendingTargets.insert(target)
        Self.logger.info(
            "Follow-up became due for \(target.sessionId.prefix(8), privacy: .public)"
        )
    }

    private func removeStaleTargets(
        notIn currentTargets: Set<NotchFollowUpTarget>
    ) {
        let staleTargets = Set(scheduledTasks.keys)
            .subtracting(currentTargets)
        for target in staleTargets {
            cancelScheduledTask(for: target)
        }
        deliveredTargets.formIntersection(currentTargets)
        acknowledgedCompletions.formIntersection(currentTargets)
        pendingTargets.formIntersection(currentTargets)
    }

    private func cancelScheduledTask(for target: NotchFollowUpTarget) {
        scheduledTasks.removeValue(forKey: target)?.cancel()
        scheduledDueDates.removeValue(forKey: target)
    }

    private func cancelScheduledTasks() {
        scheduledTasks.values.forEach { $0.cancel() }
        scheduledTasks.removeAll()
        scheduledDueDates.removeAll()
    }
}
