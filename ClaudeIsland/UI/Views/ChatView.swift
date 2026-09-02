//
//  Modified by lihao505 for Agent Notch, 2026.
//  ChatView.swift
//  ClaudeIsland
//
//  Redesigned chat interface with clean visual hierarchy
//

import Combine
import SwiftUI

private let maximumDisplayedCLICharacters = 200_000

/// Pipe reads can split a multi-byte scalar at any byte boundary. Keep only an
/// incomplete UTF-8 suffix between reads so Chinese and emoji are never turned
/// into replacement characters in a partial/cancelled CLI response.
private struct CLIIncrementalUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func append(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var bytes = pending
        bytes.append(contentsOf: data)
        let completeCount = Self.completePrefixLength(bytes)
        pending = Array(bytes.dropFirst(completeCount))
        return String(decoding: bytes.prefix(completeCount), as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: false) }
        return String(decoding: pending, as: UTF8.self)
    }

    private static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let width: Int
            switch first {
            case 0x00...0x7F:
                width = 1
            case 0xC2...0xDF:
                width = 2
            case 0xE0...0xEF:
                width = 3
            case 0xF0...0xF4:
                width = 4
            default:
                // Consume malformed standalone bytes now. String(decoding:)
                // will represent them consistently as U+FFFD.
                index += 1
                continue
            }

            let available = min(width, bytes.count - index)
            var existingContinuationBytesAreValid = true
            if available > 1 {
                for offset in 1..<available
                where (bytes[index + offset] & 0xC0) != 0x80 {
                    existingContinuationBytesAreValid = false
                    break
                }
            }
            if !existingContinuationBytesAreValid {
                index += 1
                continue
            }
            guard available == width else { break }
            index += width
        }
        return index
    }
}

/// Coalesces pipe callbacks into a bounded, already-cleaned text snapshot.
/// The pipe reader can therefore keep draining without queueing one unbounded
/// MainActor job per chunk, while UTF-8 and split ANSI sequences remain intact.
private final class CLIStreamTextAccumulator: @unchecked Sendable {
    private enum ANSIState {
        case text
        case escape
        case controlSequence
    }

    private let lock = NSLock()
    private var decoder = CLIIncrementalUTF8Decoder()
    private var ansiState = ANSIState.text
    private var output = ""
    private var outputCharacterCount = 0
    private var wasTruncated = false
    private var isFinished = false

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        appendDecoded(decoder.append(data))
    }

    @discardableResult
    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !isFinished {
            appendDecoded(decoder.finish())
            isFinished = true
        }
        return snapshotLocked()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func appendDecoded(_ text: String) {
        guard !text.isEmpty else { return }
        var visible = ""
        visible.reserveCapacity(text.utf8.count)

        for scalar in text.unicodeScalars {
            switch ansiState {
            case .text:
                if scalar.value == 0x1B {
                    ansiState = .escape
                } else {
                    visible.unicodeScalars.append(scalar)
                }
            case .escape:
                if scalar.value == 0x5B { // "[" begins an ANSI CSI sequence.
                    ansiState = .controlSequence
                } else {
                    // Match the previous regex behavior: only CSI escapes are
                    // display formatting. Preserve any other escaped text.
                    visible.unicodeScalars.append(UnicodeScalar(0x1B)!)
                    visible.unicodeScalars.append(scalar)
                    ansiState = .text
                }
            case .controlSequence:
                if scalar.value == 0x1B {
                    ansiState = .escape
                } else if (0x40...0x7E).contains(scalar.value) {
                    ansiState = .text
                }
            }
        }

        guard !visible.isEmpty else { return }
        output.append(visible)
        outputCharacterCount += visible.count
        guard outputCharacterCount > maximumDisplayedCLICharacters else {
            return
        }

        // Trim in a sizeable batch so a long-running verbose CLI remains O(n)
        // instead of moving the retained String for every subsequent chunk.
        let retainedCharacters = maximumDisplayedCLICharacters * 3 / 4
        output = String(output.suffix(retainedCharacters))
        outputCharacterCount = output.count
        wasTruncated = true
    }

    private func snapshotLocked() -> String {
        wasTruncated ? "…\n" + output : output
    }
}

struct ChatView: View {
    private enum ChatSendResult {
        case success(output: String)
        case cancelled
        case failure(String)
    }

    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var preferences = NotchPreferences.shared

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    @State private var isSendingMessage: Bool = false
    @State private var sendTask: Task<Void, Never>?
    @State private var activeSendGeneration: UUID?
    @State private var sendErrorMessage: String?
    @FocusState private var isInputFocused: Bool

    init(sessionId: String, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor, viewModel: NotchViewModel) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    /// Codex's native rollout is authoritative for desktop-backed sessions.
    /// In full-access mode it records `approval_policy: never`, meaning no
    /// PermissionRequest is expected and the chip must not say "Once".
    private var effectiveApprovalMode: ApprovalMode {
        if isNativeFullyTrusted {
            return .trusted
        }
        return preferences.approvalMode(for: sessionId)
    }

    /// Only Codex full-access is an immutable native decision. In ask mode,
    /// Agent Notch's own bridge may still provide once/auto/trusted behavior,
    /// so the per-conversation menu must remain interactive.
    private var isNativeFullyTrusted: Bool {
        session.source == .codex && session.conversationInfo.nativeApprovalMode == .trusted
    }

    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // Messages
                if isLoading {
                    loadingState
                } else if displayedHistory.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                // Approval bar, interactive prompt, or Input bar
                if let tool = approvalTool {
                    if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
                        // Interactive tools - answer or review directly in the notch
                        interactivePromptBar
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    } else {
                        approvalBar(tool: tool)
                            .id(session.pendingToolId)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                } else {
                    inputBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // Check if already loaded (from previous visit)
            if ChatHistoryManager.shared.isLoaded(sessionId: sessionId) {
                history = ChatHistoryManager.shared.history(for: sessionId)
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: session.cwd)
            history = ChatHistoryManager.shared.history(for: sessionId)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                // Native-file sync may publish while a CLI reply is still in
                // flight. Preserve optimistic CLI rows until an equivalent
                // native row lands instead of making the user's message blink
                // out of the notch.
                let mergedHistory = ChatHistoryManager.shared.reconcile(
                    nativeHistory: newHistory,
                    optimisticHistory: history
                )
                let countChanged = mergedHistory.count != history.count
                let lastItemChanged = mergedHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || mergedHistory != history {
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && mergedHistory.count > previousHistoryCount {
                        let addedCount = mergedHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = mergedHistory.count
                    }

                    history = mergedHistory

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !mergedHistory.isEmpty {
                        isLoading = false
                    }
                }
            } else if hasLoadedOnce {
                // Session was loaded but is now gone (removed via /clear) - navigate back
                viewModel.exitChat()
            }
        }
        // Chat state must follow the unfiltered store. `instances` deliberately
        // hides older completed rows when active work gets crowded; using that
        // presentation list here can leave an already-open conversation stuck
        // on its last processing snapshot with a disabled input field.
        .onReceive(
            SessionStore.shared.sessionsPublisher
                .receive(on: DispatchQueue.main)
        ) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing
                let isNowWaiting = updated.phase.isWaitingForApproval

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                } else if !wasWaiting && isNowWaiting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .notchPanelDidBecomeInteractive
            )
        ) { _ in
            // The panel is nonactivating and AppKit may promote it to the key
            // window one run-loop later than SwiftUI creates this view. Retry
            // focus after that promotion so the first click can type reliably.
            guard canSendMessages else { return }
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
                    isInputFocused = true
                }
            }
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.exitChat()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                        .frame(width: 24, height: 24)

                    AgentBadge(source: session.source)

                    Text(session.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.85))
                        .lineLimit(1)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    preferences.clearApprovalMode(for: sessionId)
                } label: {
                    Label(
                        t("Follow default", "跟随默认"),
                        systemImage: preferences.hasApprovalOverride(for: sessionId)
                            ? "circle"
                            : "checkmark"
                    )
                }

                Divider()

                ForEach(ApprovalMode.allCases) { mode in
                    Button {
                        if !isNativeFullyTrusted {
                            preferences.setApprovalMode(mode, for: sessionId)
                        }
                    } label: {
                        Label(
                            approvalModeTitle(mode),
                            systemImage:
                                (isNativeFullyTrusted && effectiveApprovalMode == mode)
                                || (!isNativeFullyTrusted
                                    && preferences.hasApprovalOverride(for: sessionId)
                                    && preferences.approvalMode(for: sessionId) == mode)
                                ? "checkmark"
                                : approvalModeIcon(mode)
                        )
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: approvalModeIcon(effectiveApprovalMode))
                    Text(approvalModeTitle(effectiveApprovalMode))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.55)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(
                    Capsule().fill(session.source.accentColor.opacity(0.16))
                )
                .overlay {
                    Capsule().stroke(
                        session.source.accentColor.opacity(0.25),
                        lineWidth: 1
                    )
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isNativeFullyTrusted)
            .help(
                isNativeFullyTrusted
                    ? t("Controlled by Codex desktop permissions", "由 Codex 桌面端权限控制")
                    : ""
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHeaderHovered ? session.source.accentColor.opacity(0.12) : Color.clear)
        )
        .onHover { isHeaderHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    private func approvalModeTitle(_ mode: ApprovalMode) -> String {
        switch mode {
        case .ask:
            return t("Once", "单次")
        case .auto:
            return t("Auto", "自动")
        case .trusted:
            return t("Fully trusted", "完全信任")
        }
    }

    private func approvalModeIcon(_ mode: ApprovalMode) -> String {
        switch mode {
        case .ask:
            return "hand.raised.fill"
        case .auto:
            return "bolt.fill"
        case .trusted:
            return "lock.open.fill"
        }
    }

    private func t(_ english: String, _ chinese: String) -> String {
        preferences.language.text(english, chinese)
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients
    private let fadeColor = Color(red: 0.00, green: 0.00, blue: 0.00)

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing {
                        ProcessingIndicatorView(
                            turnId: lastUserMessageId,
                            color: session.source.accentColor
                        )
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                    }

                    ForEach(displayedHistory.reversed()) { item in
                        MessageItemView(
                            item: item,
                            sessionId: sessionId,
                            accentColor: session.source.accentColor
                        )
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: displayedHistory.count)
            }
            .scaleEffect(x: 1, y: -1)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    // User scrolled back to bottom
                    resumeAutoscroll()
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
        }
    }

    // MARK: - Input Bar

    /// Keep the notch conversation focused on actual user/assistant messages.
    /// Routine tool telemetry (especially repeated Bash rows) remains in the
    /// native transcript, while a tool that currently needs approval stays
    /// visible so the user can still inspect why approval is required.
    private var displayedHistory: [ChatHistoryItem] {
        history.filter { item in
            switch item.type {
            case .user, .assistant, .image, .interrupted:
                return true
            case .toolCall(let tool):
                return tool.status == .waitingForApproval
            case .thinking:
                return false
            }
        }
    }

    /// Claude/CLI agents receive keystrokes through tmux. Desktop-backed
    /// sessions are resumed non-interactively through their local CLIs.
    private var canSendMessages: Bool {
        guard !isSendingMessage else { return false }

        if session.source == .codex || session.source == .codebuddy {
            guard AgentTransportRouter.isAvailable(for: session.source) else {
                return false
            }
            switch session.phase {
            // Codex/CodeBuddy sessions remain resumable after the desktop
            // process reports `ended`; the CLI resume command is precisely
            // how a completed turn receives the next user message.
            case .idle, .waitingForInput, .ended:
                return true
            default:
                return false
            }
        }

        return session.isInTmux && session.tty != nil
    }

    private var inputPlaceholder: String {
        if canSendMessages {
            return "Message \(session.source.displayName)..."
        }
        if isSendingMessage {
            return "Sending to \(session.source.displayName)..."
        }
        if session.source == .codex {
            return !AgentTransportRouter.isAvailable(for: .codex)
                ? "Install Codex CLI to enable messaging"
                : "Wait for Codex to finish"
        }
        if session.source == .codebuddy {
            return !AgentTransportRouter.isAvailable(for: .codebuddy)
                ? "Install CodeBuddy CLI to enable messaging"
                : "Wait for CodeBuddy to finish"
        }
        return "Open the agent in tmux to enable messaging"
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField(inputPlaceholder, text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(canSendMessages ? .white : .white.opacity(0.4))
                .focused($isInputFocused)
                .disabled(!canSendMessages)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessages ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit {
                    sendMessage()
                }
                .onTapGesture {
                    if canSendMessages {
                        isInputFocused = true
                    }
                }

                Button {
                    if isSendingMessage {
                        sendTask?.cancel()
                    } else {
                        sendMessage()
                    }
                } label: {
                    if isSendingMessage {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(session.source.accentColor)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(
                                !canSendMessages || inputText.isEmpty
                                    ? .white.opacity(0.2)
                                    : session.source.accentColor
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(
                    isSendingMessage
                        ? false
                        : (!canSendMessages || inputText.isEmpty)
                )
                .help(
                    isSendingMessage
                        ? t("Stop this reply", "停止本次回复")
                        : t("Send", "发送")
                )
            }

            if let sendErrorMessage {
                Text(sendErrorMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.red.opacity(0.85))
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            onApproveOnce: { approvePermission() },
            onAutoApprove: { autoApprovePermission() },
            onDeny: { denyPermission() }
        )
    }

    // MARK: - Interactive Prompt Bar

    /// Native structured UI for questions and plan review.
    @ViewBuilder
    private var interactivePromptBar: some View {
        if let permission = session.activePermission {
            StructuredInteractivePromptBar(
                context: permission,
                isInTmux: session.isInTmux,
                onSubmitAnswers: { answers in
                    sessionMonitor.answerQuestions(
                        sessionId: sessionId,
                        expectedToolUseId: permission.toolUseId,
                        answers: answers
                    )
                },
                onApprovePlan: {
                    sessionMonitor.approvePlan(
                        sessionId: sessionId,
                        expectedToolUseId: permission.toolUseId
                    )
                },
                onDeny: { denyPermission() },
                onGoToTerminal: { focusTerminal() }
            )
        }
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    // MARK: - Actions

    private func focusTerminal() {
        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func approvePermission() {
        guard let toolUseId = session.pendingToolId else { return }
        sessionMonitor.approvePermission(
            sessionId: sessionId,
            expectedToolUseId: toolUseId
        )
    }

    private func autoApprovePermission() {
        preferences.setApprovalMode(.auto, for: sessionId)
        approvePermission()
    }

    private func denyPermission() {
        guard let toolUseId = session.pendingToolId else { return }
        sessionMonitor.denyPermission(
            sessionId: sessionId,
            expectedToolUseId: toolUseId,
            reason: nil
        )
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendMessages, !text.isEmpty else { return }

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true
        isSendingMessage = true
        sendErrorMessage = nil
        inputText = ""

        // Add the exact text sent to the CLI immediately. The response is
        // appended from CLI stdout below; no desktop transcript round-trip is
        // required for this chat path.
        let optimisticUserId = "cli-user-\(UUID().uuidString)"
        history.append(ChatHistoryItem(
            id: optimisticUserId,
            type: .user(text),
            timestamp: Date()
        ))

        let assistantId = "cli-assistant-\(UUID().uuidString)"
        let generation = UUID()
        activeSendGeneration = generation
        let stdoutAccumulator = CLIStreamTextAccumulator()
        let (stdoutSignals, stdoutContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task { @MainActor in
            // The accumulator owns every byte; AsyncStream only coalesces wakeup
            // signals. Dropping an intermediate signal therefore never drops
            // CLI text or splits a UTF-8 scalar.
            let streamConsumer = Task { @MainActor in
                await consumeCLIStdout(
                    stdoutSignals,
                    accumulator: stdoutAccumulator,
                    assistantId: assistantId,
                    generation: generation
                )
            }

            defer {
                if activeSendGeneration == generation {
                    activeSendGeneration = nil
                    isSendingMessage = false
                    sendTask = nil
                }
            }

            let result = await sendToSession(text, onStdoutChunk: { data in
                stdoutAccumulator.append(data)
                stdoutContinuation.yield(())
            })
            stdoutAccumulator.finish()
            stdoutContinuation.finish()
            let streamedOutput = await streamConsumer.value

            // A future send must never receive a late callback from this one.
            guard activeSendGeneration == generation else { return }

            switch result {
            case .failure(let errorMessage):
                if cleanedCLIOutput(streamedOutput).isEmpty {
                    history.removeAll { $0.id == optimisticUserId }
                    inputText = text
                }
                sendErrorMessage = errorMessage
            case .cancelled:
                history.append(ChatHistoryItem(
                    id: "cli-interrupted-\(UUID().uuidString)",
                    type: .interrupted,
                    timestamp: Date()
                ))
                sendErrorMessage = t(
                    "Reply stopped. The CLI session remains available.",
                    "已停止本次回复，CLI 会话仍可继续。"
                )
            case .success(let output):
                // This is intentionally a CLI-only chat path. Render the
                // actual CLI response directly instead of depending on a
                // desktop app's native transcript watcher.
                let assistantText = cleanedCLIOutput(output)
                if !assistantText.isEmpty {
                    upsertCLIAssistant(
                        id: assistantId,
                        text: assistantText
                    )
                    shouldScrollToBottom = true
                }

                // Persist against the agent's real transcript after stdout is
                // already visible. mergeHistory keeps the optimistic rows in
                // place until their native equivalents arrive. Do not keep
                // the composer in a sending state while a best-effort file
                // reconciliation scans the transcript.
                if session.source == .codex || session.source == .codebuddy {
                    Task {
                        await ChatHistoryManager.shared.syncFromFile(
                            sessionId: sessionId,
                            cwd: session.cwd
                        )
                    }
                }
            }
        }
        sendTask = task
    }

    private func sendToSession(
        _ text: String,
        onStdoutChunk: @escaping @Sendable (Data) -> Void
    ) async -> ChatSendResult {
        do {
            let output = try await AgentTransportRouter.send(
                text,
                to: session,
                onStdoutChunk: onStdoutChunk
            )
            return .success(output: output)
        } catch ProcessExecutorError.cancelled(_) {
            return .cancelled
        } catch let transportError as AgentTransportError {
            return .failure(transportError.localizedDescription)
        } catch {
            return .failure(
                cliFailureMessage(
                    agentName: session.source.displayName,
                    error: error
                )
            )
        }
    }

    /// Present the actionable end of a CLI failure instead of its complete
    /// diagnostic stream. Codex can emit benign cache warnings before the real
    /// terminal error; showing the entire stderr both hides that error in the
    /// two-line notch UI and can expose unrelated command diagnostics.
    private func cliFailureMessage(agentName: String, error: Error) -> String {
        let detail: String
        switch error {
        case ProcessExecutorError.executionFailed(_, let exitCode, let stderr):
            detail = actionableCLIStderr(stderr)
                ?? t(
                    "The CLI exited with code \(exitCode).",
                    "CLI 已退出（代码 \(exitCode)）。"
                )
        case ProcessExecutorError.commandNotFound:
            detail = t("The CLI was not found.", "未找到 CLI。")
        case ProcessExecutorError.timedOut(_, let seconds):
            detail = t(
                "The reply timed out after \(seconds) seconds.",
                "回复在 \(seconds) 秒后超时。"
            )
        case ProcessExecutorError.launchFailed(_, let underlying):
            detail = t(
                "The CLI could not start: \(conciseErrorLine(underlying.localizedDescription))",
                "CLI 无法启动：\(conciseErrorLine(underlying.localizedDescription))"
            )
        case ProcessExecutorError.standardInputFailed(_, let reason):
            detail = t(
                "The CLI stopped accepting input: \(conciseErrorLine(reason))",
                "CLI 未能接收输入：\(conciseErrorLine(reason))"
            )
        case ProcessExecutorError.invalidOutput:
            detail = t("The CLI returned invalid output.", "CLI 返回了无效输出。")
        case ProcessExecutorError.cancelled:
            detail = t("The reply was stopped.", "回复已停止。")
        default:
            detail = conciseErrorLine(error.localizedDescription)
        }

        return t(
            "Could not send to \(agentName): \(detail)",
            "无法发送到 \(agentName)：\(detail)"
        )
    }

    private func actionableCLIStderr(_ stderr: String?) -> String? {
        guard let stderr else { return nil }
        let lines = cleanedCLIOutput(stderr)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // Quota exhaustion is common and fully actionable. Prefer it over
        // preceding WARN lines such as a stale model-cache diagnostic.
        if let quotaLine = lines.last(where: { line in
            let lowercased = line.lowercased()
            return lowercased.contains("usage limit")
                || lowercased.contains("quota exceeded")
        }) {
            let normalized = stripErrorPrefix(quotaLine)
            if let resetRange = normalized.range(
                of: "try again at ",
                options: [.caseInsensitive]
            ) {
                let resetTime = normalized[resetRange.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if !resetTime.isEmpty {
                    return t(
                        "Usage limit reached. Try again at \(resetTime).",
                        "用量已耗尽，请在 \(resetTime) 后重试。"
                    )
                }
            }
            return t("Usage limit reached.", "用量已耗尽，请稍后重试。")
        }

        let actionable = lines.last(where: { line in
            let lowercased = line.lowercased()
            return lowercased.hasPrefix("error:")
                || lowercased.hasPrefix("fatal:")
                || lowercased.contains("permission denied")
                || lowercased.contains("rate limit")
        }) ?? lines.last!
        return conciseErrorLine(stripErrorPrefix(actionable))
    }

    private func stripErrorPrefix(_ line: String) -> String {
        let prefixes = ["ERROR:", "Error:", "error:", "FATAL:", "Fatal:", "fatal:"]
        for prefix in prefixes where line.hasPrefix(prefix) {
            return line.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line
    }

    private func conciseErrorLine(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumCharacters = 360
        guard singleLine.count > maximumCharacters else { return singleLine }
        return String(singleLine.prefix(maximumCharacters - 1)) + "…"
    }

    private func consumeCLIStdout(
        _ stream: AsyncStream<Void>,
        accumulator: CLIStreamTextAccumulator,
        assistantId: String,
        generation: UUID
    ) async -> String {
        for await _ in stream {
            guard activeSendGeneration == generation else { continue }
            let visibleText = accumulator.snapshot().trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !visibleText.isEmpty else { continue }
            upsertCLIAssistant(id: assistantId, text: visibleText)
            shouldScrollToBottom = true

            // SwiftUI only needs a human-visible refresh cadence. While this
            // task is suspended, bufferingNewest(1) coalesces any number of
            // pipe reads into one follow-up snapshot.
            try? await Task.sleep(nanoseconds: 75_000_000)
        }

        let output = accumulator.finish().trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if activeSendGeneration == generation {
            if !output.isEmpty {
                upsertCLIAssistant(id: assistantId, text: output)
                shouldScrollToBottom = true
            }
        }
        return output
    }

    @MainActor
    private func upsertCLIAssistant(id: String, text: String) {
        let timestamp: Date
        if let index = history.firstIndex(where: { $0.id == id }) {
            timestamp = history[index].timestamp
            history[index] = ChatHistoryItem(
                id: id,
                type: .assistant(text),
                timestamp: timestamp
            )
        } else {
            history.append(ChatHistoryItem(
                id: id,
                type: .assistant(text),
                timestamp: Date()
            ))
        }
    }

    private func cleanedCLIOutput(_ output: String) -> String {
        let cleaned = output
            .replacingOccurrences(
                of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maximumDisplayedCLICharacters else {
            return cleaned
        }
        return "…\n" + String(
            cleaned.suffix(maximumDisplayedCLICharacters)
        )
    }

}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String
    let accentColor: Color

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .assistant(let text):
            AssistantMessageView(text: text, accentColor: accentColor)
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId)
        case .thinking(let text):
            ThinkingView(text: text)
        case .image(let block):
            ImageMessageView(image: block)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - Image Message

struct ImageMessageView: View {
    let image: ImageBlock

    /// Decoded image cached so base64 isn't re-decoded on every render.
    /// Large inline images (tens of KB) would otherwise thrash during
    /// scrolling or parent re-renders.
    @State private var decoded: NSImage?

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            } else {
                // Decode failed — show a labelled placeholder rather than silently dropping
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                    Text("Image (\(image.mediaType))")
                        .font(.system(size: 12))
                }
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                )
            }
        }
        .task(id: image.id) {
            // Decode off the main thread so large images don't hitch scrolling.
            let b64 = image.base64Data
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: b64) else { return nil as NSImage? }
                return NSImage(data: data)
            }.value
            self.decoded = decoded
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: .white, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.15))
                )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String
    let accentColor: Color

    var body: some View {
        // Skip rendering when text is empty — otherwise the dot indicator
        // shows up alone (orphan dot) for tool-only assistant turns.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                // White dot indicator
                Circle()
                    .fill(accentColor.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                MarkdownText(text, color: .white.opacity(0.9), fontSize: 13)

                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = ["Processing", "Working"]
    private let color: Color
    private let baseText: String

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// Use a turnId to select text consistently per user turn
    init(
        turnId: String = "",
        color: Color = Color(red: 0.85, green: 0.47, blue: 0.34)
    ) {
        self.color = color
        // Use hash of turnId to pick base text consistently for this turn
        let index = abs(turnId.hashValue) % baseTexts.count
        baseText = baseTexts[index]
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner(color: color)
                .frame(width: 6)

            Text(baseText + dots)
                .font(.system(size: 13))
                .foregroundColor(color)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String

    @State private var pulseOpacity: Double = 0.6
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return Color.white
        case .waitingForApproval:
            return Color.orange
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return .white.opacity(0.6)
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return .white.opacity(0.7)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT a subagent container, NOT Edit).
    private var canExpand: Bool {
        !tool.isSubagentContainer && tool.name != "Edit" && hasResult
    }

    private var showContent: Bool {
        tool.name == "Edit" || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor.opacity(tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.6))
                    .frame(width: 6, height: 6)
                    .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .fixedSize()

                if tool.isSubagentContainer && !tool.subagentTools.isEmpty {
                    let taskDesc = tool.input["description"] ?? "Running agent..."
                    Text("\(taskDesc) (\(tool.subagentTools.count) tools)")
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task/Agent tools)
            if tool.isSubagentContainer && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && !tool.isSubagentContainer && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.name == "Edit" && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(canExpand && isHovering ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more tool uses")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return .orange
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if tool.status == .interrupted {
            return "Interrupted"
        } else if tool.status == .running {
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            // Status text (same format as regular tools)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(tools.count) tools:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        // Skip rendering when text is empty — streaming thinking blocks can
        // briefly arrive empty, which otherwise leaves an orphan grey dot.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .italic()
                    .lineLimit(isExpanded ? nil : 1)
                    .multilineTextAlignment(.leading)

                Spacer()

                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.gray.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canExpand {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    let isInTmux: Bool
    let onGoToTerminal: () -> Void

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                Text("Claude Code needs your input")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if isInTmux {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(isInTmux ? .black : .white.opacity(0.4))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isInTmux ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showButton ? 1 : 0)
            .scaleEffect(showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let onApproveOnce: () -> Void
    let onAutoApprove: () -> Void
    let onDeny: () -> Void
    @ObservedObject private var preferences = NotchPreferences.shared

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TerminalColors.amber)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text(t("Approval required", "需要审批"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))

                    HStack(spacing: 5) {
                        Text(MCPToolFormatter.formatToolName(tool))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(TerminalColors.amber)
                        Text(t("wants to perform this action", "请求执行以下操作"))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.46))
                    }

                    if let input = toolInput, !input.isEmpty {
                        Text(input)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.64))
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.white.opacity(0.055))
                            )
                    }
                }
                .opacity(showContent ? 1 : 0)
                .offset(x: showContent ? 0 : -10)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                approvalButton(
                    t("Deny", "拒绝"),
                    icon: "xmark",
                    foreground: .white.opacity(0.72),
                    background: .white.opacity(0.09),
                    action: onDeny
                )
                .opacity(showDenyButton ? 1 : 0)
                .scaleEffect(showDenyButton ? 1 : 0.8)

                approvalButton(
                    t("Allow once", "允许一次"),
                    icon: "checkmark",
                    foreground: .black,
                    background: .white.opacity(0.94),
                    action: onApproveOnce
                )
                .opacity(showAllowButton ? 1 : 0)
                .scaleEffect(showAllowButton ? 1 : 0.8)

                approvalButton(
                    t("Auto approve", "自动审批"),
                    icon: "bolt.fill",
                    foreground: .black,
                    background: TerminalColors.green,
                    action: onAutoApprove
                )
                .opacity(showAllowButton ? 1 : 0)
                .scaleEffect(showAllowButton ? 1 : 0.8)
            }
        }
        .frame(minHeight: 82)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }

    private func approvalButton(
        _ title: String,
        icon: String,
        foreground: Color,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(background)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func t(_ english: String, _ chinese: String) -> String {
        preferences.language.text(english, chinese)
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(count == 1 ? "1 new message" : "\(count) new messages")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
