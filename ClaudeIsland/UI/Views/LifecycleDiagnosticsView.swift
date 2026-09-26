//
//  LifecycleDiagnosticsView.swift
//  Agent Notch
//
//  Native, read-only lifecycle diagnostics. Export happens only on a click.
//

import AppKit
import SwiftUI

struct LifecycleDiagnosticsView: View {
    let language: AppLanguage

    @StateObject private var coordinator: LifecycleDiagnosticsCoordinator
    @State private var copyStatus: CopyStatus?

    @MainActor init(language: AppLanguage) {
        self.init(language: language, coordinator: LifecycleDiagnosticsCoordinator())
    }

    @MainActor init(language: AppLanguage, coordinator: LifecycleDiagnosticsCoordinator) {
        self.language = language
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    private enum CopyStatus {
        case copied
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusSection

            if let snapshot = coordinator.snapshot {
                connectionsSection(snapshot)
                sessionsSection(snapshot)
                decisionsSection(snapshot)
            }

            privacySection
        }
        .onAppear { coordinator.start() }
        .onDisappear { coordinator.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
            notification in
            if isSettingsWindow(notification) { coordinator.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            notification in
            if isSettingsWindow(notification) { coordinator.start() }
        }
    }

    private var statusSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: statusSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("settings.diagnostics.health")
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let refreshed = coordinator.lastRefreshedAt {
                    Text(t("Refreshed at ", "刷新于 ") + refreshed.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await coordinator.refresh() }
            } label: {
                Label(t("Refresh", "刷新"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.isRefreshing)
            .accessibilityIdentifier("settings.diagnostics.refresh")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsSurface()
    }

    private func connectionsSection(_ snapshot: LifecycleDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(t("Connections", "连接状态"))

            VStack(spacing: 0) {
                connectionRow(
                    title: t("Local bridge", "本地桥接"),
                    detail: snapshot.bridge.isRunning && snapshot.bridge.ownsSocket
                        ? t("Socket is listening", "Socket 正在监听")
                        : t("Socket is not available", "Socket 暂不可用"),
                    symbol: snapshot.bridge.isRunning && snapshot.bridge.ownsSocket
                        ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    color: snapshot.bridge.isRunning && snapshot.bridge.ownsSocket ? .green : .orange
                )
                Divider()
                connectionRow(
                    title: t("Pending approvals", "待处理审批"),
                    detail: "\(snapshot.bridge.pendingPermissionCount)",
                    symbol: "hand.raised",
                    color: .secondary
                )
                Divider()
                connectionRow(
                    title: t("JSONL watchers", "JSONL 监听器"),
                    detail: watcherSummary(snapshot.watchers),
                    symbol: "doc.text.magnifyingglass",
                    color: snapshot.watchers.contains(where: { $0.state == .recovering })
                        ? .orange : .secondary
                )
                if !snapshot.watchers.isEmpty {
                    Divider()
                    ForEach(snapshot.watchers.prefix(12), id: \.label) { watcher in
                        connectionRow(
                            title: watcher.label,
                            detail: watcherTitle(watcher.state)
                                + (watcher.retryCount > 0
                                    ? t(" · retries ", " · 重试 ") + "\(watcher.retryCount)" : ""),
                            symbol: watcherSymbol(watcher.state),
                            color: watcher.state == .recovering ? .orange : .secondary
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .settingsSurface()
            .accessibilityIdentifier("settings.diagnostics.connections")
        }
    }

    private func sessionsSection(_ snapshot: LifecycleDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(t("Current sessions", "当前会话"))
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.sessions.isEmpty {
                    emptyMessage(
                        t("No active sessions right now.", "当前没有活动会话。"),
                        symbol: "square.stack"
                    )
                } else {
                    ForEach(snapshot.sessions.prefix(12), id: \.label) { session in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(session.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sourceTitle(session.source) + " · " + phaseTitle(session.phase))
                                    .font(.system(size: 12, weight: .medium))
                                Text(
                                    ageTitle(session.lastActivityAgeMs)
                                        + t(" since activity", "前有活动")
                                        + (session.waitingForPermission
                                            ? t(" · approval pending", " · 等待审批") : "")
                                )
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.hasProcess {
                                Image(systemName: "terminal")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(t("Process linked", "已关联进程"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                        if session.label != snapshot.sessions.prefix(12).last?.label {
                            Divider()
                        }
                    }
                    if snapshot.sessions.count > 12 {
                        Text(t("More sessions are included in the report.", "其余会话可在报告中查看。"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .settingsSurface()
            .accessibilityIdentifier("settings.diagnostics.sessions")
        }
    }

    private func decisionsSection(_ snapshot: LifecycleDiagnosticsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(t("Recent decisions", "最近裁决"))
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.decisions.isEmpty {
                    emptyMessage(
                        t("No lifecycle decisions recorded yet.", "尚无生命周期裁决记录。"),
                        symbol: "clock.arrow.circlepath"
                    )
                } else {
                    ForEach(Array(snapshot.decisions.prefix(16).enumerated()), id: \.offset) {
                        index, decision in
                        decisionRow(decision)
                        if index < min(snapshot.decisions.count, 16) - 1 {
                            Divider()
                        }
                    }
                    if snapshot.decisions.count > 16 {
                        Text(t("The report includes up to 100 recent decisions.", "报告中最多包含最近 100 条裁决。"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .settingsSurface()
            .accessibilityIdentifier("settings.diagnostics.decisions")
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(t("Share a diagnostic report", "分享诊断报告"))
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    t(
                        "Agent Notch does not upload or save this report. It uses temporary labels and excludes conversations, tool input, raw IDs and file paths.",
                        "Agent Notch 不会上传或保存报告。报告使用临时标签，不包含对话、工具输入、原始 ID 或文件路径。"
                    ),
                    systemImage: "hand.raised.slash"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(t(
                    "Copying uses the macOS clipboard, which may sync across your devices.",
                    "复制将使用 macOS 剪贴板，可能通过系统功能同步到你的其他设备。"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        copyReport()
                    } label: {
                        Label(t("Copy report", "复制诊断报告"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.snapshot == nil)
                    .accessibilityIdentifier("settings.diagnostics.copy")

                    if let copyStatus {
                        Label(
                            copyStatus == .copied
                                ? t("Copied to clipboard", "已复制到剪贴板")
                                : t("Could not copy; please try again", "复制失败，请重试"),
                            systemImage: copyStatus == .copied
                                ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(copyStatus == .copied ? Color.secondary : Color.orange)
                        .accessibilityIdentifier("settings.diagnostics.copyStatus")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSurface()
        }
    }

    private func decisionRow(_ decision: LifecycleDecisionDiagnostics) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: decision.accepted ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(decision.accepted ? .green : .orange)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(decision.label + " · " + originTitle(decision.origin)
                    + " · " + decision.evidence)
                    .font(.system(size: 11, weight: .medium))
                Text(reasonTitle(decision.reason))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    phaseTitle(decision.previousPhase) + " → " + phaseTitle(decision.nextPhase)
                        + " · " + t("latency ", "延迟 ") + "\(decision.deliveryLatencyMs) ms"
                )
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(decision.accepted ? t("Accepted", "已接受") : t("Ignored", "已忽略"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(decision.accepted ? .green : .orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func connectionRow(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
    }

    private func emptyMessage(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 13)
    }

    private var statusTitle: String {
        guard let snapshot = coordinator.snapshot else {
            return t("Collecting local status…", "正在读取本地状态…")
        }
        switch snapshot.health {
        case .healthy: return t("Connections look healthy", "连接状态正常")
        case .attention: return t("A watcher needs attention", "监听器需要留意")
        case .unavailable: return t("Local bridge unavailable", "本地桥接暂不可用")
        }
    }

    private var statusDetail: String {
        if coordinator.refreshDelayed {
            return t("Refresh is taking longer than usual; showing the previous snapshot.",
                     "刷新耗时较长，正在保留上一次快照。")
        }
        guard coordinator.snapshot != nil else {
            return t("No session data is uploaded or saved by this page.",
                     "此页面不会上传或保存会话数据。")
        }
        return t("Read-only status from the session store, bridge and file watchers.",
                 "只读显示会话、桥接和文件监听器的状态。")
    }

    private var statusSymbol: String {
        guard let health = coordinator.snapshot?.health else { return "waveform.path" }
        switch health {
        case .healthy: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .unavailable: return "bolt.slash.circle.fill"
        }
    }

    private var statusColor: Color {
        guard let health = coordinator.snapshot?.health else { return .secondary }
        switch health {
        case .healthy: return .green
        case .attention: return .orange
        case .unavailable: return .orange
        }
    }

    private func watcherSummary(_ watchers: [InterruptWatcherDiagnosticsSnapshot]) -> String {
        let active = watchers.filter { $0.state == .watching }.count
        let waiting = watchers.filter { $0.state == .waitingForFile }.count
        let recovering = watchers.filter { $0.state == .recovering }.count
        return t("\(active) watching · \(waiting) waiting · \(recovering) recovering",
                 "监听 \(active) · 等待文件 \(waiting) · 恢复中 \(recovering)")
    }

    private func watcherTitle(_ state: InterruptWatcherHealth) -> String {
        switch state {
        case .waitingForFile: return t("Waiting for file", "等待文件")
        case .watching: return t("Watching", "监听中")
        case .recovering: return t("Recovering", "恢复中")
        case .stopped: return t("Stopped", "已停止")
        }
    }

    private func watcherSymbol(_ state: InterruptWatcherHealth) -> String {
        switch state {
        case .waitingForFile: return "clock"
        case .watching: return "checkmark.circle"
        case .recovering: return "arrow.clockwise.circle"
        case .stopped: return "stop.circle"
        }
    }

    private func phaseTitle(_ phase: LifecyclePhaseKindValue?) -> String {
        guard let phase else { return t("None", "无") }
        switch phase {
        case .idle: return t("Idle", "空闲")
        case .processing: return t("Working", "工作中")
        case .waitingForInput: return t("Waiting for input", "等待输入")
        case .waitingForApproval: return t("Waiting for approval", "等待审批")
        case .compacting: return t("Compacting", "压缩上下文")
        case .ended: return t("Ended", "已结束")
        }
    }

    private func sourceTitle(_ source: String) -> String {
        switch source {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "codebuddy": return "CodeBuddy"
        case "gemini": return "Gemini"
        case "cursor": return "Cursor"
        default: return t("Agent", "智能体")
        }
    }

    private func originTitle(_ origin: String) -> String {
        switch origin {
        case "codexDiscovery": return t("Discovery", "发现")
        case "codexPolling": return t("Polling", "轮询")
        case "hook": return "Hook"
        case "localInteraction": return t("Local action", "本地操作")
        case "transcript": return t("Transcript", "会话记录")
        case "bridgeSnapshot": return t("Bridge restore", "桥接恢复")
        case "interruptWatcher": return t("Interrupt watcher", "中断监听")
        case "processMonitor": return t("Process monitor", "进程监听")
        default: return origin
        }
    }

    private func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "discoveredActiveTurn": return t("Active turn discovered", "发现正在运行的回合")
        case "activeTurnAdvanced": return t("Activity advanced", "回合活动已推进")
        case "newerTurnStarted": return t("Newer turn started", "新回合已开始")
        case "nativeCompletion": return t("Native turn completed", "原生回合已完成")
        case "staleActiveTimedOut": return t("Old active evidence expired", "旧工作证据已过期")
        case "unknownActiveTimedOut": return t("Unknown activity expired", "未知活动已过期")
        case "sourceMissingBeyondGrace": return t("Source missing beyond grace period", "数据源缺失已超过宽限期")
        case "creationNotAllowed": return t("Observation cannot create a session", "此证据不能创建会话")
        case "staleDiscovery": return t("Discovery is too old", "发现证据已过期")
        case "activeOlderThanHook": return t("Activity predates a hook", "活动早于 Hook 证据")
        case "activeWithoutNewGeneration": return t("No newer turn boundary", "没有更新的回合边界")
        case "completionOlderThanHook": return t("Completion predates a hook", "完成证据早于 Hook")
        case "completionOlderThanTurn": return t("Completion predates this turn", "完成证据早于当前回合")
        case "interactionHasPriority": return t("Interaction still needs attention", "交互请求仍需处理")
        case "missingWithinGrace": return t("Source is within grace period", "数据源仍在宽限期内")
        case "unknownWithinGrace": return t("Status is still uncertain", "状态仍待确认")
        case "sessionNotFound": return t("Session no longer exists", "会话已不存在")
        case "alreadyCurrent": return t("State is already current", "状态已是最新")
        case "hookPhaseAdvanced": return t("Hook advanced the phase", "Hook 推进了状态")
        case "hookCompletion": return t("Hook completed the turn", "Hook 完成了回合")
        case "hookSessionEnded": return t("Hook ended the session", "Hook 结束了会话")
        case "hookSessionRemoved": return t("Hook removed the session", "Hook 移除了会话")
        case "hookOlderThanBoundary": return t("Hook predates current boundary", "Hook 早于当前边界")
        case "invalidHookPhase": return t("Hook phase is invalid", "Hook 状态无效")
        case "interactionResolved": return t("Interaction was resolved", "交互请求已处理")
        case "localFailurePreservedNewerActivity": return t("Newer activity preserved after local failure", "本地失败后保留了更新的活动")
        case "interactionOlderThanCompletion": return t("Interaction predates completion", "交互请求早于完成证据")
        case "interactionOlderThanBoundary": return t("Interaction predates current boundary", "交互请求早于当前边界")
        case "invalidInteractionPhase": return t("Interaction phase is invalid", "交互状态无效")
        case "interruptAccepted": return t("Interrupt accepted", "中断已接受")
        case "interruptOlderThanBoundary": return t("Interrupt predates current boundary", "中断早于当前边界")
        case "processExitAccepted": return t("Process exit accepted", "进程退出已接受")
        default: return reason
        }
    }

    private func ageTitle(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return t("<1 s", "不足 1 秒") }
        let seconds = milliseconds / 1_000
        if seconds < 60 { return t("\(seconds) s", "\(seconds) 秒") }
        let minutes = seconds / 60
        if minutes < 60 { return t("\(minutes) min", "\(minutes) 分钟") }
        return t("\(minutes / 60) h", "\(minutes / 60) 小时")
    }

    private func copyReport() {
        guard let snapshot = coordinator.snapshot else { return }
        do {
            let report = try DiagnosticsReportFormatter.json(snapshot)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            copyStatus = pasteboard.setString(report, forType: .string) ? .copied : .failed
        } catch {
            copyStatus = .failed
        }
    }

    private func isSettingsWindow(_ notification: Notification) -> Bool {
        (notification.object as? NSWindow)?.identifier?.rawValue
            == "com_apple_SwiftUI_Settings_window"
    }

    private func t(_ english: String, _ chinese: String) -> String {
        language.text(english, chinese)
    }
}
