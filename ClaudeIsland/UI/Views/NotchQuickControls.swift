// Modified by lihao505 for Agent Notch, 2026.
import SwiftUI

/// Pure presentation with explicit bindings/actions. Offline previews never
/// need to touch shared preferences, login services or the hook installer.
struct NotchQuickControls: View {
    let language: AppLanguage
    @Binding var idleBehavior: IdleNotchBehavior
    @Binding var compactStyle: CompactNotchStyle
    @Binding var approvalMode: ApprovalMode
    @Binding var expandOnHover: Bool
    let hoverDelay: Double
    @Binding var showUsageLimits: Bool
    @Binding var launchAtLogin: Bool
    @Binding var hooksInstalled: Bool
    let hooksNeedRepair: Bool
    let isUpdatingHooks: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onToggleLanguage: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    displaySection
                    Divider().overlay(.white.opacity(0.1))
                    permissionsSection
                    Divider().overlay(.white.opacity(0.1))
                    systemSection
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(TerminalColors.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .font(.system(size: 12))
        .controlSize(.small)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(t("Back to tasks", "返回任务列表"))
            .accessibilityLabel(t("Back to tasks", "返回任务列表"))
            Text(t("Quick Settings", "快捷设置"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button(action: onToggleLanguage) {
                Label(language == .english ? "简体中文" : "English", systemImage: "globe")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(t("Switch to Simplified Chinese", "切换为英语"))
        }
        .foregroundStyle(.white)
        .frame(height: 32)
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(t("Appearance & behavior", "显示与行为"))
            controlRow(t("When idle", "闲置时"), icon: "moon") {
                Picker(t("When idle", "闲置时"), selection: $idleBehavior) {
                    Text(t("Stay visible", "常驻显示")).tag(IdleNotchBehavior.alwaysVisible)
                    Text(t("Smart hide", "智能隐藏")).tag(IdleNotchBehavior.smartHide)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 218)
            }
            controlRow(t("Small notch", "小刘海样式"), icon: "rectangle.topthird.inset.filled") {
                Picker(t("Small notch style", "小刘海样式"), selection: $compactStyle) {
                    Text(t("Simple", "简略")).tag(CompactNotchStyle.simple)
                    Text(t("Detailed", "详细")).tag(CompactNotchStyle.detailed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 218)
            }
            HStack(spacing: 24) {
                Toggle(isOn: $expandOnHover) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Expand on hover", "悬停展开"))
                        Text(expandOnHover ? String(format: "%.2f s", hoverDelay) : t("Off", "已关闭"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel(t("Expand on hover", "悬停展开"))
                Toggle(isOn: $showUsageLimits) {
                    Text(t("Show usage", "显示用量"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.switch)
            .frame(minHeight: 36)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(t("Permissions", "权限"))
            controlRow(t("Default approvals", "默认审批"), icon: "hand.raised") {
                Picker(t("Default approvals", "默认审批"), selection: $approvalMode) {
                    Text(t("Ask each time", "每次询问")).tag(ApprovalMode.ask)
                    Text(t("Automatic", "自动批准")).tag(ApprovalMode.auto)
                    Text(t("Fully trusted", "完全信任")).tag(ApprovalMode.trusted)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 170)
            }
            Text(approvalExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(t("System & integration", "系统与集成"))
            Toggle(isOn: $launchAtLogin) {
                Label(t("Launch at login", "登录时启动"), systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .frame(minHeight: 36)
            Toggle(isOn: $hooksInstalled) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("Agent Bridge", "智能体桥接"))
                        Text(bridgeStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    if isUpdatingHooks {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel(t("Updating bridge", "正在更新桥接"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .disabled(isUpdatingHooks)
            .accessibilityLabel(t("Agent Bridge", "智能体桥接"))
            .accessibilityHint(bridgeStatus)
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onOpenSettings) {
                HStack {
                    Label(t("All Settings…", "完整设置…"), systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .help(t("Open the settings window", "打开独立设置窗口"))
            Button(action: onQuit) {
                Label(t("Quit", "退出"), systemImage: "power")
                    .frame(height: 28)
            }
            .help(t("Quit Agent Notch completely", "完全退出 Agent Notch"))
            .accessibilityLabel(t("Quit Agent Notch completely", "完全退出 Agent Notch"))
        }
        .buttonStyle(.bordered)
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
        }
    }

    private var approvalExplanation: String {
        let mode: String
        switch approvalMode {
        case .ask: mode = t("Ask before each tool request.", "每次工具请求都先询问你。")
        case .auto: mode = t("Allow ordinary tools this run; resets after restart.", "本次运行自动批准普通工具；重启后恢复询问。")
        case .trusted: mode = t("Allow ordinary tools even when the app is closed.", "即使 App 未运行，也自动批准普通工具请求。")
        }
        return mode + t(" Questions and plans still need your input.", "问题和计划仍需你确认。")
    }

    private var bridgeStatus: String {
        if isUpdatingHooks { return t("Updating…", "正在更新…") }
        if hooksNeedRepair { return t("Needs repair · see All Settings", "需要修复 · 请查看完整设置") }
        return hooksInstalled ? t("Enabled", "已启用") : t("Not enabled", "未启用")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func controlRow<Control: View>(
        _ title: String, icon: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .lineLimit(1)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 36)
    }

    private func t(_ english: String, _ chinese: String) -> String {
        language.text(english, chinese)
    }
}
