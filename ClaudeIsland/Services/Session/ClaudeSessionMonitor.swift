//
//  Modified by lihao505 for Agent Notch, 2026.
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()
    private var hookEventTask: Task<Void, Never>?
    private var hookEventContinuation: AsyncStream<SessionEvent>.Continuation?
    private var isMonitoring = false

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // HookSocketServer accepts connections on one serial queue, but
        // launching an unstructured Task for every callback does not preserve
        // that order. One AsyncStream consumer keeps PreToolUse,
        // PermissionRequest, PostToolUse and Stop in wire order; SessionStore's
        // event timestamps provide a second guard across separate hook
        // processes.
        let (hookEvents, continuation) = AsyncStream.makeStream(
            of: SessionEvent.self
        )
        hookEventContinuation = continuation
        hookEventTask = Task {
            for await event in hookEvents {
                guard !Task.isCancelled else { break }
                await SessionStore.shared.process(event)
            }
        }

        // Start accepting fresh hooks before disk restoration yields to parser
        // I/O. SessionStore resolves the race by keeping the newest timestamp.
        HookSocketServer.shared.start(
            onEvent: { event in
                continuation.yield(.hookReceived(event))

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                continuation.yield(.permissionSocketFailed(
                    sessionId: sessionId,
                    toolUseId: toolUseId
                ))
            }
        )

        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        HookSocketServer.shared.stop()
        hookEventContinuation?.finish()
        hookEventContinuation = nil
        hookEventTask?.cancel()
        hookEventTask = nil
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(
        sessionId: String,
        expectedToolUseId: String
    ) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }
            if permission.toolUseId != expectedToolUseId {
                return
            }
            let toolUseId = permission.toolUseId

            HookSocketServer.shared.respondToPermission(
                toolUseId: toolUseId,
                sessionId: sessionId,
                decision: "allow"
            ) { delivered in
                Task {
                    await SessionStore.shared.process(
                        delivered
                            ? .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
                            : .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        }
    }

    func denyPermission(
        sessionId: String,
        expectedToolUseId: String,
        reason: String?
    ) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }
            if permission.toolUseId != expectedToolUseId {
                return
            }
            let toolUseId = permission.toolUseId

            HookSocketServer.shared.respondToPermission(
                toolUseId: toolUseId,
                sessionId: sessionId,
                decision: "deny",
                reason: reason
            ) { delivered in
                Task {
                    await SessionStore.shared.process(
                        delivered
                            ? .permissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)
                            : .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        }
    }

    /// Answer an interactive PreToolUse request. Claude Code requires the
    /// original tool input to be echoed back together with the selected
    /// answers, then explicitly allowed.
    func answerQuestions(
        sessionId: String,
        expectedToolUseId: String,
        answers: [String: String]
    ) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission,
                  permission.toolName == "AskUserQuestion",
                  permission.toolUseId == expectedToolUseId else {
                return
            }

            var updatedInput = permission.toolInput ?? [:]
            updatedInput["answers"] = AnyCodable(answers)
            let toolUseId = permission.toolUseId
            HookSocketServer.shared.respondToPermission(
                toolUseId: toolUseId,
                sessionId: sessionId,
                decision: "allow",
                updatedInput: updatedInput
            ) { delivered in
                Task {
                    await SessionStore.shared.process(
                        delivered
                            ? .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
                            : .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        }
    }

    /// ExitPlanMode also requires an echoed updatedInput when it is handled
    /// through a PreToolUse integration.
    func approvePlan(sessionId: String, expectedToolUseId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission,
                  permission.toolName == "ExitPlanMode",
                  permission.toolUseId == expectedToolUseId else {
                return
            }

            let toolUseId = permission.toolUseId
            HookSocketServer.shared.respondToPermission(
                toolUseId: toolUseId,
                sessionId: sessionId,
                decision: "allow",
                updatedInput: permission.toolInput ?? [:]
            ) { delivered in
                Task {
                    await SessionStore.shared.process(
                        delivered
                            ? .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
                            : .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        let now = Date()
        let active = sessions.filter {
            $0.completedAt == nil &&
                ($0.phase.isActive || $0.phase.isWaitingForApproval)
        }
        let recentCompleted = sessions
            .filter { session in
                guard let completedAt = session.completedAt else {
                    return false
                }
                return now.timeIntervalSince(completedAt) <
                    SessionRetentionPolicy.completedLifetime
            }
            .sorted {
                ($0.completedAt ?? .distantPast) >
                    ($1.completedAt ?? .distantPast)
            }

        let visibleCompleted: ArraySlice<SessionState>
        if active.count >= SessionRetentionPolicy.activeCrowdingThreshold {
            visibleCompleted = []
        } else {
            visibleCompleted = recentCompleted.prefix(
                SessionRetentionPolicy.maximumVisibleCompleted
            )
        }

        instances = active + visibleCompleted
        pendingInstances = active.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
