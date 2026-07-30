//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchMenuView.swift
//  ClaudeIsland
//
//  Minimal menu matching Dynamic Island aesthetic
//

import ApplicationServices
import Combine
import SwiftUI
import ServiceManagement
import Sparkle

// MARK: - NotchMenuView

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var preferences = NotchPreferences.shared
    @State private var hooksInstalled: Bool = false
    @State private var launchAtLogin: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            compactHeader

            HStack(spacing: 10) {
                PresenceModeButton(
                    title: t("Stay Ready", "常驻显示"),
                    icon: "sparkles",
                    isSelected: preferences.idleBehavior == .alwaysVisible
                ) {
                    preferences.idleBehavior = .alwaysVisible
                }

                PresenceModeButton(
                    title: t("Smart Hide", "智能隐藏"),
                    icon: "eye.slash",
                    isSelected: preferences.idleBehavior == .smartHide
                ) {
                    preferences.idleBehavior = .smartHide
                }
            }

            HStack(spacing: 8) {
                Text(t("Small notch", "小刘海"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))

                Spacer()

                compactStyleButton(.simple, title: t("Simple", "简略"))
                compactStyleButton(.detailed, title: t("Detailed", "详细"))
            }
            .padding(.horizontal, 3)

            HStack(spacing: 8) {
                Text(t("Default approvals", "默认审批"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))

                Spacer()

                approvalModeButton(.ask, title: t("Once", "单次"))
                approvalModeButton(.auto, title: t("Auto", "自动"))
                approvalModeButton(.trusted, title: t("Trust", "信任"))
            }
            .padding(.horizontal, 3)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                CompactControlTile(
                    title: t("Hover", "悬停展开"),
                    subtitle: preferences.expandOnHover
                        ? String(format: "%.2fs", preferences.hoverDelay)
                        : t("Off", "关闭"),
                    icon: "cursorarrow.motionlines",
                    isOn: preferences.expandOnHover
                ) {
                    preferences.expandOnHover.toggle()
                }

                CompactControlTile(
                    title: t("Usage", "用量"),
                    subtitle: preferences.showUsageLimits
                        ? t("Visible", "显示")
                        : t("Hidden", "隐藏"),
                    icon: "chart.bar.fill",
                    isOn: preferences.showUsageLimits
                ) {
                    preferences.showUsageLimits.toggle()
                }

                CompactControlTile(
                    title: t("At Login", "登录启动"),
                    subtitle: launchAtLogin
                        ? t("Enabled", "已开启")
                        : t("Disabled", "已关闭"),
                    icon: "power",
                    isOn: launchAtLogin
                ) {
                    toggleLaunchAtLogin()
                }

                CompactControlTile(
                    title: t("Agent Bridge", "智能体桥接"),
                    subtitle: hooksInstalled
                        ? t("Connected", "已连接")
                        : t("Needs setup", "需要设置"),
                    icon: "point.3.connected.trianglepath.dotted",
                    isOn: hooksInstalled
                ) {
                    toggleHooks()
                }
            }

            HStack(spacing: 10) {
                Button {
                    AppDelegate.shared?.showDetailedSettings(
                        afterCollapsing: viewModel
                    )
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.95, green: 0.48, blue: 0.27),
                                            Color(red: 0.55, green: 0.29, blue: 0.94)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("Open Agent Notch Settings", "打开 Agent Notch 设置"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(
                                t(
                                    "Display, timing, usage and integrations",
                                    "显示、动效、用量与集成"
                                )
                            )
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.42))
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 13)
                            .fill(Color.white.opacity(0.055))
                            .overlay {
                                RoundedRectangle(cornerRadius: 13)
                                    .strokeBorder(Color.white.opacity(0.08))
                            }
                    )
                }
                .buttonStyle(.plain)

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 13, weight: .semibold))
                        Text(t("Quit", "退出"))
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(TerminalColors.red.opacity(0.86))
                    .frame(width: 54, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 13)
                            .fill(TerminalColors.red.opacity(0.09))
                            .overlay {
                                RoundedRectangle(cornerRadius: 13)
                                    .strokeBorder(TerminalColors.red.opacity(0.20))
                            }
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t("Quit Agent Notch", "完全退出 Agent Notch"))
                .help(t("Quit Agent Notch", "完全退出 Agent Notch"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            refreshStates()
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .menu {
                refreshStates()
            }
        }
    }

    private func refreshStates() {
        hooksInstalled = HookInstaller.isInstalled()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var compactHeader: some View {
        HStack {
            Button {
                viewModel.toggleMenu()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(t("Quick Controls", "快捷控制"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(
                    t(
                        "Tune the notch without leaving your task",
                        "无需离开任务即可调整刘海"
                    )
                )
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.36))
            }

            Spacer()

            Button {
                preferences.language =
                    preferences.language == .english
                    ? .simplifiedChinese
                    : .english
            } label: {
                Text(preferences.language == .english ? "中" : "EN")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                    .frame(minWidth: 28)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.055)))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }

    private func compactStyleButton(
        _ style: CompactNotchStyle,
        title: String
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                preferences.compactStyle = style
            }
        } label: {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    preferences.compactStyle == style
                        ? Color.white
                        : Color.white.opacity(0.4)
                )
                .padding(.horizontal, 10)
                .frame(height: 25)
                .background(
                    Capsule()
                        .fill(
                            preferences.compactStyle == style
                                ? Color(red: 0.95, green: 0.48, blue: 0.27)
                                    .opacity(0.2)
                                : Color.white.opacity(0.04)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func approvalModeButton(
        _ mode: ApprovalMode,
        title: String
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                preferences.approvalMode = mode
            }
        } label: {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    preferences.approvalMode == mode
                        ? Color.white
                        : Color.white.opacity(0.4)
                )
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(
                    Capsule().fill(
                        preferences.approvalMode == mode
                            ? Color(red: 0.32, green: 0.73, blue: 0.97).opacity(0.24)
                            : Color.white.opacity(0.04)
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func t(_ english: String, _ chinese: String) -> String {
        preferences.language.text(english, chinese)
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    private func toggleHooks() {
        if hooksInstalled {
            HookInstaller.uninstall()
            hooksInstalled = false
        } else {
            HookInstaller.installIfNeeded()
            hooksInstalled = true
        }
    }
}

private struct PresenceModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
            }
            .foregroundStyle(
                isSelected
                    ? Color(red: 0.98, green: 0.58, blue: 0.35)
                    : Color.white.opacity(0.48)
            )
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isSelected
                            ? Color(red: 0.95, green: 0.48, blue: 0.27)
                                .opacity(0.11)
                            : Color.white.opacity(0.04)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isSelected
                                    ? Color(red: 0.95, green: 0.48, blue: 0.27)
                                        .opacity(0.32)
                                    : Color.white.opacity(0.06)
                            )
                    }
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CompactControlTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        isOn
                            ? Color(red: 0.24, green: 0.72, blue: 0.64)
                            : Color.white.opacity(0.36)
                    )
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(
                            isOn
                                ? Color(red: 0.24, green: 0.72, blue: 0.64)
                                    .opacity(0.12)
                                : Color.white.opacity(0.05)
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(
                            isOn
                                ? Color(red: 0.24, green: 0.72, blue: 0.64)
                                : Color.white.opacity(0.3)
                        )
                }

                Spacer()
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isOn ? 0.055 : 0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.06))
                    }
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Update Row

struct UpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if case .installing = updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                            .onAppear { isSpinning = true }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(iconColor)
                    }
                }
                .frame(width: 16)

                // Label
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)

                Spacer()

                // Right side: progress or status
                rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && isInteractive ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch updateManager.state {
        case .idle:
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .found(let version, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }

        case .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }

        case .readyToInstall(let version):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .error:
            Text("Retry")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Computed Properties

    private var icon: String {
        switch updateManager.state {
        case .idle:
            return "arrow.down.circle"
        case .checking:
            return "arrow.down.circle"
        case .upToDate:
            return "checkmark.circle.fill"
        case .found:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "doc.zipper"
        case .readyToInstall:
            return "checkmark.circle.fill"
        case .installing:
            return "gear"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch updateManager.state {
        case .idle:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking:
            return .white.opacity(0.7)
        case .upToDate:
            return TerminalColors.green
        case .found, .readyToInstall:
            return TerminalColors.green
        case .downloading:
            return TerminalColors.blue
        case .extracting:
            return TerminalColors.amber
        case .installing:
            return TerminalColors.blue
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var label: String {
        switch updateManager.state {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking..."
        case .upToDate:
            return "Check for Updates"
        case .found:
            return "Download Update"
        case .downloading:
            return "Downloading..."
        case .extracting:
            return "Extracting..."
        case .readyToInstall:
            return "Install & Relaunch"
        case .installing:
            return "Installing..."
        case .error:
            return "Update failed"
        }
    }

    private var labelColor: Color {
        switch updateManager.state {
        case .idle, .upToDate:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking, .downloading, .extracting, .installing:
            return .white.opacity(0.9)
        case .found, .readyToInstall:
            return TerminalColors.green
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        case .checking, .downloading, .extracting, .installing:
            return false
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}

// MARK: - Accessibility Permission Row

struct AccessibilityRow: View {
    let isEnabled: Bool

    @State private var isHovered = false
    @State private var refreshTrigger = false

    private var currentlyEnabled: Bool {
        // Re-check on each render when refreshTrigger changes
        _ = refreshTrigger
        return isEnabled
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer()

            if isEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Button(action: openAccessibilitySettings) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}
