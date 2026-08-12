//
//  Modified by lihao505 for Agent Notch, 2026.
//  ConversationParser.swift
//  ClaudeIsland
//
//  Parses Claude JSONL conversation files to extract summary and last message
//  Optimized for incremental parsing - only reads new lines since last sync
//

import Foundation
import os.log

/// Token usage information from a session
struct UsageInfo: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    nonisolated init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Formatted string for display (e.g., "12.5K tokens")
    var formattedTotal: String {
        let total = totalTokens
        if total >= 1_000_000 {
            return String(format: "%.1fM", Double(total) / 1_000_000)
        } else if total >= 1_000 {
            return String(format: "%.1fK", Double(total) / 1_000)
        }
        return "\(total)"
    }
}

struct ConversationInfo: Equatable {
    let summary: String?
    let lastMessage: String?
    let lastMessageRole: String?  // "user", "assistant", or "tool"
    let lastToolName: String?  // Tool name if lastMessageRole is "tool"
    let firstUserMessage: String?  // Fallback title when no summary
    let lastUserMessageDate: Date?  // Timestamp of last user message (for stable sorting)
    var usage: UsageInfo = UsageInfo()  // Token usage stats
    /// Native agent policy when the source exposes one. Codex writes this in
    /// turn_context/thread_settings_applied rows; it is more authoritative
    /// than Agent Notch's local fallback policy file.
    var nativeApprovalMode: ApprovalMode? = nil
}

/// The latest authoritative turn marker in a Codex Desktop rollout.
///
/// A hidden reply relay can outlive the turn for hours, so its PID is not
/// evidence that Codex is still working. Native turn boundaries and Codex's
/// explicitly phased `final_answer` message are.
nonisolated enum CodexTaskLifecycle: Equatable, Sendable {
    case active(Date?)
    case completed(Date?)
    case missing
    case unknown
}

actor ConversationParser {
    static let shared = ConversationParser()

    /// Logger for conversation parser (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "Parser")

    /// ISO8601DateFormatter is not Sendable, so create it at the parse boundary
    /// instead of sharing one mutable formatter across actor contexts.
    nonisolated private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// Cache of parsed conversation info, keyed by session file path
    private var cache: [String: CachedInfo] = [:]

    private var incrementalState: [String: IncrementalParseState] = [:]
    private var codexRolloutPaths: [String: URL] = [:]
    private var codexLifecycleCache: [
        String: (
            fileSize: UInt64,
            modificationDate: Date?,
            lifecycle: CodexTaskLifecycle
        )
    ] = [:]

    private enum NativeConversationKind {
        case codex
        case codeBuddy
    }

    private struct CachedInfo {
        let modificationDate: Date
        let info: ConversationInfo
    }

    /// State for incremental JSONL parsing
    private struct IncrementalParseState {
        var lastFileOffset: UInt64 = 0
        var messages: [ChatMessage] = []
        var seenToolIds: Set<String> = []
        var toolIdToName: [String: String] = [:]  // Map tool_use_id to tool name
        var completedToolIds: Set<String> = []  // Tools that have received results
        var toolResults: [String: ToolResult] = [:]  // Tool results keyed by tool_use_id
        var structuredResults: [String: ToolResultData] = [:]  // Structured results keyed by tool_use_id
        var lastClearOffset: UInt64 = 0  // Offset of last /clear command (0 = none or at start)
        var clearPending: Bool = false  // True if a /clear was just detected
    }

    /// Parsed tool result data
    struct ToolResult {
        let content: String?
        let stdout: String?
        let stderr: String?
        let isError: Bool
        let isInterrupted: Bool

        init(content: String?, stdout: String?, stderr: String?, isError: Bool) {
            self.content = content
            self.stdout = stdout
            self.stderr = stderr
            self.isError = isError
            // Detect if this was an interrupt or rejection (various formats)
            self.isInterrupted = isError && (
                content?.contains("Interrupted by user") == true ||
                content?.contains("interrupted by user") == true ||
                content?.contains("user doesn't want to proceed") == true
            )
        }
    }

    /// Parse a JSONL file to extract conversation info
    /// Uses caching based on file modification time
    func parse(sessionId: String, cwd: String) -> ConversationInfo {
        // Codex and CodeBuddy have their own native conversation stores. The
        // bridge's Claude-shaped transcript is only a lifecycle fallback and
        // may contain Shell/Bash hook placeholders, so never use it for the
        // user-visible chat when a native file is available.
        if nativeConversationURL(sessionId: sessionId, cwd: cwd) != nil {
            let messages = parseFullConversation(sessionId: sessionId, cwd: cwd)
            let firstUser = messages.first(where: { $0.role == .user })?.textContent
            let last = messages.last(where: { !$0.textContent.isEmpty })
            let lastRole: String?
            if let last {
                lastRole = last.role == .user ? "user" : "assistant"
            } else {
                lastRole = nil
            }
            let title = Self.codexThreadTitle(sessionId: sessionId)
            let nativeApprovalMode = nativeApprovalMode(
                sessionId: sessionId,
                cwd: cwd
            )

            return ConversationInfo(
                summary: title,
                lastMessage: Self.truncateMessage(last?.textContent),
                lastMessageRole: lastRole,
                lastToolName: nil,
                firstUserMessage: Self.truncateMessage(firstUser),
                lastUserMessageDate: messages.last(where: { $0.role == .user })?.timestamp,
                usage: UsageInfo(),
                nativeApprovalMode: nativeApprovalMode
            )
        }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let sessionFile = ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        if let cached = cache[sessionFile], cached.modificationDate == modDate {
            return cached.info
        }

        guard let data = fileManager.contents(atPath: sessionFile),
              let content = String(data: data, encoding: .utf8) else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil)
        }

        var info = parseContent(content)
        if info.summary == nil,
           let codexTitle = Self.codexThreadTitle(sessionId: sessionId) {
            info = ConversationInfo(
                summary: codexTitle,
                lastMessage: info.lastMessage,
                lastMessageRole: info.lastMessageRole,
                lastToolName: info.lastToolName,
                firstUserMessage: info.firstUserMessage,
                lastUserMessageDate: info.lastUserMessageDate,
                usage: info.usage,
                nativeApprovalMode: info.nativeApprovalMode
            )
        }
        cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)

        return info
    }

    /// Codex Desktop stores the user-visible task title in a small local index.
    /// Older synthetic transcripts may predate summary rows, so use this as a
    /// title-only fallback instead of showing the cwd basename ("project").
    nonisolated static func codexThreadTitle(sessionId: String) -> String? {
        let index = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let content = try? String(contentsOf: index, encoding: .utf8) else {
            return nil
        }

        for line in content.split(separator: "\n").reversed() {
            guard line.contains(sessionId),
                  let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  row["id"] as? String == sessionId,
                  let rawTitle = row["thread_name"] as? String else {
                continue
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    /// Read the latest Codex approval policy from its native rollout. This is
    /// intentionally separate from the app-owned bridge policy: when Codex is
    /// launched with full access (`approval_policy: never`), no Permission-
    /// Request hook is expected and the notch must not label the conversation
    /// as single-approval.
    func nativeApprovalMode(sessionId: String, cwd: String) -> ApprovalMode? {
        guard let native = nativeConversationURL(sessionId: sessionId, cwd: cwd),
              case .codex = native.kind,
              let handle = try? FileHandle(forReadingFrom: native.url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        let tailBudget: UInt64 = 1_048_576
        let startOffset = fileSize > tailBudget ? fileSize - tailBudget : 0
        guard (try? handle.seek(toOffset: startOffset)) != nil,
              let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(...firstNewline)
        }

        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let rowType = row["type"] as? String,
                  let payload = row["payload"] as? [String: Any] else {
                continue
            }

            let policy: String?
            switch rowType {
            case "turn_context":
                policy = payload["approval_policy"] as? String
            case "event_msg":
                guard payload["type"] as? String == "thread_settings_applied" else {
                    continue
                }
                policy = (payload["thread_settings"] as? [String: Any])?["approval_policy"] as? String
            default:
                continue
            }

            if let mode = Self.approvalMode(forCodexPolicy: policy) {
                return mode
            }
        }
        return nil
    }

    nonisolated private static func approvalMode(forCodexPolicy policy: String?) -> ApprovalMode? {
        switch policy?.lowercased() {
        case "never", "bypasspermissions", "bypass_permissions", "full-auto", "full_auto":
            return .trusted
        case "untrusted", "on-request", "on_request", "on-failure", "on_failure", "always":
            return .ask
        default:
            return nil
        }
    }

    /// Read only the tail of Codex Desktop's native rollout and return its
    /// latest turn boundary. This is intentionally independent from the
    /// synthetic chat transcript used by the notch UI.
    func codexTaskLifecycle(sessionId: String) -> CodexTaskLifecycle {
        guard let rolloutURL = codexRolloutURL(sessionId: sessionId) else {
            return .missing
        }
        // URL resource values can remain cached on a long-lived URL instance.
        // That used to freeze the first observed `.active` result even after
        // Codex appended final_answer/task_complete to the rollout. FileManager
        // attributes are fetched from the filesystem on every reconciliation.
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: rolloutURL.path
        ),
        let size = attributes[.size] as? NSNumber else {
            return .unknown
        }
        let fileSize = size.uint64Value
        let modificationDate = attributes[.modificationDate] as? Date
        if let cached = codexLifecycleCache[sessionId],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            return cached.lifecycle
        }

        guard let handle = try? FileHandle(forReadingFrom: rolloutURL) else {
            codexRolloutPaths.removeValue(forKey: sessionId)
            codexLifecycleCache.removeValue(forKey: sessionId)
            return .missing
        }
        defer { try? handle.close() }

        let tailBudget: UInt64 = 1_048_576
        guard let fileSize = try? handle.seekToEnd() else {
            return .unknown
        }
        let startOffset = fileSize > tailBudget
            ? fileSize - tailBudget
            : 0
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return .unknown
        }

        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else {
            return .unknown
        }
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(...firstNewline)
        }

        var lifecycle = CodexTaskLifecycle.unknown
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"event_msg\""),
                  let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any],
                  row["type"] as? String == "event_msg",
                  let payload = row["payload"] as? [String: Any],
                  let type = payload["type"] as? String else {
                continue
            }

            let timestamp = (row["timestamp"] as? String)
                .flatMap(Self.parseISO8601)
            if type == "agent_message",
               payload["phase"] as? String == "final_answer" {
                // Codex Desktop renders this message before it appends
                // task_complete (normally about a second later). Treat the
                // explicit final phase as the completion boundary so the
                // notch stops showing work as soon as the user sees the final
                // answer. Commentary agent messages never enter this branch.
                lifecycle = .completed(timestamp)
                break
            }
            switch type {
            case "task_started":
                lifecycle = .active(timestamp)
            case "task_complete":
                lifecycle = .completed(timestamp)
            case "user_message":
                // A long turn can append more than the one-megabyte tail
                // budget before it finishes, pushing task_started out of the
                // scan window. The latest user message is still an
                // authoritative active-turn boundary.
                lifecycle = .active(timestamp)
            case "agent_message"
                where payload["phase"] as? String == "commentary":
                // Likewise, ongoing commentary is positive evidence that the
                // current turn is active. A final answer is handled above.
                lifecycle = .active(timestamp)
            default:
                continue
            }
            break
        }

        codexLifecycleCache[sessionId] = (
            fileSize: fileSize,
            modificationDate: modificationDate,
            lifecycle: lifecycle
        )
        return lifecycle
    }

    private func codexRolloutURL(sessionId: String) -> URL? {
        if let cached = codexRolloutPaths[sessionId],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let suffix = "-\(sessionId).jsonl"
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let url as URL in enumerator
        where url.lastPathComponent.hasSuffix(suffix) {
            codexRolloutPaths[sessionId] = url
            return url
        }
        return nil
    }

    /// Parse JSONL content
    private func parseContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastUserMessageDate: Date?
        var usage = UsageInfo()

        // First pass: collect usage from all assistant messages
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if json["type"] as? String == "assistant",
               let message = json["message"] as? [String: Any],
               let usageDict = message["usage"] as? [String: Any] {
                usage.inputTokens += usageDict["input_tokens"] as? Int ?? 0
                usage.outputTokens += usageDict["output_tokens"] as? Int ?? 0
                usage.cacheReadTokens += usageDict["cache_read_input_tokens"] as? Int ?? 0
                usage.cacheCreationTokens += usageDict["cache_creation_input_tokens"] as? Int ?? 0
            }
        }

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false

            if type == "user" && !isMeta {
                if let message = json["message"] as? [String: Any],
                   let msgContent = message["content"] as? String {
                    if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                        firstUserMessage = Self.truncateMessage(msgContent, maxLength: 50)
                        break
                    }
                }
            }
        }

        var foundLastUserMessage = false
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String

            if lastMessage == nil {
                if type == "user" || type == "assistant" {
                    let isMeta = json["isMeta"] as? Bool ?? false
                    if !isMeta, let message = json["message"] as? [String: Any] {
                        if let msgContent = message["content"] as? String {
                            if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                                lastMessage = msgContent
                                lastMessageRole = type
                            }
                        } else if let contentArray = message["content"] as? [[String: Any]] {
                            for block in contentArray.reversed() {
                                let blockType = block["type"] as? String
                                if blockType == "tool_use" {
                                    let toolName = block["name"] as? String ?? "Tool"
                                    let toolInput = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                    lastMessage = toolInput
                                    lastMessageRole = "tool"
                                    lastToolName = toolName
                                    break
                                } else if blockType == "text", let text = block["text"] as? String {
                                    if !text.hasPrefix("[Request interrupted by user") {
                                        lastMessage = text
                                        lastMessageRole = type
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !foundLastUserMessage && type == "user" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if let msgContent = message["content"] as? String {
                        if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                            if let timestampStr = json["timestamp"] as? String {
                                lastUserMessageDate = Self.parseISO8601(timestampStr)
                            }
                            foundLastUserMessage = true
                        }
                    }
                }
            }

            if summary == nil, type == "summary", let summaryText = json["summary"] as? String {
                summary = summaryText
            }

            if summary != nil && lastMessage != nil && foundLastUserMessage {
                break
            }
        }

        return ConversationInfo(
            summary: summary,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate,
            usage: usage
        )
    }

    /// Format tool input for display in instance list
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task", "Agent":
            // "Task" is the legacy name; Claude Code now uses "Agent"
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    /// Truncate message for display
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    // MARK: - Full Conversation Parsing

    /// Parse full conversation history for chat view (returns ALL messages - use sparingly)
    func parseFullConversation(sessionId: String, cwd: String) -> [ChatMessage] {
        if let native = nativeConversationURL(sessionId: sessionId, cwd: cwd) {
            var state = IncrementalParseState()
            _ = parseNativeNewLines(
                filePath: native.url.path,
                kind: native.kind,
                state: &state
            )
            incrementalState[sessionId] = state
            return state.messages
        }

        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return []
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        _ = parseNewLines(filePath: sessionFile, state: &state)
        incrementalState[sessionId] = state

        return state.messages
    }

    /// Result of incremental parsing
    struct IncrementalParseResult {
        let newMessages: [ChatMessage]
        let allMessages: [ChatMessage]
        let completedToolIds: Set<String>
        let toolResults: [String: ToolResult]
        let structuredResults: [String: ToolResultData]
        let clearDetected: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionId: String, cwd: String) -> IncrementalParseResult {
        if let native = nativeConversationURL(sessionId: sessionId, cwd: cwd) {
            var state = incrementalState[sessionId] ?? IncrementalParseState()
            let newMessages = parseNativeNewLines(
                filePath: native.url.path,
                kind: native.kind,
                state: &state
            )
            incrementalState[sessionId] = state
            return IncrementalParseResult(
                newMessages: newMessages,
                allMessages: state.messages,
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        let sessionFile = Self.sessionFilePath(sessionId: sessionId, cwd: cwd)

        guard FileManager.default.fileExists(atPath: sessionFile) else {
            return IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                clearDetected: false
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let newMessages = parseNewLines(filePath: sessionFile, state: &state)
        let clearDetected = state.clearPending
        if clearDetected {
            state.clearPending = false
        }
        incrementalState[sessionId] = state

        return IncrementalParseResult(
            newMessages: newMessages,
            allMessages: state.messages,
            completedToolIds: state.completedToolIds,
            toolResults: state.toolResults,
            structuredResults: state.structuredResults,
            clearDetected: clearDetected
        )
    }

    /// Parse only new lines since last read (incremental)
    private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return []
        }

        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }

        if fileSize == state.lastFileOffset {
            return state.messages
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return state.messages
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return state.messages
        }

        state.clearPending = false
        let isIncrementalRead = state.lastFileOffset > 0
        let lines = newContent.components(separatedBy: "\n")
        var newMessages: [ChatMessage] = []

        for line in lines where !line.isEmpty {
            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = state.lastFileOffset
                    Self.logger.debug("/clear detected (new), will notify UI")
                }
                continue
            }

            if line.contains("\"tool_result\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let messageDict = json["message"] as? [String: Any],
                   let contentArray = messageDict["content"] as? [[String: Any]] {
                    let toolUseResult = json["toolUseResult"] as? [String: Any]
                    let topLevelToolName = json["toolName"] as? String
                    let stdout = toolUseResult?["stdout"] as? String
                    let stderr = toolUseResult?["stderr"] as? String

                    for block in contentArray {
                        if block["type"] as? String == "tool_result",
                           let toolUseId = block["tool_use_id"] as? String {
                            state.completedToolIds.insert(toolUseId)

                            let content = block["content"] as? String
                            let isError = block["is_error"] as? Bool ?? false
                            state.toolResults[toolUseId] = ToolResult(
                                content: content,
                                stdout: stdout,
                                stderr: stderr,
                                isError: isError
                            )

                            let toolName = topLevelToolName ?? state.toolIdToName[toolUseId]

                            if let toolUseResult = toolUseResult,
                               let name = toolName {
                                let structured = Self.parseStructuredResult(
                                    toolName: name,
                                    toolUseResult: toolUseResult,
                                    isError: isError
                                )
                                state.structuredResults[toolUseId] = structured
                            }
                        }
                    }
                }
            } else if line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") {
                if let lineData = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let message = parseMessageLine(json, seenToolIds: &state.seenToolIds, toolIdToName: &state.toolIdToName) {
                    newMessages.append(message)
                    state.messages.append(message)
                }
            }
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    /// Get set of completed tool IDs for a session
    func completedToolIds(for sessionId: String) -> Set<String> {
        return incrementalState[sessionId]?.completedToolIds ?? []
    }

    /// Get tool results for a session
    func toolResults(for sessionId: String) -> [String: ToolResult] {
        return incrementalState[sessionId]?.toolResults ?? [:]
    }

    /// Get structured tool results for a session
    func structuredResults(for sessionId: String) -> [String: ToolResultData] {
        return incrementalState[sessionId]?.structuredResults ?? [:]
    }

    /// Reset incremental state for a session (call when reloading)
    func resetState(for sessionId: String) {
        incrementalState.removeValue(forKey: sessionId)
    }

    /// Check if a /clear command was detected during the last parse
    /// Returns true once and consumes the pending flag
    func checkAndConsumeClearDetected(for sessionId: String) -> Bool {
        guard var state = incrementalState[sessionId], state.clearPending else {
            return false
        }
        state.clearPending = false
        incrementalState[sessionId] = state
        return true
    }

    /// Build session file path
    private static func sessionFilePath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"
    }

    /// Locate an agent's native transcript. Codex stores rollouts under
    /// ~/.codex/sessions; CodeBuddy stores message JSONL under
    /// ~/.codebuddy/projects. The bridge transcript is deliberately not part
    /// of this lookup.
    private func nativeConversationURL(
        sessionId: String,
        cwd: String
    ) -> (url: URL, kind: NativeConversationKind)? {
        if let url = codexRolloutURL(sessionId: sessionId) {
            return (url, .codex)
        }

        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codebuddy/projects", isDirectory: true)
        let projectKey = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let projectKeyWithoutLeadingDash = projectKey.hasPrefix("-")
            ? String(projectKey.dropFirst())
            : projectKey

        let candidates = [
            root.appendingPathComponent(projectKey).appendingPathComponent("\(sessionId).jsonl"),
            root.appendingPathComponent(projectKeyWithoutLeadingDash).appendingPathComponent("\(sessionId).jsonl")
        ]
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return (url, .codeBuddy)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let url as URL in enumerator
        where url.lastPathComponent == "\(sessionId).jsonl" {
            return (url, .codeBuddy)
        }
        return nil
    }

    /// Parse native Codex/CodeBuddy rows while deliberately ignoring tool
    /// calls, shell output, reasoning blobs, and hook-generated transcripts.
    private func parseNativeNewLines(
        filePath: String,
        kind: NativeConversationKind,
        state: inout IncrementalParseState
    ) -> [ChatMessage] {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            return []
        }
        defer { try? fileHandle.close() }

        guard let fileSize = try? fileHandle.seekToEnd() else { return [] }
        if fileSize < state.lastFileOffset {
            state = IncrementalParseState()
        }
        if fileSize == state.lastFileOffset { return [] }

        let startOffset = state.lastFileOffset
        guard (try? fileHandle.seek(toOffset: startOffset)) != nil,
              let data = try? fileHandle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var newMessages: [ChatMessage] = []
        var lineOffset = startOffset
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineLength = UInt64(line.utf8.count + 1)
            defer { lineOffset += lineLength }

            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let parsed: (ChatRole, String, Date?)?
            switch kind {
            case .codex:
                parsed = Self.parseCodexNativeRow(row)
            case .codeBuddy:
                parsed = Self.parseCodeBuddyNativeRow(row)
            }
            guard let (role, messageText, timestamp) = parsed else { continue }

            let cleaned = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            // The byte offset is stable across incremental reads and unique
            // for each native JSONL row, so no actor-isolated hashing is
            // needed here.
            let id = "native-\(lineOffset)"
            guard !state.messages.contains(where: { $0.id == id }) else { continue }

            let message = ChatMessage(
                id: id,
                role: role,
                timestamp: timestamp ?? Date(),
                content: [.text(cleaned)]
            )
            state.messages.append(message)
            newMessages.append(message)
        }

        state.lastFileOffset = fileSize
        return newMessages
    }

    private static func parseCodexNativeRow(
        _ row: [String: Any]
    ) -> (ChatRole, String, Date?)? {
        guard row["type"] as? String == "event_msg",
              let payload = row["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }

        let role: ChatRole
        switch type {
        case "user_message": role = .user
        case "agent_message": role = .assistant
        default: return nil
        }

        guard let message = payload["message"] as? String else { return nil }
        let timestamp = (row["timestamp"] as? String).flatMap(parseISO8601)
        return (role, message, timestamp)
    }

    private static func parseCodeBuddyNativeRow(
        _ row: [String: Any]
    ) -> (ChatRole, String, Date?)? {
        guard row["type"] as? String == "message",
              let roleValue = row["role"] as? String,
              let role = ChatRole(rawValue: roleValue),
              role == .user || role == .assistant else {
            return nil
        }

        let text: String?
        if let content = row["content"] as? String {
            text = content
        } else if let blocks = row["content"] as? [[String: Any]] {
            text = blocks.compactMap { block in
                block["text"] as? String
            }.joined(separator: "\n")
        } else {
            text = nil
        }
        guard let text, !text.isEmpty else { return nil }

        let timestamp: Date?
        if let milliseconds = row["timestamp"] as? NSNumber {
            timestamp = Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        } else if let value = row["timestamp"] as? String {
            timestamp = parseISO8601(value)
        } else {
            timestamp = nil
        }
        return (role, text, timestamp)
    }

    /// Build subagent JSONL file path.
    ///
    /// Current Claude Code nests subagent files under the parent session:
    ///   projects/<project>/<sessionId>/subagents/agent-<agentId>.jsonl
    ///
    /// Older Claude Code versions stored them flat:
    ///   projects/<project>/agent-<agentId>.jsonl
    ///
    /// Prefer the nested path; fall back to the flat path if only it exists
    /// (cross-version compatibility). If neither exists yet (file still being
    /// created) we return the nested path as the modern default.
    nonisolated static func subagentFilePath(sessionId: String, agentId: String, projectDir: String) -> String {
        let base = ClaudePaths.projectsDir.path + "/" + projectDir
        let nested = base + "/" + sessionId + "/subagents/agent-" + agentId + ".jsonl"
        let flat = base + "/agent-" + agentId + ".jsonl"

        let fm = FileManager.default
        if fm.fileExists(atPath: nested) { return nested }
        if fm.fileExists(atPath: flat) { return flat }
        return nested
    }

    private func parseMessageLine(_ json: [String: Any], seenToolIds: inout Set<String>, toolIdToName: inout [String: String]) -> ChatMessage? {
        guard let type = json["type"] as? String,
              let uuid = json["uuid"] as? String else {
            return nil
        }

        guard type == "user" || type == "assistant" else {
            return nil
        }

        if json["isMeta"] as? Bool == true {
            return nil
        }

        guard let messageDict = json["message"] as? [String: Any] else {
            return nil
        }

        let timestamp: Date
        if let timestampStr = json["timestamp"] as? String {
            timestamp = Self.parseISO8601(timestampStr) ?? Date()
        } else {
            timestamp = Date()
        }

        var blocks: [MessageBlock] = []

        if let content = messageDict["content"] as? String {
            if content.hasPrefix("<command-name>") || content.hasPrefix("<local-command") || content.hasPrefix("Caveat:") {
                return nil
            }
            if content.hasPrefix("[Request interrupted by user") {
                blocks.append(.interrupted)
            } else {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String {
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if text.hasPrefix("[Request interrupted by user") {
                                blocks.append(.interrupted)
                            } else {
                                blocks.append(.text(text))
                            }
                        }
                    case "tool_use":
                        if let toolId = block["id"] as? String {
                            if seenToolIds.contains(toolId) {
                                continue
                            }
                            seenToolIds.insert(toolId)
                            if let toolName = block["name"] as? String {
                                toolIdToName[toolId] = toolName
                            }
                        }
                        if let toolBlock = parseToolUse(block) {
                            blocks.append(.toolUse(toolBlock))
                        }
                    case "thinking":
                        if let thinking = block["thinking"] as? String {
                            blocks.append(.thinking(thinking))
                        }
                    case "image":
                        // Claude Code stores inline images as base64 with media_type.
                        if let source = block["source"] as? [String: Any],
                           let mediaType = source["media_type"] as? String,
                           let data = source["data"] as? String {
                            blocks.append(.image(ImageBlock(mediaType: mediaType, base64Data: data)))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }

        let role: ChatRole = type == "user" ? .user : .assistant

        return ChatMessage(
            id: uuid,
            role: role,
            timestamp: timestamp,
            content: blocks
        )
    }

    private func parseToolUse(_ block: [String: Any]) -> ToolUseBlock? {
        guard let id = block["id"] as? String,
              let name = block["name"] as? String else {
            return nil
        }

        var input: [String: String] = [:]
        if let inputDict = block["input"] as? [String: Any] {
            for (key, value) in inputDict {
                if let strValue = value as? String {
                    input[key] = strValue
                } else if let intValue = value as? Int {
                    input[key] = String(intValue)
                } else if let boolValue = value as? Bool {
                    input[key] = boolValue ? "true" : "false"
                }
            }
        }

        return ToolUseBlock(id: id, name: name, input: input)
    }

    // MARK: - Structured Result Parsing

    /// Parse tool result JSON into structured ToolResultData
    private static func parseStructuredResult(
        toolName: String,
        toolUseResult: [String: Any],
        isError: Bool
    ) -> ToolResultData {
        if toolName.hasPrefix("mcp__") {
            let parts = String(toolName.dropFirst(5)).components(separatedBy: "__")
            let serverName = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let mcpToolName = parts.dropFirst().joined(separator: "__")
            return .mcp(MCPResult(
                serverName: serverName,
                toolName: mcpToolName.isEmpty ? toolName : mcpToolName,
                rawResult: toolUseResult
            ))
        }

        switch toolName {
        case "Read":
            return parseReadResult(toolUseResult)
        case "Edit":
            return parseEditResult(toolUseResult)
        case "Write":
            return parseWriteResult(toolUseResult)
        case "Bash":
            return parseBashResult(toolUseResult)
        case "Grep":
            return parseGrepResult(toolUseResult)
        case "Glob":
            return parseGlobResult(toolUseResult)
        case "TodoWrite":
            return parseTodoWriteResult(toolUseResult)
        case "Task", "Agent":
            return parseTaskResult(toolUseResult)
        case "WebFetch":
            return parseWebFetchResult(toolUseResult)
        case "WebSearch":
            return parseWebSearchResult(toolUseResult)
        case "AskUserQuestion":
            return parseAskUserQuestionResult(toolUseResult)
        case "BashOutput":
            return parseBashOutputResult(toolUseResult)
        case "KillShell":
            return parseKillShellResult(toolUseResult)
        case "ExitPlanMode":
            return parseExitPlanModeResult(toolUseResult)
        default:
            let content = toolUseResult["content"] as? String ??
                          toolUseResult["stdout"] as? String ??
                          toolUseResult["result"] as? String
            return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
        }
    }

    // MARK: - Individual Tool Result Parsers

    private static func parseReadResult(_ data: [String: Any]) -> ToolResultData {
        if let fileData = data["file"] as? [String: Any] {
            return .read(ReadResult(
                filePath: fileData["filePath"] as? String ?? "",
                content: fileData["content"] as? String ?? "",
                numLines: fileData["numLines"] as? Int ?? 0,
                startLine: fileData["startLine"] as? Int ?? 1,
                totalLines: fileData["totalLines"] as? Int ?? 0
            ))
        }
        return .read(ReadResult(
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            numLines: data["numLines"] as? Int ?? 0,
            startLine: data["startLine"] as? Int ?? 1,
            totalLines: data["totalLines"] as? Int ?? 0
        ))
    }

    private static func parseEditResult(_ data: [String: Any]) -> ToolResultData {
        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .edit(EditResult(
            filePath: data["filePath"] as? String ?? "",
            oldString: data["oldString"] as? String ?? "",
            newString: data["newString"] as? String ?? "",
            replaceAll: data["replaceAll"] as? Bool ?? false,
            userModified: data["userModified"] as? Bool ?? false,
            structuredPatch: patches
        ))
    }

    private static func parseWriteResult(_ data: [String: Any]) -> ToolResultData {
        let typeStr = data["type"] as? String ?? "create"
        let writeType: WriteResult.WriteType = typeStr == "overwrite" ? .overwrite : .create

        var patches: [PatchHunk]? = nil
        if let patchArray = data["structuredPatch"] as? [[String: Any]] {
            patches = patchArray.compactMap { patch -> PatchHunk? in
                guard let oldStart = patch["oldStart"] as? Int,
                      let oldLines = patch["oldLines"] as? Int,
                      let newStart = patch["newStart"] as? Int,
                      let newLines = patch["newLines"] as? Int,
                      let lines = patch["lines"] as? [String] else {
                    return nil
                }
                return PatchHunk(
                    oldStart: oldStart,
                    oldLines: oldLines,
                    newStart: newStart,
                    newLines: newLines,
                    lines: lines
                )
            }
        }

        return .write(WriteResult(
            type: writeType,
            filePath: data["filePath"] as? String ?? "",
            content: data["content"] as? String ?? "",
            structuredPatch: patches
        ))
    }

    private static func parseBashResult(_ data: [String: Any]) -> ToolResultData {
        return .bash(BashResult(
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            interrupted: data["interrupted"] as? Bool ?? false,
            isImage: data["isImage"] as? Bool ?? false,
            returnCodeInterpretation: data["returnCodeInterpretation"] as? String,
            backgroundTaskId: data["backgroundTaskId"] as? String
        ))
    }

    private static func parseGrepResult(_ data: [String: Any]) -> ToolResultData {
        let modeStr = data["mode"] as? String ?? "files_with_matches"
        let mode: GrepResult.Mode
        switch modeStr {
        case "content": mode = .content
        case "count": mode = .count
        default: mode = .filesWithMatches
        }

        return .grep(GrepResult(
            mode: mode,
            filenames: data["filenames"] as? [String] ?? [],
            numFiles: data["numFiles"] as? Int ?? 0,
            content: data["content"] as? String,
            numLines: data["numLines"] as? Int,
            appliedLimit: data["appliedLimit"] as? Int
        ))
    }

    private static func parseGlobResult(_ data: [String: Any]) -> ToolResultData {
        return .glob(GlobResult(
            filenames: data["filenames"] as? [String] ?? [],
            durationMs: data["durationMs"] as? Int ?? 0,
            numFiles: data["numFiles"] as? Int ?? 0,
            truncated: data["truncated"] as? Bool ?? false
        ))
    }

    private static func parseTodoWriteResult(_ data: [String: Any]) -> ToolResultData {
        func parseTodos(_ array: [[String: Any]]?) -> [TodoItem] {
            guard let array = array else { return [] }
            return array.compactMap { item -> TodoItem? in
                guard let content = item["content"] as? String,
                      let status = item["status"] as? String else {
                    return nil
                }
                return TodoItem(
                    content: content,
                    status: status,
                    activeForm: item["activeForm"] as? String
                )
            }
        }

        return .todoWrite(TodoWriteResult(
            oldTodos: parseTodos(data["oldTodos"] as? [[String: Any]]),
            newTodos: parseTodos(data["newTodos"] as? [[String: Any]])
        ))
    }

    private static func parseTaskResult(_ data: [String: Any]) -> ToolResultData {
        return .task(TaskResult(
            agentId: data["agentId"] as? String ?? "",
            status: data["status"] as? String ?? "unknown",
            content: data["content"] as? String ?? "",
            prompt: data["prompt"] as? String,
            totalDurationMs: data["totalDurationMs"] as? Int,
            totalTokens: data["totalTokens"] as? Int,
            totalToolUseCount: data["totalToolUseCount"] as? Int
        ))
    }

    private static func parseWebFetchResult(_ data: [String: Any]) -> ToolResultData {
        return .webFetch(WebFetchResult(
            url: data["url"] as? String ?? "",
            code: data["code"] as? Int ?? 0,
            codeText: data["codeText"] as? String ?? "",
            bytes: data["bytes"] as? Int ?? 0,
            durationMs: data["durationMs"] as? Int ?? 0,
            result: data["result"] as? String ?? ""
        ))
    }

    private static func parseWebSearchResult(_ data: [String: Any]) -> ToolResultData {
        var results: [SearchResultItem] = []
        if let resultsArray = data["results"] as? [[String: Any]] {
            results = resultsArray.compactMap { item -> SearchResultItem? in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String else {
                    return nil
                }
                return SearchResultItem(
                    title: title,
                    url: url,
                    snippet: item["snippet"] as? String ?? ""
                )
            }
        }

        return .webSearch(WebSearchResult(
            query: data["query"] as? String ?? "",
            durationSeconds: data["durationSeconds"] as? Double ?? 0,
            results: results
        ))
    }

    private static func parseAskUserQuestionResult(_ data: [String: Any]) -> ToolResultData {
        var questions: [QuestionItem] = []
        if let questionsArray = data["questions"] as? [[String: Any]] {
            questions = questionsArray.compactMap { q -> QuestionItem? in
                guard let question = q["question"] as? String else { return nil }
                var options: [QuestionOption] = []
                if let optionsArray = q["options"] as? [[String: Any]] {
                    options = optionsArray.compactMap { opt -> QuestionOption? in
                        guard let label = opt["label"] as? String else { return nil }
                        return QuestionOption(
                            label: label,
                            description: opt["description"] as? String
                        )
                    }
                }
                return QuestionItem(
                    question: question,
                    header: q["header"] as? String,
                    options: options
                )
            }
        }

        var answers: [String: String] = [:]
        if let answersDict = data["answers"] as? [String: String] {
            answers = answersDict
        }

        return .askUserQuestion(AskUserQuestionResult(
            questions: questions,
            answers: answers
        ))
    }

    private static func parseBashOutputResult(_ data: [String: Any]) -> ToolResultData {
        return .bashOutput(BashOutputResult(
            shellId: data["shellId"] as? String ?? "",
            status: data["status"] as? String ?? "",
            stdout: data["stdout"] as? String ?? "",
            stderr: data["stderr"] as? String ?? "",
            stdoutLines: data["stdoutLines"] as? Int ?? 0,
            stderrLines: data["stderrLines"] as? Int ?? 0,
            exitCode: data["exitCode"] as? Int,
            command: data["command"] as? String,
            timestamp: data["timestamp"] as? String
        ))
    }

    private static func parseKillShellResult(_ data: [String: Any]) -> ToolResultData {
        return .killShell(KillShellResult(
            shellId: data["shell_id"] as? String ?? data["shellId"] as? String ?? "",
            message: data["message"] as? String ?? ""
        ))
    }

    private static func parseExitPlanModeResult(_ data: [String: Any]) -> ToolResultData {
        return .exitPlanMode(ExitPlanModeResult(
            filePath: data["filePath"] as? String,
            plan: data["plan"] as? String,
            isAgent: data["isAgent"] as? Bool ?? false
        ))
    }

    // MARK: - Subagent Tools Parsing

    /// Parse subagent tools from an agent JSONL file
    func parseSubagentTools(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = Self.subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}

/// Info about a subagent tool call parsed from JSONL
struct SubagentToolInfo: Sendable {
    let id: String
    let name: String
    let input: [String: String]
    let isCompleted: Bool
    let timestamp: String?
}

// MARK: - Static Subagent Tools Parsing

extension ConversationParser {
    /// Parse subagent tools from an agent JSONL file (static, synchronous version)
    nonisolated static func parseSubagentToolsSync(sessionId: String, agentId: String, cwd: String) -> [SubagentToolInfo] {
        guard !agentId.isEmpty else { return [] }

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let agentFile = subagentFilePath(sessionId: sessionId, agentId: agentId, projectDir: projectDir)

        guard FileManager.default.fileExists(atPath: agentFile),
              let content = try? String(contentsOfFile: agentFile, encoding: .utf8) else {
            return []
        }

        var tools: [SubagentToolInfo] = []
        var seenToolIds: Set<String> = []
        var completedToolIds: Set<String> = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("\"tool_result\""),
               let lineData = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let messageDict = json["message"] as? [String: Any],
               let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "tool_result",
                       let toolUseId = block["tool_use_id"] as? String {
                        completedToolIds.insert(toolUseId)
                    }
                }
            }
        }

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"tool_use\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let messageDict = json["message"] as? [String: Any],
                  let contentArray = messageDict["content"] as? [[String: Any]] else {
                continue
            }

            for block in contentArray {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let toolName = block["name"] as? String,
                      !seenToolIds.contains(toolId) else {
                    continue
                }

                seenToolIds.insert(toolId)

                var input: [String: String] = [:]
                if let inputDict = block["input"] as? [String: Any] {
                    for (key, value) in inputDict {
                        if let strValue = value as? String {
                            input[key] = strValue
                        } else if let intValue = value as? Int {
                            input[key] = String(intValue)
                        } else if let boolValue = value as? Bool {
                            input[key] = boolValue ? "true" : "false"
                        }
                    }
                }

                let isCompleted = completedToolIds.contains(toolId)
                let timestamp = json["timestamp"] as? String

                tools.append(SubagentToolInfo(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: isCompleted,
                    timestamp: timestamp
                ))
            }
        }

        return tools
    }
}
