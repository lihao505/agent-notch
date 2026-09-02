//
//  Modified by lihao505 for Agent Notch, 2026.
//  SessionStore.swift
//  ClaudeIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Darwin
import Foundation
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore(
        persistenceEnabled: true,
        fileSyncEnabled: true
    )

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Session")

    /// Minimal on-disk representation used only to restore sessions whose
    /// backing process is still alive after the menu bar app restarts.
    private struct PersistedSession: Codable {
        let sessionId: String
        let cwd: String
        let projectName: String
        let source: String
        let pid: Int?
        let tty: String?
        let phase: String?
        let lastActivity: Date
        let createdAt: Date
        let lastHookEventAt: Date?
        let lastCodexTurnStartedAt: Date?
        let completedAt: Date?
    }

    /// Latest privacy-minimized lifecycle observation written by the bridge.
    /// This is separate from `PersistedSession`: the bridge keeps updating it
    /// while Agent Notch is not running, which closes the mid-turn launch gap.
    private struct BridgeSessionSnapshot: Decodable {
        let version: Int
        let observedAt: TimeInterval
        let sessionId: String
        let cwd: String
        let source: String
        let event: String
        let status: String
        let pid: Int?
        let tty: String?

        enum CodingKeys: String, CodingKey {
            case version
            case observedAt = "observed_at"
            case sessionId = "session_id"
            case cwd, source, event, status, pid, tty
        }
    }

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Periodic status check task
    private var statusCheckTask: Task<Void, Never>?

    /// A one-second fallback keeps the UI responsive if an agent drops a hook
    /// event. Normal hook delivery remains immediate.
    private let statusCheckIntervalSeconds: UInt64 = 1

    /// Codex Desktop can occasionally miss the terminal hook/row (for example
    /// after a crash). Native rollout progress normally updates far more often;
    /// after this quiet period an old active boundary is no longer credible.
    private let codexActiveStaleInterval: TimeInterval = 10 * 60

    /// A live PID plus a recent observation prevents PID reuse from reviving an
    /// unrelated process. This is intentionally longer than a typical tool run
    /// so Agent Notch can still join long-running work already in progress.
    private let bridgeSnapshotMaximumAge: TimeInterval = 24 * 60 * 60

    private static let bridgeSnapshotMaximumBytes: UInt64 = 64 * 1024

    /// Restoration is deliberately deferred until monitoring starts, so the
    /// actor is fully initialized before any filesystem or process inspection.
    private var didRestorePersistedSessions = false

    /// Rollout discovery closes the gap when Codex Desktop omits a
    /// UserPromptSubmit hook. The watermark is captured before each scan and
    /// overlapped slightly so a file write racing the enumeration is retried.
    private var lastCodexDiscoverySweepAt: Date?
    private let persistenceEnabled: Bool
    private let fileSyncEnabled: Bool

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    /// Dependency switches keep reducer tests isolated from the user's live
    /// session files while production continues using the shared instance.
    init(persistenceEnabled: Bool, fileSyncEnabled: Bool) {
        self.persistenceEnabled = persistenceEnabled
        self.fileSyncEnabled = fileSyncEnabled
    }

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.sessionId
        let receivedAt = Date()
        let observedAt = event.lifecycleObservedDate(receivedAt: receivedAt)
        let eventSource = event.source == nil
            ? AgentSource.claude
            : AgentSource(hookValue: event.source)
        let eventProjectName = URL(
            fileURLWithPath: event.cwd
        ).lastPathComponent
        if SessionRetentionPolicy.isIgnoredProbe(
            source: eventSource,
            cwd: event.cwd,
            projectName: eventProjectName
        ) {
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            return
        }

        let isNewSession = !sessions.keys.contains(sessionId)
        var session = sessions[sessionId] ?? createSession(
            from: event,
            observedAt: observedAt
        )
        let shouldApplyLifecycle = session.lastHookEventAt.map {
            observedAt >= $0
        } ?? true

        if shouldApplyLifecycle {
            let normalizedTTY = event.tty?.replacingOccurrences(
                of: "/dev/",
                with: ""
            )
            let pidChanged = session.pid != event.pid
            let ttyChanged = normalizedTTY.map { session.tty != $0 } ?? false
            session.pid = event.pid
            if event.source != nil {
                session.source = AgentSource(hookValue: event.source)
            }
            // Process ancestry is topology, not lifecycle state. Resolve it
            // only when the session first appears or its PID/TTY changes;
            // periodic reconciliation remains the fallback for a missed race.
            if let pid = event.pid,
               isNewSession || pidChanged || ttyChanged {
                let tree = ProcessTreeBuilder.shared.buildTree(
                    forceRefresh: isNewSession || pidChanged
                )
                session.isInTmux = ProcessTreeBuilder.shared.isInTmux(
                    pid: pid,
                    tree: tree
                )
            }
            if let normalizedTTY {
                session.tty = normalizedTTY
            }
            session.lastHookEventAt = observedAt
            session.lastActivity = max(session.lastActivity, observedAt)
        } else {
            Self.logger.info(
                "Ignoring stale phase event \(event.event, privacy: .public) for \(sessionId.prefix(8), privacy: .public)"
            )
        }

        if event.status == "ended" {
            guard shouldApplyLifecycle else {
                sessions[sessionId] = session
                return
            }
            if event.event == "SessionExpired" {
                sessions.removeValue(forKey: sessionId)
            } else {
                session.phase = .ended
                session.completedAt = session.completedAt ?? observedAt
                session.pid = nil
                sessions[sessionId] = session
            }
            cancelPendingSync(sessionId: sessionId)
            return
        }

        let newPhase = event.determinePhase()

        // Any fresh active signal can recover a resumed conversation when
        // UserPromptSubmit was dropped. SessionStart alone is intentionally
        // excluded because opening a dormant session is not a new turn.
        let startsNewTurn = shouldApplyLifecycle && (
            newPhase.isActive ||
            newPhase.isWaitingForApproval
        )
        if startsNewTurn &&
           (session.phase == .ended || session.completedAt != nil) {
            session.phase = .idle
            session.completedAt = nil
        }

        let isDuplicateInteractiveObservation: Bool
        if case .waitingForApproval(let permission) = session.phase {
            isDuplicateInteractiveObservation = event.event == "PreToolUse"
                && event.status != "waiting_for_approval"
                && event.toolUseId == permission.toolUseId
        } else {
            isDuplicateInteractiveObservation = false
        }

        let previousPhase = session.phase
        if !shouldApplyLifecycle {
            // Tool tracking below still consumes the event. Only its lifecycle
            // mutation is stale.
        } else if isDuplicateInteractiveObservation {
            Self.logger.debug(
                "Keeping interactive approval state for duplicate PreToolUse observation"
            )
        } else if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        let isCompletionSignal =
            event.event == "Stop" ||
            event.event == "StopFailure" ||
            (event.event == "Notification" &&
                event.notificationType == "idle_prompt")
        if shouldApplyLifecycle && isCompletionSignal {
            // Completion must be visible even when a missed start/tool hook
            // left the session in idle. Relying only on canTransition used to
            // set completedAt while leaving phase == idle, so the compact
            // completion animation could never appear.
            session.phase = .waitingForInput
            session.completedAt = observedAt
        } else if shouldApplyLifecycle && (
                    newPhase.isActive ||
                    newPhase.isWaitingForApproval
                  ) {
            session.completedAt = nil
        }

        if shouldApplyLifecycle && previousPhase != session.phase {
            let latencyMs = max(
                0,
                Int(receivedAt.timeIntervalSince(observedAt) * 1_000)
            )
            Self.logger.info(
                "Phase \(String(describing: previousPhase), privacy: .public) -> \(String(describing: session.phase), privacy: .public) via \(event.event, privacy: .public) (\(latencyMs)ms)"
            )
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if shouldApplyLifecycle && isCompletionSignal {
            finalizeDanglingTools(in: &session)
        }

        sessions[sessionId] = session

        if fileSyncEnabled && event.shouldSyncFile {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd)
        }
    }

    private func createSession(
        from event: HookEvent,
        observedAt: Date
    ) -> SessionState {
        let source = event.source == nil ? .claude : AgentSource(hookValue: event.source)
        let codexTitle = source == .codex
            ? ConversationParser.codexThreadTitle(sessionId: event.sessionId)
            : nil
        return SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            source: source,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle,
            conversationInfo: ConversationInfo(
                summary: codexTitle,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            ),
            lastActivity: observedAt,
            createdAt: observedAt,
            lastHookEventAt: observedAt
        )
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && !ToolCallItem.isSubagentContainerName(toolName)
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse", "PostToolUseFailure":
            if let toolUseId = event.toolUseId {
                let succeeded = event.event == "PostToolUse"
                session.toolTracker.completeTool(
                    id: toolUseId,
                    success: succeeded
                )
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = succeeded ? .success : .error
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task/Agent subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolName = event.tool,
                      let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool is starting. Add it to the parent Task/Agent's
                // subagent list and sync to chatItems so the UI updates live (rather
                // than only after the parent Agent completes).
                var input: [String: String] = [:]
                if let hookInput = event.toolInput {
                    for (key, value) in hookInput {
                        if let str = value.value as? String {
                            input[key] = str
                        } else if let num = value.value as? Int {
                            input[key] = String(num)
                        } else if let bool = value.value as? Bool {
                            input[key] = bool ? "true" : "false"
                        }
                    }
                }
                let subagentTool = SubagentToolCall(
                    id: toolUseId,
                    name: toolName,
                    input: input,
                    status: .running,
                    timestamp: Date()
                )
                session.subagentState.addSubagentTool(subagentTool)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "PostToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                // Agent tool returned — the subagent has finished. Stop
                // tracking so subsequent tools in the parent turn don't get
                // attached to this dead task.
                session.subagentState.stopTask(taskToolId: toolUseId)
                Self.logger.debug("Stopped subagent tracking for \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool completed. Update its status in the
                // parent's subagent list and sync.
                session.subagentState.updateSubagentToolStatus(toolId: toolUseId, status: .success)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    /// Push the current subagent tool lists from subagentState into the
    /// corresponding ChatHistoryItem.subagentTools so the UI renders them live.
    private func syncSubagentToolsToChatItems(session: inout SessionState) {
        for (taskToolId, context) in session.subagentState.activeTasks {
            guard !context.subagentTools.isEmpty else { continue }
            for i in 0..<session.chatItems.count {
                if session.chatItems[i].id == taskToolId,
                   case .toolCall(var tool) = session.chatItems[i].type {
                    tool.subagentTools = context.subagentTools
                    session.chatItems[i] = ChatHistoryItem(
                        id: taskToolId,
                        type: .toolCall(tool),
                        timestamp: session.chatItems[i].timestamp
                    )
                    break
                }
            }
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        // Update summary/last-message metadata from the parser's current
        // snapshot. For native transcripts this must not advance the shared
        // message cursor: rows appended after the payload was created belong
        // to the next incremental sync.
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.sessionId,
            cwd: payload.cwd
        )

        // ConversationParser is another actor, so this actor may process a
        // Stop/PermissionRequest/SessionExpired while the file is being read.
        // Re-fetch after the await instead of mutating a snapshot that could
        // now be stale or whose session may already have been removed.
        guard var session = sessions[payload.sessionId] else { return }
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .image, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        reconcilePhaseFromTranscript(
            payload: payload,
            session: &session
        )

        // Commit all synchronous transcript changes before the subagent parser
        // yields this actor again.
        sessions[payload.sessionId] = session

        let subagentDecorations = await loadSubagentToolsFromAgentFiles(
            sessionId: payload.sessionId,
            session: session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        guard var latestSession = sessions[payload.sessionId] else {
            // SessionExpired/SessionEnd arrived while subagent files were read.
            // Never resurrect the removed session from the pre-await snapshot.
            return
        }

        // Only merge the fields produced by the awaited subagent reads into the
        // latest value. A concurrent Stop/PermissionRequest may have changed
        // phase, completion, tool status, or even cleared chat items; none of
        // those authoritative fields are copied back from the old snapshot.
        for decoration in subagentDecorations {
            guard let index = latestSession.chatItems.firstIndex(where: {
                $0.id == decoration.taskToolId
            }), case .toolCall(var tool) = latestSession.chatItems[index].type else {
                continue
            }
            tool.subagentTools = decoration.tools
            latestSession.chatItems[index] = ChatHistoryItem(
                id: decoration.taskToolId,
                type: .toolCall(tool),
                timestamp: latestSession.chatItems[index].timestamp
            )
            if let description = decoration.description {
                latestSession.subagentState.agentDescriptions[
                    decoration.agentId
                ] = description
            }
        }
        sessions[payload.sessionId] = latestSession
        publishState()

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: latestSession,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    private struct SubagentFileDecoration {
        let taskToolId: String
        let agentId: String
        let description: String?
        let tools: [SubagentToolCall]
    }

    /// Read Task/Agent JSONL files without retaining an inout SessionState
    /// across actor suspension. The caller merges these narrow decorations into
    /// the latest session after the await.
    private func loadSubagentToolsFromAgentFiles(
        sessionId: String,
        session: SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async -> [SubagentFileDecoration] {
        var decorations: [SubagentFileDecoration] = []
        for i in 0..<session.chatItems.count {
            guard case .toolCall(let tool) = session.chatItems[i].type,
                  tool.isSubagentContainer,
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            let description = session.subagentState.activeTasks[
                taskToolId
            ]?.description ?? tool.input["description"]

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                sessionId: sessionId,
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            let tools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }
            decorations.append(SubagentFileDecoration(
                taskToolId: taskToolId,
                agentId: taskResult.agentId,
                description: description,
                tools: tools
            ))

            Self.logger.debug(
                "Loaded \(tools.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)"
            )
        }
        return decorations
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty text blocks — assistant turns with only tool calls
            // produce empty text blocks that would render as orphan dots/gaps.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            // Skip empty thinking blocks — streaming can briefly produce empty
            // ones that would render as orphan grey dots.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .image(let imageBlock):
            let itemId = "\(message.id)-image-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .image(imageBlock), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    /// A terminal turn signal is authoritative even if a PostToolUse row or
    /// hook was dropped. Leaving those placeholders running made every later
    /// idle turn look permanently active.
    private func finalizeDanglingTools(in session: inout SessionState) {
        for index in session.chatItems.indices {
            guard case .toolCall(var tool) = session.chatItems[index].type,
                  tool.status == .running ||
                    tool.status == .waitingForApproval else {
                continue
            }
            tool.status = .interrupted
            session.chatItems[index] = ChatHistoryItem(
                id: session.chatItems[index].id,
                type: .toolCall(tool),
                timestamp: session.chatItems[index].timestamp
            )
        }
        session.toolTracker.inProgress.removeAll()
        session.subagentState = SubagentState()
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
        publishState()
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Read metadata from the state populated above. Native metadata reads
        // deliberately do not advance the message cursor, so rows appended
        // between these calls remain available to the next incremental sync.
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                }
            }
        }

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        // A restored Claude process can outlive a turn whose Stop hook was
        // missed. Its existing final assistant row is still an authoritative
        // completion boundary when history is first loaded.
        reconcilePhaseFromTranscript(
            payload: FileUpdatePayload(
                sessionId: sessionId,
                cwd: session.cwd,
                messages: messages,
                isIncremental: false,
                completedToolIds: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults
            ),
            session: &session
        )

        sessions[sessionId] = session
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            // Metadata-only and tool-result rows still need reconciliation,
            // but an unchanged Codex rollout must not trigger another title,
            // policy-tail, or full transcript read every second.
            guard !result.newMessages.isEmpty ||
                    result.clearDetected ||
                    result.fileAdvanced else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    /// Transcript updates are a fallback for a missed socket hook. A new user
    /// row or running tool means work is active; a final assistant text with no
    /// running tool means the turn has completed.
    private func reconcilePhaseFromTranscript(
        payload: FileUpdatePayload,
        session: inout SessionState
    ) {
        // Codex synthetic transcripts are presentation data. They may retain
        // a tool placeholder when a native hook is missed, so letting them
        // drive lifecycle would overwrite the authoritative task boundary
        // read from Codex Desktop's rollout and cause active/completed flapping.
        guard session.source != .codex else { return }
        guard !session.phase.isWaitingForApproval else { return }

        let lastMessage = payload.messages.max(by: {
            $0.timestamp < $1.timestamp
        })
        let lastAssistantStartsTool = lastMessage?.content.contains { block in
            if case .toolUse = block { return true }
            return false
        } ?? false

        // A text-only final assistant turn is a terminal boundary. Close any
        // stale tool placeholders before looking at the historical tool list;
        // otherwise a missed result from an old turn wins forever.
        if let lastMessage,
           lastMessage.role == .assistant,
           !lastAssistantStartsTool,
           !lastMessage.textContent.trimmingCharacters(
                in: .whitespacesAndNewlines
           ).isEmpty {
            finalizeDanglingTools(in: &session)
            session.phase = .waitingForInput
            session.completedAt = session.completedAt ?? Date()
            return
        }

        let hasRunningTool = session.chatItems.contains { item in
            guard case .toolCall(let tool) = item.type else {
                return false
            }
            return tool.status == .running ||
                tool.status == .waitingForApproval
        }

        if hasRunningTool {
            session.phase = .processing
            session.completedAt = nil
            return
        }

        guard let lastMessage else {
            return
        }

        if lastMessage.role == .user {
            session.phase = .processing
            session.completedAt = nil
        }
    }

    // MARK: - Periodic Status Check

    /// Start periodic status checking for all sessions
    func startPeriodicStatusCheck() async {
        if !didRestorePersistedSessions {
            didRestorePersistedSessions = true
            await restorePersistedSessions()
            await restoreBridgeSessionSnapshots()
        }

        guard statusCheckTask == nil else { return }

        let intervalSeconds = statusCheckIntervalSeconds
        statusCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.recheckAllSessions()
            }
        }
        Self.logger.info("Started periodic status check (every \(intervalSeconds)s)")
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
        Self.logger.info("Stopped periodic status check")
    }

    /// Recheck status of all active sessions
    private func recheckAllSessions() async {
        var stateChanged = false
        let now = Date()

        let discoveryStartedAt = Date()
        let discoveryThreshold = lastCodexDiscoverySweepAt ??
            now.addingTimeInterval(-codexActiveStaleInterval)
        let discoveredCodexTasks = await ConversationParser.shared
            .discoverCodexTasks(modifiedAfter: discoveryThreshold)
        lastCodexDiscoverySweepAt = discoveryStartedAt.addingTimeInterval(-2)
        for observation in discoveredCodexTasks {
            if reconcileCodexLifecycle(
                observation,
                now: now,
                allowCreation: true
            ) {
                stateChanged = true
            }
        }

        for sessionId in Array(sessions.keys) {
            guard var session = sessions[sessionId] else {
                continue
            }
            if SessionRetentionPolicy.isIgnoredProbe(
                source: session.source,
                cwd: session.cwd,
                projectName: session.projectName
            ) {
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
                stateChanged = true
                continue
            }

            if session.source == .codex {
                let observedLastActivity = session.lastActivity
                let lifecycle = await ConversationParser.shared
                    .codexTaskLifecycle(sessionId: sessionId)
                // The actor is reentrant while the parser reads the rollout.
                // A Stop/SessionExpired hook may have updated or removed this
                // session during that await. Never resurrect the old snapshot
                // or overwrite a newer authoritative hook with stale parsing.
                guard let latestSession = sessions[sessionId] else {
                    continue
                }
                session = latestSession

                if session.lastActivity <= observedLastActivity {
                    let observation = CodexTaskObservation(
                        sessionId: sessionId,
                        cwd: session.cwd,
                        lifecycle: lifecycle,
                        fileModifiedAt: now
                    )
                    if reconcileCodexLifecycle(
                        observation,
                        now: now,
                        allowCreation: false
                    ) {
                        stateChanged = true
                    }
                    if !sessions.keys.contains(sessionId) {
                        continue
                    }
                }
                guard let reconciledSession = sessions[sessionId] else {
                    continue
                }
                session = reconciledSession
            }

            if session.phase == .ended {
                if let completedAt = session.completedAt,
                   now.timeIntervalSince(completedAt) >=
                    SessionRetentionPolicy.completedLifetime {
                    sessions.removeValue(forKey: sessionId)
                    cancelPendingSync(sessionId: sessionId)
                    stateChanged = true
                }
                continue
            }

            // Lifecycle polling above is enough to notice a resumed Codex
            // rollout. Avoid reparsing every hidden completed transcript once
            // per second during the five-hour retention window.
            if session.completedAt != nil {
                continue
            }

            if let pid = session.pid {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    Self.logger.info("Process \(pid) no longer running, ending session \(sessionId.prefix(8))")
                    session.pid = nil
                    session.phase = .ended
                    session.completedAt = session.completedAt ?? now
                    sessions[sessionId] = session
                    cancelPendingSync(sessionId: sessionId)
                    stateChanged = true
                    continue
                }
            }

            // Reconcile every live session. This recovers from an occasional
            // missed UserPromptSubmit/PreToolUse socket event without waiting
            // for a later hook to repair the visible state.
            scheduleFileSync(sessionId: sessionId, cwd: session.cwd)
        }

        if stateChanged {
            publishState()
        }
    }

    /// Merge Codex's native turn boundary without letting generic activity
    /// evidence cross a completion boundary. This is the central arbitration
    /// rule shared by discovery and the one-second fallback poll.
    @discardableResult
    private func reconcileCodexLifecycle(
        _ observation: CodexTaskObservation,
        now: Date,
        allowCreation: Bool
    ) -> Bool {
        let sessionId = observation.sessionId

        switch observation.lifecycle {
        case .active(let turnStartedAt, let lastEvidenceAt):
            let evidenceAt = lastEvidenceAt ??
                turnStartedAt ??
                observation.fileModifiedAt

            guard var session = sessions[sessionId] else {
                guard allowCreation,
                      now.timeIntervalSince(evidenceAt) <
                        codexActiveStaleInterval else {
                    return false
                }
                let projectName = URL(
                    fileURLWithPath: observation.cwd
                ).lastPathComponent
                let title = ConversationParser.codexThreadTitle(
                    sessionId: sessionId
                )
                sessions[sessionId] = SessionState(
                    sessionId: sessionId,
                    cwd: observation.cwd,
                    projectName: projectName,
                    source: .codex,
                    phase: .processing,
                    conversationInfo: ConversationInfo(
                        summary: title,
                        lastMessage: nil,
                        lastMessageRole: nil,
                        lastToolName: nil,
                        firstUserMessage: nil,
                        lastUserMessageDate: nil
                    ),
                    lastActivity: evidenceAt,
                    createdAt: turnStartedAt ?? evidenceAt,
                    lastCodexTurnStartedAt: turnStartedAt
                )
                scheduleFileSync(
                    sessionId: sessionId,
                    cwd: observation.cwd
                )
                Self.logger.info(
                    "Discovered active Codex turn \(sessionId.prefix(8), privacy: .public) from native rollout"
                )
                return true
            }

            let newestEvidenceAt = max(
                evidenceAt,
                session.lastHookEventAt ?? .distantPast
            )
            let isStale = now.timeIntervalSince(newestEvidenceAt) >=
                codexActiveStaleInterval
            if !session.phase.isWaitingForApproval && isStale {
                guard session.completedAt == nil ||
                        session.phase != .waitingForInput else {
                    return false
                }
                session.phase = .waitingForInput
                session.completedAt = now
                finalizeDanglingTools(in: &session)
                sessions[sessionId] = session
                return true
            }

            if let completedAt = session.completedAt {
                // Token counts and commentary from the completed turn can be
                // newer than Stop. Only a genuinely newer task_started (or a
                // safe fallback boundary) may revive the card.
                guard let turnStartedAt,
                      turnStartedAt > completedAt else {
                    return false
                }
            }

            let previousPhase = session.phase
            let previousCompletion = session.completedAt
            let previousActivity = session.lastActivity
            session.source = .codex
            session.lastCodexTurnStartedAt = turnStartedAt ??
                session.lastCodexTurnStartedAt
            session.lastActivity = max(session.lastActivity, evidenceAt)
            if !session.phase.isWaitingForApproval &&
               !session.phase.isActive {
                session.phase = .processing
            }
            if !session.phase.isWaitingForApproval {
                session.completedAt = nil
            }
            sessions[sessionId] = session
            return previousPhase != session.phase ||
                previousCompletion != session.completedAt ||
                previousActivity != session.lastActivity

        case .completed(let completedAt):
            guard var session = sessions[sessionId],
                  !session.phase.isWaitingForApproval else {
                return false
            }
            let completionEvidenceAt = completedAt ??
                observation.fileModifiedAt
            if session.completedAt == nil,
               let lastHookEventAt = session.lastHookEventAt,
               lastHookEventAt > completionEvidenceAt {
                return false
            }
            if let turnStartedAt = session.lastCodexTurnStartedAt,
               turnStartedAt > completionEvidenceAt {
                return false
            }
            guard session.completedAt == nil ||
                    session.phase != .waitingForInput else {
                return false
            }
            session.phase = .waitingForInput
            session.completedAt = completionEvidenceAt
            session.lastActivity = max(
                session.lastActivity,
                completionEvidenceAt
            )
            finalizeDanglingTools(in: &session)
            sessions[sessionId] = session
            return true

        case .missing:
            guard sessions[sessionId] != nil,
                  let session = sessions[sessionId],
                  now.timeIntervalSince(session.lastActivity) >=
                    SessionRetentionPolicy.missingCodexGracePeriod else {
                return false
            }
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            return true

        case .unknown:
            guard var session = sessions[sessionId],
                  !session.phase.isWaitingForApproval,
                  session.phase.isActive,
                  now.timeIntervalSince(session.lastActivity) >=
                    codexActiveStaleInterval else {
                return false
            }
            session.phase = .waitingForInput
            session.completedAt = now
            finalizeDanglingTools(in: &session)
            sessions[sessionId] = session
            return true
        }
    }

    /// Check if a process is still running
    private nonisolated func isProcessRunning(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }

    // MARK: - State Publishing

    private func publishState() {
        pruneCompletedSessions()
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
        if persistenceEnabled {
            persistActiveSessions()
        }
    }

    private func pruneCompletedSessions(now: Date = Date()) {
        // Keep recent completed sessions in the backing store so an open chat
        // cannot disappear merely because another task finished. The monitor
        // applies `maximumVisibleCompleted` to the notch list; storage cleanup
        // is time-based only.
        let sessionsToRemove: [SessionState] = sessions.values.compactMap {
            session -> SessionState? in
            guard let completedAt = session.completedAt else { return nil }
            let expired = now.timeIntervalSince(completedAt) >=
                SessionRetentionPolicy.completedLifetime
            return expired ? session : nil
        }

        for session in sessionsToRemove {
            sessions.removeValue(forKey: session.sessionId)
            cancelPendingSync(sessionId: session.sessionId)
        }
    }

    // MARK: - Active Session Persistence

    private static var persistenceURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return baseURL
            .appendingPathComponent("MultiAgent Notch", isDirectory: true)
            .appendingPathComponent("active-sessions.json", isDirectory: false)
    }

    private static var bridgeSnapshotDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".multiagent-notch", isDirectory: true)
            .appendingPathComponent("session-state", isDirectory: true)
    }

    /// Persist sessions with a live backing process, recent native Codex
    /// activity, or a recent completion. Codex Desktop tasks discovered from
    /// rollouts intentionally have no per-task PID; dropping them here makes
    /// a correctly discovered mid-turn card disappear again on restart.
    private func persistActiveSessions() {
        let now = Date()
        let active = sessions.values.compactMap { session -> PersistedSession? in
            let isRecentCompletion: Bool
            if let completedAt = session.completedAt {
                isRecentCompletion = now.timeIntervalSince(completedAt) <
                    SessionRetentionPolicy.completedLifetime
            } else {
                isRecentCompletion = false
            }
            let livePid = session.pid.flatMap {
                isProcessRunning(pid: $0) ? $0 : nil
            }
            let hasRecentNativeCodexActivity = session.source == .codex &&
                session.phase.isActive &&
                now.timeIntervalSince(session.lastActivity) <
                    codexActiveStaleInterval
            guard isRecentCompletion ||
                    livePid != nil ||
                    hasRecentNativeCodexActivity else {
                return nil
            }

            return PersistedSession(
                sessionId: session.sessionId,
                cwd: session.cwd,
                projectName: session.projectName,
                source: session.source.rawValue,
                pid: livePid,
                tty: session.tty,
                phase: session.phase.description,
                lastActivity: session.lastActivity,
                createdAt: session.createdAt,
                lastHookEventAt: session.lastHookEventAt,
                lastCodexTurnStartedAt: session.lastCodexTurnStartedAt,
                completedAt: session.completedAt
            )
        }

        let url = Self.persistenceURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(active).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            Self.logger.error(
                "Failed to persist active sessions: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Restore cards only when their original process is still alive. A
    /// permission request cannot safely survive an app/socket restart, so
    /// restored sessions always begin idle and are refreshed from their JSONL.
    private func restorePersistedSessions() async {
        let url = Self.persistenceURL
        guard let data = try? Data(contentsOf: url) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let persisted = try? decoder.decode([PersistedSession].self, from: data) else {
            Self.logger.warning("Ignoring unreadable active session snapshot")
            return
        }

        let processTree = ProcessTreeBuilder.shared.buildTree()
        var restoredCount = 0
        var restoredActiveSessions: [(sessionId: String, cwd: String)] = []

        let now = Date()
        let retainedCompletionIds = Set(
            persisted
                .filter { item in
                    guard let completedAt = item.completedAt else {
                        return false
                    }
                    return now.timeIntervalSince(completedAt) <
                        SessionRetentionPolicy.completedLifetime
                }
                .sorted {
                    ($0.completedAt ?? .distantPast) >
                        ($1.completedAt ?? .distantPast)
                }
                .prefix(SessionRetentionPolicy.maximumVisibleCompleted)
                .map(\.sessionId)
        )
        for item in persisted where !sessions.keys.contains(item.sessionId) {
            let source = AgentSource(rawValue: item.source) ?? .unknown
            if SessionRetentionPolicy.isIgnoredProbe(
                source: source,
                cwd: item.cwd,
                projectName: item.projectName
            ) {
                continue
            }

            let livePid = item.pid.flatMap {
                isProcessRunning(pid: $0) ? $0 : nil
            }
            let isRecentCompletion: Bool
            if let completedAt = item.completedAt {
                isRecentCompletion = now.timeIntervalSince(completedAt) <
                    SessionRetentionPolicy.completedLifetime
            } else {
                isRecentCompletion = false
            }
            guard livePid != nil ||
                    (isRecentCompletion &&
                        retainedCompletionIds.contains(item.sessionId)) else {
                continue
            }

            let codexTitle = source == .codex
                ? ConversationParser.codexThreadTitle(sessionId: item.sessionId)
                : nil
            let codexLifecycle = source == .codex
                ? await ConversationParser.shared.codexTaskLifecycle(
                    sessionId: item.sessionId
                )
                : .unknown
            if codexLifecycle == .missing,
               now.timeIntervalSince(item.lastActivity) >=
                SessionRetentionPolicy.missingCodexGracePeriod {
                continue
            }

            let lifecycleCompletion: Date?
            if case .completed(let completedAt) = codexLifecycle {
                lifecycleCompletion = completedAt ?? now
            } else {
                lifecycleCompletion = item.completedAt
            }
            let restoredPhase: SessionPhase
            let lifecycleStartsNewerTurn: Bool
            if case .active(let turnStartedAt, _) = codexLifecycle,
               let turnStartedAt {
                lifecycleStartsNewerTurn = item.completedAt.map {
                    turnStartedAt > $0
                } ?? true
            } else {
                lifecycleStartsNewerTurn = false
            }
            if lifecycleStartsNewerTurn {
                restoredPhase = .processing
            } else if lifecycleCompletion != nil {
                restoredPhase = item.phase == "ended"
                    ? .ended
                    : .waitingForInput
            } else {
                switch item.phase {
                case "processing": restoredPhase = .processing
                case "compacting": restoredPhase = .compacting
                default: restoredPhase = .idle
                }
            }
            let session = SessionState(
                sessionId: item.sessionId,
                cwd: item.cwd,
                projectName: item.projectName,
                source: source,
                pid: livePid,
                tty: item.tty,
                isInTmux: livePid.map {
                    ProcessTreeBuilder.shared.isInTmux(
                        pid: $0,
                        tree: processTree
                    )
                } ?? false,
                phase: restoredPhase,
                conversationInfo: ConversationInfo(
                    summary: codexTitle,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: nil,
                    lastUserMessageDate: nil
                ),
                lastActivity: item.lastActivity,
                createdAt: item.createdAt,
                lastHookEventAt: item.lastHookEventAt,
                lastCodexTurnStartedAt: item.lastCodexTurnStartedAt,
                completedAt: lifecycleStartsNewerTurn
                    ? nil
                    : lifecycleCompletion
            )

            // The socket starts concurrently with restoration. A fresh hook is
            // authoritative and must not be overwritten by an older disk row
            // after the parser await above yields this actor.
            if let current = sessions[item.sessionId],
               current.lastActivity >= item.lastActivity {
                continue
            }
            sessions[item.sessionId] = session
            if lifecycleCompletion == nil {
                restoredActiveSessions.append((item.sessionId, item.cwd))
            }
            restoredCount += 1
        }

        publishState()
        // Only active sessions need eager chat restoration. Recent completed
        // cards keep lightweight metadata and load their potentially enormous
        // transcript lazily if the user explicitly opens the conversation.
        for item in restoredActiveSessions {
            await loadHistoryFromFile(sessionId: item.sessionId, cwd: item.cwd)
        }
        if restoredCount > 0 {
            Self.logger.info("Restored \(restoredCount) active sessions")
        }
    }

    /// Import active bridge observations that were written while the app was
    /// offline. Completed/idle observations are deliberately ignored: the
    /// normal app snapshot already owns completion retention, and an approval
    /// socket cannot be reconstructed after restart.
    private func restoreBridgeSessionSnapshots() async {
        let directory = Self.bridgeSnapshotDirectory
        guard Self.isOwnedDirectory(directory) else { return }

        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let activeStatuses: Set<String> = [
            "starting",
            "processing",
            "running_tool",
            "compacting",
            "waiting_for_approval",
        ]
        let now = Date()
        let processTree = ProcessTreeBuilder.shared.buildTree()
        var restored: [(sessionId: String, cwd: String)] = []

        for file in files where file.pathExtension == "json" {
            guard Self.isOwnedRegularFile(file),
                  let values = try? file.resourceValues(forKeys: resourceKeys),
                  let byteCount = values.fileSize,
                  byteCount > 0,
                  UInt64(byteCount) <= Self.bridgeSnapshotMaximumBytes,
                  let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(
                    BridgeSessionSnapshot.self,
                    from: data
                  ),
                  snapshot.version == 1,
                  !snapshot.sessionId.isEmpty,
                  !snapshot.cwd.isEmpty,
                  activeStatuses.contains(snapshot.status),
                  let pid = snapshot.pid,
                  pid > 1,
                  isProcessRunning(pid: pid) else {
                continue
            }

            let observedAt = Date(timeIntervalSince1970: snapshot.observedAt)
            let age = now.timeIntervalSince(observedAt)
            guard age >= -5 * 60,
                  age <= bridgeSnapshotMaximumAge else {
                continue
            }

            let source = AgentSource(hookValue: snapshot.source)
            let projectName = URL(
                fileURLWithPath: snapshot.cwd
            ).lastPathComponent
            guard !SessionRetentionPolicy.isIgnoredProbe(
                source: source,
                cwd: snapshot.cwd,
                projectName: projectName
            ) else {
                continue
            }

            // Codex has an explicit native turn boundary. It wins over a stale
            // active hook snapshot left by a dropped Stop event.
            if source == .codex {
                let lifecycle = await ConversationParser.shared
                    .codexTaskLifecycle(sessionId: snapshot.sessionId)
                if case .completed = lifecycle {
                    continue
                }
            }

            // A hook may arrive while the lifecycle parser above is awaiting.
            // Keep the newer in-memory observation in that race.
            if let current = sessions[snapshot.sessionId],
               current.lastActivity >= observedAt {
                continue
            }

            let restoredPhase: SessionPhase = snapshot.status == "compacting"
                ? .compacting
                : .processing
            if var existing = sessions[snapshot.sessionId] {
                existing.source = source
                existing.pid = pid
                existing.tty = snapshot.tty?.replacingOccurrences(
                    of: "/dev/",
                    with: ""
                )
                existing.isInTmux = ProcessTreeBuilder.shared.isInTmux(
                    pid: pid,
                    tree: processTree
                )
                existing.phase = restoredPhase
                existing.lastActivity = observedAt
                existing.lastHookEventAt = observedAt
                existing.completedAt = nil
                sessions[snapshot.sessionId] = existing
            } else {
                let codexTitle = source == .codex
                    ? ConversationParser.codexThreadTitle(
                        sessionId: snapshot.sessionId
                    )
                    : nil
                sessions[snapshot.sessionId] = SessionState(
                    sessionId: snapshot.sessionId,
                    cwd: snapshot.cwd,
                    projectName: projectName,
                    source: source,
                    pid: pid,
                    tty: snapshot.tty?.replacingOccurrences(
                        of: "/dev/",
                        with: ""
                    ),
                    isInTmux: ProcessTreeBuilder.shared.isInTmux(
                        pid: pid,
                        tree: processTree
                    ),
                    phase: restoredPhase,
                    conversationInfo: ConversationInfo(
                        summary: codexTitle,
                        lastMessage: nil,
                        lastMessageRole: nil,
                        lastToolName: nil,
                        firstUserMessage: nil,
                        lastUserMessageDate: nil
                    ),
                    lastActivity: observedAt,
                    createdAt: observedAt,
                    lastHookEventAt: observedAt
                )
            }
            restored.append((snapshot.sessionId, snapshot.cwd))
        }

        guard !restored.isEmpty else { return }
        publishState()
        for item in restored {
            await loadHistoryFromFile(
                sessionId: item.sessionId,
                cwd: item.cwd
            )
        }
        Self.logger.info(
            "Restored \(restored.count) sessions from offline bridge snapshots"
        )
    }

    private nonisolated static func isOwnedDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFDIR &&
            metadata.st_uid == getuid()
    }

    private nonisolated static func isOwnedRegularFile(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG &&
            metadata.st_uid == getuid()
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
