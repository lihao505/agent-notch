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

/// Codex rewrites its small title index when tasks are created or renamed.
/// Cache the decoded map by file signature so every one-second status pass
/// does not reread and reverse-scan the complete index once per session.
nonisolated private final class CodexThreadTitleIndex: @unchecked Sendable {
    static let shared = CodexThreadTitleIndex()

    private let lock = NSLock()
    private var modificationDate: Date?
    private var fileSize: UInt64?
    private var titles: [String: String] = [:]

    private init() {}

    func title(for sessionId: String) -> String? {
        let index = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: index.path
        ),
        let currentModificationDate = attributes[.modificationDate] as? Date,
        let currentFileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }

        lock.lock()
        if modificationDate == currentModificationDate,
           fileSize == currentFileSize {
            let result = titles[sessionId]
            lock.unlock()
            return result
        }
        lock.unlock()

        guard let content = try? String(contentsOf: index, encoding: .utf8) else {
            return nil
        }
        var refreshed: [String: String] = [:]
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any],
                  let id = row["id"] as? String,
                  let rawTitle = row["thread_name"] as? String else {
                continue
            }
            let title = rawTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !title.isEmpty {
                refreshed[id] = title
            }
        }

        lock.lock()
        modificationDate = currentModificationDate
        fileSize = currentFileSize
        titles = refreshed
        let result = refreshed[sessionId]
        lock.unlock()
        return result
    }
}

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
    /// `turnStartedAt` is the authoritative generation boundary. Activity
    /// such as token counts may advance `lastEvidenceAt`, but must never make
    /// an already completed turn look like a newly started one.
    case active(turnStartedAt: Date?, lastEvidenceAt: Date?)
    case completed(Date?)
    case missing
    case unknown
}

nonisolated struct CodexTaskObservation: Sendable {
    let sessionId: String
    let cwd: String
    let lifecycle: CodexTaskLifecycle
    let fileModifiedAt: Date
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
    private var codexLifecycleState: [String: CodexLifecycleParseState] = [:]
    private var codexMetadataCache: [String: (sessionId: String, cwd: String)] = [:]
    private var codexRolloutIndexInitialized = false
    private var codexIndexedDirectoryModificationDates: [String: Date] = [:]

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
        var nativeApprovalMode: ApprovalMode?
    }

    /// A separate cursor for the small subset of Codex rollout rows that
    /// determine whether a turn is still active. Keeping this independent from
    /// chat parsing lets the one-second status poll consume only newly appended
    /// bytes instead of repeatedly splitting and decoding a one-megabyte tail.
    private struct CodexLifecycleParseState {
        var isInitialized = false
        /// End of the bytes already read from disk. `pending` contains any
        /// unterminated row from those bytes, so the file itself is never
        /// reread merely because the writer stopped in the middle of a row.
        var readOffset: UInt64 = 0
        var modificationDate: Date?
        var deviceNumber: UInt64?
        var fileNumber: UInt64?
        var lifecycle: CodexTaskLifecycle = .unknown
        var turnStartedAt: Date?
        var lastEvidenceAt: Date?
        var pending = Data()
        /// Last bytes immediately preceding `readOffset`. This cheap anchor
        /// detects a truncate-and-regrow that happens between two status polls.
        var anchor = Data()
        /// An initial one-megabyte tail can begin in the middle of a JSON row.
        /// Discard through its newline without retaining an arbitrarily large
        /// compacted/context row.
        var discardingLeadingPartial = false
        /// Once a row is known to be irrelevant or exceeds the event-row hard
        /// limit, stream past it without retaining any more bytes until LF.
        var discardingCurrentLine = false
        var currentLineIsEventMessage = false
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
            // This is a metadata snapshot, not a transcript-consumption API.
            // Advancing the shared native cursor here can lose a row appended
            // after parseIncremental returned: this call would consume it, but
            // its message would not be present in the already-created update
            // payload. Only parseIncremental/parseFullConversation may advance
            // the native cursor; a later incremental tick will consume any row
            // appended after this snapshot.
            let state = incrementalState[sessionId] ?? IncrementalParseState()
            let messages = state.messages
            let firstUser = messages.first(where: { $0.role == .user })?.textContent
            let last = messages.last(where: { !$0.textContent.isEmpty })
            let lastRole: String?
            if let last {
                lastRole = last.role == .user ? "user" : "assistant"
            } else {
                lastRole = nil
            }
            let title = Self.codexThreadTitle(sessionId: sessionId)
            // The incremental scan sees every turn_context/settings row once,
            // so it remains authoritative even when a long turn pushes the
            // policy row outside the one-megabyte tail fallback.
            let nativeApprovalMode = state.nativeApprovalMode ??
                nativeApprovalMode(sessionId: sessionId, cwd: cwd)

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
        CodexThreadTitleIndex.shared.title(for: sessionId)
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
        // Include the byte immediately before the tail. It tells us whether
        // startOffset is already a line boundary without ever trying to decode
        // a UTF-8 scalar that the byte budget split in half.
        let readOffset = startOffset > 0 ? startOffset - 1 : 0
        guard (try? handle.seek(toOffset: readOffset)) != nil,
              let data = try? handle.readToEnd() else {
            return nil
        }

        for lineData in Self.completeJSONLLines(
            in: data,
            hasLeadingProbeByte: startOffset > 0
        ).reversed() {
            guard let row = try? JSONSerialization.jsonObject(
                with: lineData
            ) as? [String: Any] else {
                continue
            }

            if let mode = Self.codexApprovalMode(from: row) {
                return mode
            }
        }
        return nil
    }

    /// Return only complete JSONL rows from a byte tail. Prefix and suffix
    /// fragments are removed as Data, before UTF-8/JSON decoding. This keeps a
    /// tail boundary inside Chinese text or an emoji from invalidating all
    /// otherwise complete rows that follow it.
    nonisolated private static func completeJSONLLines(
        in data: Data,
        hasLeadingProbeByte: Bool
    ) -> [Data] {
        guard !data.isEmpty else { return [] }

        var completeStart = data.startIndex
        if hasLeadingProbeByte {
            if data[data.startIndex] == 0x0A {
                completeStart = data.index(after: data.startIndex)
            } else {
                guard let firstNewline = data.firstIndex(of: 0x0A) else {
                    return []
                }
                completeStart = data.index(after: firstNewline)
            }
        }
        guard completeStart < data.endIndex,
              let lastNewline = data[completeStart...].lastIndex(of: 0x0A),
              completeStart <= lastNewline else {
            return []
        }

        var lines: [Data] = []
        var lineStart = completeStart
        while lineStart <= lastNewline,
              let newline = data[lineStart...].firstIndex(of: 0x0A),
              newline <= lastNewline {
            if lineStart < newline {
                lines.append(data.subdata(in: lineStart..<newline))
            }
            lineStart = data.index(after: newline)
        }
        return lines
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

    nonisolated private static func codexApprovalMode(
        from row: [String: Any]
    ) -> ApprovalMode? {
        guard let rowType = row["type"] as? String,
              let payload = row["payload"] as? [String: Any] else {
            return nil
        }

        let policy: String?
        switch rowType {
        case "turn_context":
            policy = payload["approval_policy"] as? String
        case "event_msg":
            guard payload["type"] as? String == "thread_settings_applied" else {
                return nil
            }
            policy = (payload["thread_settings"] as? [String: Any])?["approval_policy"] as? String
        default:
            return nil
        }
        return approvalMode(forCodexPolicy: policy)
    }

    /// Read Codex Desktop's native rollout and return its latest turn boundary.
    /// The first observation scans at most the final one megabyte; subsequent
    /// observations consume only bytes appended after the saved cursor.
    func codexTaskLifecycle(sessionId: String) -> CodexTaskLifecycle {
        guard let rolloutURL = codexRolloutURL(sessionId: sessionId) else {
            codexLifecycleState.removeValue(forKey: sessionId)
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
        let deviceNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        var state = codexLifecycleState[sessionId] ??
            CodexLifecycleParseState()
        let fileIdentityChanged = state.isInitialized && (
            (state.deviceNumber != nil && deviceNumber != nil &&
                state.deviceNumber != deviceNumber) ||
            (state.fileNumber != nil && fileNumber != nil &&
                state.fileNumber != fileNumber)
        )
        let sameSizeRewrite = state.isInitialized &&
            fileSize == state.readOffset &&
            state.modificationDate != modificationDate
        var mustReset = !state.isInitialized ||
            fileSize < state.readOffset ||
            fileIdentityChanged ||
            sameSizeRewrite

        if !mustReset && fileSize == state.readOffset {
            state.modificationDate = modificationDate
            state.deviceNumber = deviceNumber
            state.fileNumber = fileNumber
            codexLifecycleState[sessionId] = state
            return state.lifecycle
        }

        guard let handle = try? FileHandle(forReadingFrom: rolloutURL) else {
            codexRolloutPaths.removeValue(forKey: sessionId)
            codexLifecycleState.removeValue(forKey: sessionId)
            return .missing
        }
        defer { try? handle.close() }

        // A rollout can be truncated and regrown past the previous cursor
        // between one-second polls. Size alone cannot detect that race, so
        // compare the tiny saved anchor whenever the file changed and grew.
        if !mustReset,
           modificationDate != state.modificationDate,
           !state.anchor.isEmpty {
            let anchorOffset = state.readOffset - UInt64(state.anchor.count)
            do {
                try handle.seek(toOffset: anchorOffset)
                let currentAnchor = try handle.read(
                    upToCount: state.anchor.count
                )
                if currentAnchor != state.anchor {
                    mustReset = true
                }
            } catch {
                mustReset = true
            }
        }

        if mustReset {
            state = CodexLifecycleParseState()
            state.isInitialized = true
            // A long, tool-heavy turn can push its latest task_started many
            // megabytes behind the file tail. Locate the newest authoritative
            // lifecycle boundary backwards, then parse forward from there.
            // This keeps the generation exact without serially decoding a
            // multi-megabyte historical rollout during app startup.
            state.readOffset = Self.codexLifecycleInitialReadOffset(
                at: rolloutURL,
                fileSize: fileSize
            )
            if state.readOffset > 0 {
                do {
                    try handle.seek(toOffset: state.readOffset - 1)
                    let previousByte = try handle.read(upToCount: 1)?.first
                    state.discardingLeadingPartial = previousByte != 0x0A
                } catch {
                    state.discardingLeadingPartial = true
                }
            }
        }

        do {
            try handle.seek(toOffset: state.readOffset)
        } catch {
            codexLifecycleState.removeValue(forKey: sessionId)
            return state.lifecycle
        }

        // Limit this pass to the size captured above. If Codex appends while
        // we read, the next status tick starts exactly at this snapshot's end.
        var remaining = fileSize - state.readOffset
        while remaining > 0 {
            let requested = Int(min(
                UInt64(Self.codexLifecycleReadChunkSize),
                remaining
            ))
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: requested),
                      !data.isEmpty else {
                    break
                }
                chunk = data
            } catch {
                break
            }
            state.readOffset += UInt64(chunk.count)
            remaining -= UInt64(chunk.count)
            Self.updateCodexLifecycleAnchor(chunk, state: &state)
            Self.consumeCodexLifecycleData(chunk, state: &state)
        }

        state.modificationDate = modificationDate
        state.deviceNumber = deviceNumber
        state.fileNumber = fileNumber
        codexLifecycleState[sessionId] = state
        return state.lifecycle
    }

    /// Discover Codex turns from native rollout writes, independently of
    /// hook delivery. Codex Desktop can omit UserPromptSubmit for a resumed
    /// task, which otherwise leaves Agent Notch idle until the first tool.
    /// Only metadata is stat'ed for the full tree; lifecycle bytes are parsed
    /// for files that changed inside the caller's narrow time window.
    func discoverCodexTasks(
        modifiedAfter: Date
    ) -> [CodexTaskObservation] {
        ensureCodexRolloutIndex()
        refreshRecentCodexRolloutIndex()

        var observations: [CodexTaskObservation] = []
        let indexedRollouts = codexRolloutPaths
        for (sessionId, url) in indexedRollouts {
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let fileType = attributes[.type] as? FileAttributeType,
            fileType == .typeRegular,
            let modifiedAt = attributes[.modificationDate] as? Date,
            modifiedAt >= modifiedAfter,
            let metadata = codexSessionMetadata(at: url) else {
                continue
            }

            observations.append(CodexTaskObservation(
                sessionId: sessionId,
                cwd: metadata.cwd,
                lifecycle: codexTaskLifecycle(
                    sessionId: sessionId
                ),
                fileModifiedAt: modifiedAt
            ))
        }
        return observations
    }

    private func codexSessionsRootURL() -> URL {
        if let override = Foundation.ProcessInfo.processInfo.environment[
            "AGENT_NOTCH_CODEX_SESSIONS_ROOT"
        ]?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Build the historical rollout index once. The one-second discovery poll
    /// then stats known files and only scans the few date directories where a
    /// brand-new task can appear, instead of recursively walking all history.
    private func ensureCodexRolloutIndex() {
        guard !codexRolloutIndexInitialized else { return }
        codexRolloutIndexInitialized = true
        indexCodexRollouts(recursivelyUnder: codexSessionsRootURL())
    }

    private func refreshRecentCodexRolloutIndex(now: Date = Date()) {
        let root = codexSessionsRootURL()
        let calendar = Calendar(identifier: .gregorian)
        for daysAgo in 0...2 {
            guard let date = calendar.date(
                byAdding: .day,
                value: -daysAgo,
                to: now
            ) else {
                continue
            }
            let components = calendar.dateComponents(
                [.year, .month, .day],
                from: date
            )
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                continue
            }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", day))
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.path
            ),
            let modificationDate = attributes[.modificationDate] as? Date,
            codexIndexedDirectoryModificationDates[directory.path]
                != modificationDate else {
                continue
            }
            indexCodexRollouts(recursivelyUnder: directory)
            codexIndexedDirectoryModificationDates[directory.path]
                = modificationDate
        }
    }

    private func indexCodexRollouts(recursivelyUnder root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let metadata = codexSessionMetadata(at: url) else {
                continue
            }
            codexRolloutPaths[metadata.sessionId] = url
        }
    }

    private func codexSessionMetadata(
        at url: URL
    ) -> (sessionId: String, cwd: String)? {
        if let cached = codexMetadataCache[url.path] {
            return cached
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 256 * 1024),
              let newline = prefix.firstIndex(of: 0x0A),
              let row = try? JSONSerialization.jsonObject(
                with: prefix[..<newline]
              ) as? [String: Any],
              row["type"] as? String == "session_meta",
              let payload = row["payload"] as? [String: Any],
              let sessionId = payload["id"] as? String,
              !sessionId.isEmpty,
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        let metadata = (sessionId: sessionId, cwd: cwd)
        codexMetadataCache[url.path] = metadata
        return metadata
    }

    private nonisolated static let codexLifecycleTailBudget: UInt64 = 1_048_576
    private nonisolated static let codexLifecycleReadChunkSize = 256 * 1_024
    private nonisolated static let codexLifecycleAnchorSize = 64
    /// Lifecycle event rows are normally a few hundred bytes. Four MiB leaves
    /// generous room for a large final answer while making a malformed or
    /// unexpectedly huge event row safe to ignore until its terminating LF.
    private nonisolated static let codexLifecycleMaxEventRowSize =
        4 * 1_024 * 1_024

    private enum CodexLifecycleLineClassification {
        case eventMessage
        case irrelevant
        case incomplete
    }

    private enum CodexJSONScanResult {
        case complete
        case incomplete
        case invalid
    }

    /// Find the newest real lifecycle boundary without decoding every JSONL
    /// row. Candidate strings can also occur inside tool output, so the whole
    /// containing row is parsed and verified before its offset is accepted.
    nonisolated private static func codexLifecycleInitialReadOffset(
        at url: URL,
        fileSize: UInt64
    ) -> UInt64 {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty else {
            return fileSize > codexLifecycleTailBudget
                ? fileSize - codexLifecycleTailBudget
                : 0
        }

        let eventMessageNeedle = Data("\"type\":\"event_msg\"".utf8)
        let boundaryNeedles = [
            "\"task_started\"",
            "\"task_complete\"",
            "\"turn_aborted\"",
            "\"task_aborted\"",
            "\"task_cancelled\"",
            "\"task_canceled\"",
            "\"turn_cancelled\"",
            "\"turn_canceled\"",
            "\"task_failed\"",
            "\"turn_failed\"",
            "\"thread_rolled_back\"",
            "\"final_answer\""
        ].map { Data($0.utf8) }

        var lineEnd = data.endIndex
        if lineEnd > data.startIndex,
           data[data.index(before: lineEnd)] == 0x0A {
            lineEnd = data.index(before: lineEnd)
        }
        while lineEnd > data.startIndex {
            let precedingNewline = data[..<lineEnd].lastIndex(of: 0x0A)
            let lineStart = precedingNewline
                .map { data.index(after: $0) } ?? data.startIndex
            let line = data[lineStart..<lineEnd]
            if line.count <= codexLifecycleMaxEventRowSize,
               line.range(of: eventMessageNeedle) != nil,
               boundaryNeedles.contains(where: {
                   line.range(of: $0) != nil
               }),
               let row = try? JSONSerialization.jsonObject(with: line)
                    as? [String: Any],
               isCodexLifecycleBoundary(row) {
                return UInt64(lineStart)
            }
            guard let precedingNewline else { break }
            lineEnd = precedingNewline
        }

        return fileSize > codexLifecycleTailBudget
            ? fileSize - codexLifecycleTailBudget
            : 0
    }

    nonisolated private static func isCodexLifecycleBoundary(
        _ row: [String: Any]
    ) -> Bool {
        guard row["type"] as? String == "event_msg",
              let payload = row["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return false
        }
        if type == "agent_message" {
            return payload["phase"] as? String == "final_answer"
        }
        return type == "task_started" || [
            "task_complete",
            "turn_aborted",
            "task_aborted",
            "task_cancelled",
            "task_canceled",
            "turn_cancelled",
            "turn_canceled",
            "task_failed",
            "turn_failed",
            "thread_rolled_back"
        ].contains(type)
    }

    nonisolated private static func updateCodexLifecycleAnchor(
        _ data: Data,
        state: inout CodexLifecycleParseState
    ) {
        if data.count >= codexLifecycleAnchorSize {
            state.anchor = Data(data.suffix(codexLifecycleAnchorSize))
            return
        }
        state.anchor.append(data)
        if state.anchor.count > codexLifecycleAnchorSize {
            state.anchor.removeFirst(
                state.anchor.count - codexLifecycleAnchorSize
            )
        }
    }

    /// Consume lifecycle JSONL with bounded memory. Top-level `type` is parsed
    /// from the row prefix; known non-event rows are discarded immediately,
    /// and oversized candidate event rows are streamed through to LF.
    nonisolated private static func consumeCodexLifecycleData(
        _ data: Data,
        state: inout CodexLifecycleParseState
    ) {
        var cursor = data.startIndex
        if state.discardingLeadingPartial {
            guard let newline = data[cursor...].firstIndex(of: 0x0A) else {
                return
            }
            cursor = data.index(after: newline)
            state.discardingLeadingPartial = false
        }

        while cursor < data.endIndex {
            if state.discardingCurrentLine {
                guard let newline = data[cursor...].firstIndex(of: 0x0A) else {
                    return
                }
                cursor = data.index(after: newline)
                resetCodexLifecycleLineState(&state)
                continue
            }

            let newline = data[cursor...].firstIndex(of: 0x0A)
            let segmentEnd = newline ?? data.endIndex
            let segmentCount = data.distance(
                from: cursor,
                to: segmentEnd
            )
            let available = codexLifecycleMaxEventRowSize -
                state.pending.count

            if segmentCount > available {
                // Do not append beyond the hard cap. The remainder of this row
                // is irrelevant to lifecycle state even if its JSON is valid.
                state.pending.removeAll(keepingCapacity: false)
                state.currentLineIsEventMessage = false
                state.discardingCurrentLine = newline == nil
            } else {
                state.pending.append(contentsOf: data[cursor..<segmentEnd])
                if !state.currentLineIsEventMessage {
                    switch classifyCodexLifecycleLine(state.pending) {
                    case .eventMessage:
                        state.currentLineIsEventMessage = true
                    case .irrelevant:
                        state.pending.removeAll(keepingCapacity: false)
                        state.discardingCurrentLine = newline == nil
                    case .incomplete:
                        break
                    }
                }

                if newline != nil,
                   state.currentLineIsEventMessage,
                   let row = try? JSONSerialization.jsonObject(
                    with: state.pending
                   ) as? [String: Any] {
                    applyCodexLifecycleRow(row, state: &state)
                }
            }

            guard let newline else { return }
            cursor = data.index(after: newline)
            resetCodexLifecycleLineState(&state)
        }
    }

    nonisolated private static func resetCodexLifecycleLineState(
        _ state: inout CodexLifecycleParseState
    ) {
        state.pending.removeAll(keepingCapacity: true)
        state.discardingCurrentLine = false
        state.currentLineIsEventMessage = false
    }

    /// Parse just enough of a JSON object to classify its top-level `type`.
    /// This avoids substring false positives from nested payloads and lets
    /// response_item/context rows be released after their first read chunk.
    nonisolated private static func classifyCodexLifecycleLine(
        _ data: Data
    ) -> CodexLifecycleLineClassification {
        var index = data.startIndex
        skipCodexJSONWhitespace(data, index: &index)
        guard index < data.endIndex else { return .incomplete }
        guard data[index] == 0x7B else { return .irrelevant } // {
        index = data.index(after: index)

        while true {
            skipCodexJSONWhitespace(data, index: &index)
            guard index < data.endIndex else { return .incomplete }
            if data[index] == 0x7D { return .irrelevant } // }
            if data[index] == 0x2C { // ,
                index = data.index(after: index)
                continue
            }

            var keyRange: Range<Data.Index>?
            switch scanCodexJSONString(
                data,
                index: &index,
                contentRange: &keyRange
            ) {
            case .incomplete:
                return .incomplete
            case .invalid:
                return .irrelevant
            case .complete:
                break
            }

            skipCodexJSONWhitespace(data, index: &index)
            guard index < data.endIndex else { return .incomplete }
            guard data[index] == 0x3A else { return .irrelevant } // :
            index = data.index(after: index)
            skipCodexJSONWhitespace(data, index: &index)

            let isTypeKey = keyRange.map {
                data[$0].elementsEqual("type".utf8)
            } ?? false
            if isTypeKey {
                var valueRange: Range<Data.Index>?
                switch scanCodexJSONString(
                    data,
                    index: &index,
                    contentRange: &valueRange
                ) {
                case .incomplete:
                    return .incomplete
                case .invalid:
                    return .irrelevant
                case .complete:
                    let isEvent = valueRange.map {
                        data[$0].elementsEqual("event_msg".utf8)
                    } ?? false
                    return isEvent ? .eventMessage : .irrelevant
                }
            }

            switch skipCodexJSONValue(data, index: &index) {
            case .complete:
                continue
            case .incomplete:
                return .incomplete
            case .invalid:
                return .irrelevant
            }
        }
    }

    nonisolated private static func skipCodexJSONWhitespace(
        _ data: Data,
        index: inout Data.Index
    ) {
        while index < data.endIndex {
            switch data[index] {
            case 0x20, 0x09, 0x0D, 0x0A:
                index = data.index(after: index)
            default:
                return
            }
        }
    }

    nonisolated private static func scanCodexJSONString(
        _ data: Data,
        index: inout Data.Index,
        contentRange: inout Range<Data.Index>?
    ) -> CodexJSONScanResult {
        guard index < data.endIndex else { return .incomplete }
        guard data[index] == 0x22 else { return .invalid } // "
        index = data.index(after: index)
        let contentStart = index
        var escaped = false
        while index < data.endIndex {
            let byte = data[index]
            if escaped {
                escaped = false
                index = data.index(after: index)
            } else if byte == 0x5C { // \
                escaped = true
                index = data.index(after: index)
            } else if byte == 0x22 {
                contentRange = contentStart..<index
                index = data.index(after: index)
                return .complete
            } else if byte < 0x20 {
                return .invalid
            } else {
                index = data.index(after: index)
            }
        }
        return .incomplete
    }

    nonisolated private static func skipCodexJSONValue(
        _ data: Data,
        index: inout Data.Index
    ) -> CodexJSONScanResult {
        guard index < data.endIndex else { return .incomplete }
        if data[index] == 0x22 {
            var unused: Range<Data.Index>?
            return scanCodexJSONString(
                data,
                index: &index,
                contentRange: &unused
            )
        }

        if data[index] == 0x7B || data[index] == 0x5B { // { or [
            var expectedClosers: [UInt8] = [
                data[index] == 0x7B ? 0x7D : 0x5D,
            ]
            index = data.index(after: index)
            var inString = false
            var escaped = false
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                    continue
                }
                switch byte {
                case 0x22:
                    inString = true
                case 0x7B:
                    expectedClosers.append(0x7D)
                case 0x5B:
                    expectedClosers.append(0x5D)
                case 0x7D, 0x5D:
                    guard expectedClosers.last == byte else {
                        return .invalid
                    }
                    expectedClosers.removeLast()
                    if expectedClosers.isEmpty { return .complete }
                default:
                    break
                }
            }
            return .incomplete
        }

        // Numbers, booleans, and null end at whitespace or an object/array
        // delimiter. Validation of their spelling is left to JSONSerialization.
        let valueStart = index
        while index < data.endIndex {
            switch data[index] {
            case 0x20, 0x09, 0x0D, 0x0A, 0x2C, 0x7D, 0x5D:
                return index > valueStart ? .complete : .invalid
            default:
                index = data.index(after: index)
            }
        }
        return .incomplete
    }

    nonisolated private static func applyCodexLifecycleRow(
        _ row: [String: Any],
        state: inout CodexLifecycleParseState
    ) {
        guard row["type"] as? String == "event_msg",
              let payload = row["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }

        let timestamp = (row["timestamp"] as? String)
            .flatMap(parseISO8601)
        if type == "token_count" {
            // A token count immediately after an abort is not proof of a new
            // turn. It only refreshes evidence for an already-active turn.
            if case .active = state.lifecycle,
               let timestamp {
                state.lastEvidenceAt = max(
                    state.lastEvidenceAt ?? .distantPast,
                    timestamp
                )
                state.lifecycle = .active(
                    turnStartedAt: state.turnStartedAt,
                    lastEvidenceAt: state.lastEvidenceAt
                )
            }
            return
        }

        if type == "agent_message",
           payload["phase"] as? String == "final_answer" {
            // Codex renders the final response shortly before task_complete.
            state.lifecycle = .completed(timestamp)
            return
        }

        switch type {
        case "task_started":
            state.turnStartedAt = timestamp
            state.lastEvidenceAt = timestamp
            state.lifecycle = .active(
                turnStartedAt: timestamp,
                lastEvidenceAt: timestamp
            )
        case "user_message":
            if case .active = state.lifecycle {
                state.lastEvidenceAt = max(
                    state.lastEvidenceAt ?? .distantPast,
                    timestamp ?? .distantPast
                )
            } else {
                state.turnStartedAt = timestamp
                state.lastEvidenceAt = timestamp
            }
            state.lifecycle = .active(
                turnStartedAt: state.turnStartedAt,
                lastEvidenceAt: state.lastEvidenceAt
            )
        case "agent_message"
            where payload["phase"] as? String == "commentary":
            if case .active = state.lifecycle {
                state.lastEvidenceAt = max(
                    state.lastEvidenceAt ?? .distantPast,
                    timestamp ?? .distantPast
                )
            } else {
                // If the initial tail began after task_started, commentary is
                // still a safe active boundary for discovery. It is never
                // allowed to override a later completion because completed
                // state ignores token-only evidence above.
                state.turnStartedAt = timestamp
                state.lastEvidenceAt = timestamp
            }
            state.lifecycle = .active(
                turnStartedAt: state.turnStartedAt,
                lastEvidenceAt: state.lastEvidenceAt
            )
        case "task_complete",
             "turn_aborted",
             "task_aborted",
             "task_cancelled",
             "task_canceled",
             "turn_cancelled",
             "turn_canceled",
             "task_failed",
             "turn_failed",
             "thread_rolled_back":
            state.lifecycle = .completed(timestamp)
        default:
            break
        }
    }

    private func codexRolloutURL(sessionId: String) -> URL? {
        if let cached = codexRolloutPaths[sessionId],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        codexRolloutPaths.removeValue(forKey: sessionId)
        ensureCodexRolloutIndex()
        refreshRecentCodexRolloutIndex()
        return codexRolloutPaths[sessionId]
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
            // Explicit history loads may continue from the same cursor. Most
            // importantly, routine metadata refreshes no longer reset this
            // state and force another full rollout read.
            var state = incrementalState[sessionId] ?? IncrementalParseState()
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
        /// True when at least one complete JSONL row was consumed, including
        /// metadata-only and tool-result rows that do not create chat messages.
        let fileAdvanced: Bool
    }

    /// Parse only NEW messages since last call (efficient incremental updates)
    func parseIncremental(sessionId: String, cwd: String) -> IncrementalParseResult {
        if let native = nativeConversationURL(sessionId: sessionId, cwd: cwd) {
            var state = incrementalState[sessionId] ?? IncrementalParseState()
            let previousOffset = state.lastFileOffset
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
                clearDetected: false,
                fileAdvanced: state.lastFileOffset != previousOffset
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
                clearDetected: false,
                fileAdvanced: false
            )
        }

        var state = incrementalState[sessionId] ?? IncrementalParseState()
        let previousOffset = state.lastFileOffset
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
            clearDetected: clearDetected,
            fileAdvanced: state.lastFileOffset != previousOffset
        )
    }

    /// Return only the complete UTF-8 JSONL prefix. Writers can be observed in
    /// the middle of a row; advancing over that partial row loses it forever on
    /// the next incremental read.
    private nonisolated static func completeJSONLPrefix(
        in data: Data
    ) -> (text: String, byteCount: UInt64)? {
        guard let newlineIndex = data.lastIndex(of: 0x0A) else {
            return nil
        }
        let endIndex = data.index(after: newlineIndex)
        let completeData = Data(data[..<endIndex])
        guard let text = String(data: completeData, encoding: .utf8) else {
            return nil
        }
        return (text, UInt64(completeData.count))
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
            return []
        }

        do {
            try fileHandle.seek(toOffset: state.lastFileOffset)
        } catch {
            return []
        }

        let readOffset = state.lastFileOffset
        guard let newData = try? fileHandle.readToEnd(),
              let completePrefix = Self.completeJSONLPrefix(in: newData) else {
            return []
        }

        state.clearPending = false
        let isIncrementalRead = readOffset > 0
        let lines = completePrefix.text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).dropLast()
        var newMessages: [ChatMessage] = []
        var lineOffset = readOffset

        for line in lines {
            let lineLength = UInt64(line.utf8.count + 1)
            defer { lineOffset += lineLength }
            guard !line.isEmpty else { continue }

            if line.contains("<command-name>/clear</command-name>") {
                state.messages = []
                state.seenToolIds = []
                state.toolIdToName = [:]
                state.completedToolIds = []
                state.toolResults = [:]
                state.structuredResults = [:]

                if isIncrementalRead {
                    state.clearPending = true
                    state.lastClearOffset = lineOffset
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

        state.lastFileOffset = readOffset + completePrefix.byteCount
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
        guard (try? fileHandle.seek(toOffset: startOffset)) != nil else {
            return []
        }

        // Rollouts contain large compacted/context rows that are irrelevant to
        // the user-visible chat (individual rows can exceed 9 MB). Reading the
        // whole remaining file into Data + String caused a large launch-time
        // memory spike even after the repeated full-file scan was fixed. Keep
        // only one incomplete JSONL row in memory and prefilter by the small set
        // of row types we actually render before asking JSONSerialization to
        // materialize an object graph.
        let codexEventNeedle = Data("\"type\":\"event_msg\"".utf8)
        let codexContextNeedle = Data("\"type\":\"turn_context\"".utf8)
        let codexPayloadNeedles = [
            Data("\"type\":\"user_message\"".utf8),
            Data("\"type\":\"agent_message\"".utf8),
            Data("\"type\":\"thread_settings_applied\"".utf8),
        ]
        let codeBuddyMessageNeedles = [
            Data("\"type\":\"message\"".utf8),
            Data("\"type\": \"message\"".utf8),
        ]

        var newMessages: [ChatMessage] = []
        var pending = Data()
        var pendingOffset = startOffset
        let chunkSize = 256 * 1_024

        while true {
            let chunk: Data
            do {
                guard let nextChunk = try fileHandle.read(
                    upToCount: chunkSize
                ), !nextChunk.isEmpty else {
                    break
                }
                chunk = nextChunk
            } catch {
                break
            }
            pending.append(chunk)
            var lineStart = pending.startIndex

            while lineStart < pending.endIndex,
                  let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                let lineRange = lineStart..<newline
                let relativeOffset = pending.distance(
                    from: pending.startIndex,
                    to: lineStart
                )
                let lineOffset = pendingOffset + UInt64(relativeOffset)

                let contains: (Data) -> Bool = { needle in
                    pending.range(
                        of: needle,
                        options: [],
                        in: lineRange
                    ) != nil
                }
                let isRelevant: Bool
                switch kind {
                case .codex:
                    isRelevant = !lineRange.isEmpty && (
                        contains(codexContextNeedle) ||
                        (contains(codexEventNeedle) &&
                            codexPayloadNeedles.contains(where: contains))
                    )
                case .codeBuddy:
                    isRelevant = !lineRange.isEmpty &&
                        codeBuddyMessageNeedles.contains(where: contains)
                }
                if isRelevant {
                    let lineData = pending.subdata(in: lineRange)
                    if let row = try? JSONSerialization.jsonObject(
                        with: lineData
                    ) as? [String: Any] {
                        if case .codex = kind,
                           let mode = Self.codexApprovalMode(from: row) {
                            state.nativeApprovalMode = mode
                        }
                        let parsed: (ChatRole, String, Date?)?
                        switch kind {
                        case .codex:
                            parsed = Self.parseCodexNativeRow(row)
                        case .codeBuddy:
                            parsed = Self.parseCodeBuddyNativeRow(row)
                        }

                        if let (role, messageText, timestamp) = parsed {
                            let cleaned = messageText.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            if !cleaned.isEmpty {
                                // The byte offset is stable across incremental
                                // reads and unique for every native JSONL row.
                                let message = ChatMessage(
                                    id: "native-\(lineOffset)",
                                    role: role,
                                    timestamp: timestamp ?? Date(),
                                    content: [.text(cleaned)]
                                )
                                state.messages.append(message)
                                newMessages.append(message)
                            }
                        }
                    }
                }

                lineStart = pending.index(after: newline)
            }

            // Commit complete rows only. A writer may still be appending the
            // final row; leaving it at the current file offset makes the next
            // tick reread it rather than silently losing it.
            if lineStart > pending.startIndex {
                let consumed = pending.distance(
                    from: pending.startIndex,
                    to: lineStart
                )
                pending.removeSubrange(pending.startIndex..<lineStart)
                pendingOffset += UInt64(consumed)
            }
        }

        state.lastFileOffset = pendingOffset
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
