import AppKit
import ServiceManagement
import SwiftUI

private enum NotchStudioSection: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case usage = "Usage"
    case system = "System"

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .general: return language.text("General", "通用")
        case .appearance: return language.text("Appearance", "外观")
        case .usage: return language.text("Usage", "用量")
        case .system: return language.text("System", "系统")
        }
    }

    var icon: String {
        switch self {
        case .general: return "switch.2"
        case .appearance: return "rectangle.topthird.inset.filled"
        case .usage: return "chart.bar.fill"
        case .system: return "point.3.connected.trianglepath.dotted"
        }
    }
}

private enum NotchPreviewState: String, CaseIterable, Identifiable {
    case idle
    case working
    case waiting
    case complete

    var id: String { rawValue }

    var motion: VibePetMotion {
        switch self {
        case .idle: return .idle
        case .working: return .working
        case .waiting: return .waiting
        case .complete: return .ready
        }
    }
}

struct NotchStudioSettingsView: View {
    @StateObject private var preferences = NotchPreferences.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var selection: NotchStudioSection = .general
    @State private var launchAtLogin = false
    @State private var hooksInstalled = false
    @State private var notificationSound = AppSettings.notificationSound
    @State private var previewState: NotchPreviewState = .idle
    @Namespace private var sectionSelectionNamespace

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    pageHeader
                    notchPreview

                    Group {
                        switch selection {
                        case .general:
                            generalSettings
                        case .appearance:
                            appearanceSettings
                        case .usage:
                            usageSettings
                        case .system:
                            systemSettings
                        }
                    }
                }
                .padding(28)
            }
            .background {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(red: 0.08, green: 0.09, blue: 0.12)
                            .opacity(0.26),
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear {
            refreshSystemState()
            updateWindowTitle()
        }
        .onChange(of: preferences.language) { _, _ in
            updateWindowTitle()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("BrandIcon")
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent Notch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Claude · Codex · CodeBuddy")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 22)

            VStack(spacing: 5) {
                ForEach(NotchStudioSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .frame(width: 18)
                            Text(section.title(preferences.language))
                            Spacer()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            selection == section
                                ? Color.white
                                : Color.white.opacity(0.48)
                        )
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                        .background(
                            ZStack {
                                if selection == section {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(Color.white.opacity(0.11))
                                        .matchedGeometryEffect(
                                            id: "selected-section",
                                            in: sectionSelectionNamespace
                                        )
                                }
                            }
                        )
                        .overlay(alignment: .leading) {
                            if selection == section {
                                Capsule()
                                    .fill(
                                        Color(
                                            red: 0.95,
                                            green: 0.48,
                                            blue: 0.27
                                        )
                                    )
                                    .frame(width: 3, height: 16)
                                    .offset(x: -6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Text(t("Your agents, one glance away.", "一眼掌握所有智能体。"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.28))
                .padding(18)
        }
        .frame(width: 190)
        .background(Color(red: 0.055, green: 0.06, blue: 0.08))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selection.title(preferences.language))
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text(pageSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var pageSubtitle: String {
        switch selection {
        case .general:
            return t(
                "Choose when the notch appears and how it responds.",
                "选择刘海何时出现，以及如何响应。"
            )
        case .appearance:
            return t(
                "Tune the expanded canvas to fit the way you work.",
                "调整刘海尺寸与信息密度，适配你的工作方式。"
            )
        case .usage:
            return t(
                "Keep subscription limits visible without leaving your task.",
                "无需离开任务即可查看订阅用量。"
            )
        case .system:
            return t(
                "Manage displays, sounds and the local agent bridge.",
                "管理屏幕、声音与本地智能体桥接。"
            )
        }
    }

    private var notchPreview: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.08, blue: 0.11),
                        Color(red: 0.15, green: 0.11, blue: 0.18),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Canvas { context, size in
                    let spacing: CGFloat = 14
                    for x in stride(from: 7, through: size.width, by: spacing) {
                        for y in stride(from: 7, through: size.height, by: spacing) {
                            context.fill(
                                Path(
                                    CGRect(
                                        x: x,
                                        y: y,
                                        width: 1.5,
                                        height: 1.5
                                    )
                                ),
                                with: .color(.white.opacity(0.055))
                            )
                        }
                    }
                }
                .allowsHitTesting(false)

                VStack(spacing: 13) {
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Color.black.opacity(0.22))
                            .frame(height: 1)

                        HStack(spacing: 0) {
                            if !previewIsHidden {
                                HStack(spacing: 4) {
                                    VibePetIcon(
                                        size: 19,
                                        motion: previewState.motion
                                    )
                                    .frame(
                                        width:
                                            CompactNotchMetrics
                                                .animationCanvasSize,
                                        height:
                                            CompactNotchMetrics
                                                .animationCanvasSize
                                    )
                                    PetStateSignalIcon(
                                        motion: previewState.motion
                                    )
                                }
                                .frame(width: previewLeftWingWidth)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(
                                    width: previewCameraWidth +
                                        previewUserExtraWidth
                                )

                            if !previewIsHidden {
                                HStack(spacing: 5) {
                                    if preferences.compactStyle == .detailed {
                                        HStack(spacing: 3) {
                                            Image(
                                                systemName:
                                                    "square.stack.3d.up.fill"
                                            )
                                            Text("3")
                                                .font(
                                                    .system(
                                                        size: 9,
                                                        weight: .bold,
                                                        design: .rounded
                                                    )
                                                )
                                        }
                                        .font(.system(size: 7))
                                        .foregroundStyle(.white.opacity(0.58))
                                    }

                                    previewIndicator
                                }
                                .frame(width: previewRightWingWidth)
                            }
                        }
                        .frame(
                            width: previewIsHidden
                                ? previewCameraWidth
                                : previewWidth,
                            height: 32
                        )
                        .background(.black)
                        .clipShape(
                            NotchShape(
                                topCornerRadius: 6,
                                bottomCornerRadius: 14
                            )
                        )
                        .animation(
                            .spring(response: 0.34, dampingFraction: 0.82),
                            value: previewIsHidden
                        )
                        .animation(
                            .spring(response: 0.3, dampingFraction: 0.84),
                            value: preferences.compactStyle
                        )
                    }
                    .frame(height: 48, alignment: .top)

                    Text(
                        t(
                            "Live preview · does not change agent state",
                            "实时预览 · 不会修改真实任务状态"
                        )
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))

                    HStack(spacing: 7) {
                        ForEach(NotchPreviewState.allCases) { state in
                            previewStateButton(state)
                        }
                    }
                }
                .padding(.top, 0)
            }
            .frame(height: 136)

            HStack {
                Label(
                    previewStateTitle,
                    systemImage: previewStateSystemImage
                )
                .font(.system(size: 10, weight: .semibold))

                Spacer()

                Text(
                    previewIsHidden
                        ? t("Hardware notch only", "仅保留实体刘海")
                        : "\(Int(previewWidth)) pt"
                )
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.primary.opacity(0.025))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
    }

    private var previewCameraWidth: CGFloat { 198 }

    private var previewLeftWingWidth: CGFloat {
        CompactNotchMetrics.leftWingWidth
    }

    private var previewRightWingWidth: CGFloat {
        CompactNotchMetrics.rightWingWidth(
            for: preferences.compactStyle
        )
    }

    private var previewUserExtraWidth: CGFloat {
        CompactNotchMetrics.userExtraWidth(
            for: preferences.compactWidth
        )
    }

    private var previewWidth: CGFloat {
        previewCameraWidth + previewExtensionWidth
    }

    private var previewExtensionWidth: CGFloat {
        CompactNotchMetrics.visibleExtension(
            style: preferences.compactStyle,
            configuredWidth: preferences.compactWidth
        )
    }

    private var previewIsHidden: Bool {
        preferences.idleBehavior == .smartHide && previewState == .idle
    }

    @ViewBuilder
    private var previewIndicator: some View {
        switch previewState {
        case .idle:
            IdlePixelIndicatorIcon(size: 14)
                .frame(
                    width: CompactNotchMetrics.animationCanvasSize,
                    height: CompactNotchMetrics.animationCanvasSize
                )
                .id(previewState)
                .transition(.opacity.combined(with: .scale(scale: 0.72)))
        case .working:
            PixelLoaderIcon(size: 19)
                .frame(
                    width: CompactNotchMetrics.animationCanvasSize,
                    height: CompactNotchMetrics.animationCanvasSize
                )
                .id(previewState)
                .transition(.opacity.combined(with: .scale(scale: 0.72)))
        case .waiting:
            WaitingPixelIndicatorIcon(size: 19)
                .frame(
                    width: CompactNotchMetrics.animationCanvasSize,
                    height: CompactNotchMetrics.animationCanvasSize
                )
                .id(previewState)
                .transition(.opacity.combined(with: .scale(scale: 0.72)))
        case .complete:
            ReadyForInputIndicatorIcon(size: 14)
                .frame(
                    width: CompactNotchMetrics.animationCanvasSize,
                    height: CompactNotchMetrics.animationCanvasSize
                )
                .id(previewState)
                .transition(.opacity.combined(with: .scale(scale: 0.72)))
        }
    }

    private func previewStateButton(_ state: NotchPreviewState) -> some View {
        let selected = previewState == state

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                previewState = state
            }
        } label: {
            Text(previewStateShortTitle(for: state))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.42))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    Capsule()
                        .fill(
                            selected
                                ? previewStateColor(state).opacity(0.2)
                                : Color.white.opacity(0.045)
                        )
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            selected
                                ? previewStateColor(state).opacity(0.48)
                                : Color.white.opacity(0.05)
                        )
                        .allowsHitTesting(false)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var previewStateTitle: String {
        previewStateTitle(for: previewState)
    }

    private func previewStateShortTitle(
        for state: NotchPreviewState
    ) -> String {
        switch state {
        case .idle: return t("Idle", "空闲")
        case .working: return t("Working", "工作中")
        case .waiting: return t("Waiting", "等待")
        case .complete: return t("Complete", "已完成")
        }
    }

    private func previewStateTitle(for state: NotchPreviewState) -> String {
        switch state {
        case .idle: return t("Idle · gentle animation", "空闲 · 轻缓动画")
        case .working: return t("Working · animated", "工作中 · 动态提示")
        case .waiting: return t("Waiting · needs attention", "等待 · 需要处理")
        case .complete: return t("Complete · ready", "已完成 · 就绪标记")
        }
    }

    private var previewStateSystemImage: String {
        switch previewState {
        case .idle: return "moon.stars"
        case .working: return "bolt.fill"
        case .waiting: return "hand.raised.fill"
        case .complete: return "checkmark.circle.fill"
        }
    }

    private func previewStateColor(_ state: NotchPreviewState) -> Color {
        switch state {
        case .idle: return Color.white
        case .working: return Color(red: 0.95, green: 0.48, blue: 0.27)
        case .waiting: return Color(red: 0.75, green: 0.50, blue: 0.29)
        case .complete: return TerminalColors.green
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsTitle(
                t("Language", "语言"),
                caption: t(
                    "Changes apply instantly across the notch.",
                    "切换后立即应用到刘海与设置界面。"
                )
            )

            Picker("", selection: $preferences.language) {
                Text("English").tag(AppLanguage.english)
                Text("简体中文").tag(AppLanguage.simplifiedChinese)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            settingsTitle(
                t("Default approval policy", "默认审批方式"),
                caption: t(
                    "New conversations inherit this. Each chat can override it.",
                    "新对话继承此设置；每个聊天可单独覆盖。"
                )
            )

            settingsCard {
                VStack(spacing: 8) {
                    approvalModeCard(
                        .ask,
                        icon: "hand.raised.fill",
                        title: t("Single approval", "单次审批"),
                        subtitle: t(
                            "Show Allow / Deny for every tool request.",
                            "每次工具请求都显示允许 / 拒绝。"
                        )
                    )
                    approvalModeCard(
                        .auto,
                        icon: "bolt.fill",
                        title: t("Auto approve", "自动审批"),
                        subtitle: t(
                            "Allow tools while Agent Notch is open; resets after restart.",
                            "应用本次运行期间自动允许；重启后恢复单次审批。"
                        )
                    )
                    approvalModeCard(
                        .trusted,
                        icon: "lock.open.fill",
                        title: t("Fully trusted", "完全信任"),
                        subtitle: t(
                            "Keep allowing normal tool requests across restarts.",
                            "跨重启持续允许普通工具请求。"
                        )
                    )
                }

                Divider()

                Label(
                    t(
                        "Questions and plan approval always stay manual.",
                        "问答与计划确认始终保留为手动审批。"
                    ),
                    systemImage: "info.circle"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            settingsTitle(
                t("Idle presence", "空闲时显示"),
                caption: t(
                    "What remains when no agent is active",
                    "没有智能体工作时，刘海如何显示"
                )
            )

            HStack(spacing: 12) {
                behaviorCard(
                    behavior: .alwaysVisible,
                    icon: "sparkle",
                    title: t("Always Ready", "常驻显示"),
                    subtitle: t(
                        "Keep a small notch presence available.",
                        "保留一个随时可用的小刘海。"
                    )
                )
                behaviorCard(
                    behavior: .smartHide,
                    icon: "eye.slash",
                    title: t("Smart Hide", "智能隐藏"),
                    subtitle: t(
                        "Disappear until an agent needs attention.",
                        "智能体需要你时才显示。"
                    )
                )
            }

            settingsCard {
                settingToggle(
                    t("Expand on hover", "悬停展开"),
                    detail: t(
                        "Reveal the panel without clicking.",
                        "无需点击即可展开面板。"
                    ),
                    isOn: $preferences.expandOnHover
                )

                if preferences.expandOnHover {
                    Divider()
                    sliderRow(
                        title: t("Hover delay", "悬停延迟"),
                        value: $preferences.hoverDelay,
                        range: 0...2,
                        step: 0.05,
                        valueText: String(format: "%.2fs", preferences.hoverDelay)
                    )
                }

                Divider()
                settingToggle(
                    t("Collapse on mouse leave", "鼠标移开后收起"),
                    detail: t(
                        "Return to the compact notch automatically.",
                        "自动返回小刘海状态。"
                    ),
                    isOn: $preferences.collapseOnMouseLeave
                )

                if preferences.collapseOnMouseLeave {
                    Divider()
                    sliderRow(
                        title: t("Collapse delay", "收起延迟"),
                        value: $preferences.collapseDelay,
                        range: 0.2...3,
                        step: 0.05,
                        valueText: String(format: "%.2fs", preferences.collapseDelay)
                    )
                }

                Divider()
                sliderRow(
                    title: t("Completion dwell", "完成后停留"),
                    value: $preferences.completionCompactDuration,
                    range: 3...30,
                    step: 1,
                    valueText: "\(Int(preferences.completionCompactDuration))s"
                )
            }
        }
    }

    private func approvalModeCard(
        _ mode: ApprovalMode,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        let isSelected = preferences.approvalMode == mode
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                preferences.approvalMode = mode
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(
                            isSelected
                                ? Color(red: 0.95, green: 0.48, blue: 0.27)
                                : Color.primary.opacity(0.08)
                        )
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? Color(red: 0.95, green: 0.48, blue: 0.27)
                            : Color.secondary.opacity(0.45)
                    )
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.orange.opacity(0.08) : Color.primary.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isSelected ? Color.orange.opacity(0.45) : Color.primary.opacity(0.08),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    }
            )
        }
        .buttonStyle(.plain)
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsTitle(
                t("Small notch", "小刘海"),
                caption: t(
                    "Choose how much task information stays at a glance",
                    "选择常驻状态下显示多少任务信息"
                )
            )

            HStack(spacing: 12) {
                compactStyleCard(
                    style: .simple,
                    icon: "waveform.path",
                    title: t("Simple", "简略"),
                    subtitle: t(
                        "Pet motion and a pixel status symbol.",
                        "只显示桌宠动作与像素状态符号。"
                    )
                )
                compactStyleCard(
                    style: .detailed,
                    icon: "square.stack.3d.up.fill",
                    title: t("Detailed", "详细"),
                    subtitle: t(
                        "Also show the current task count.",
                        "额外显示当前任务数量。"
                    )
                )
            }

            settingsCard {
                sliderRow(
                    title: t("Compact width", "小刘海宽度"),
                    value: $preferences.compactWidth,
                    range: NotchPreferences.compactWidthRange,
                    step: 5,
                    valueText: "+\(Int(previewExtensionWidth)) pt"
                )

                Divider()

                HStack {
                    Text(
                        t(
                            "At minimum, each side only fits its content. Increase the slider to add balanced breathing room.",
                            "最小值仅容纳两侧动画；增大滑块会均匀增加额外留白。"
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button(t("Reset", "重置")) {
                        withAnimation(.spring(response: 0.3)) {
                            preferences.resetCompactWidth()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            settingsTitle(
                t("Expanded canvas", "展开面板"),
                caption: t(
                    "Set the maximum canvas; short task lists stay compact",
                    "设置最大尺寸；任务较少时仍会自动缩短"
                )
            )

            settingsCard {
                sliderRow(
                    title: t("Panel width", "面板宽度"),
                    value: $preferences.panelWidth,
                    range: 480...760,
                    step: 10,
                    valueText: "\(Int(preferences.panelWidth)) px"
                )
                Divider()
                sliderRow(
                    title: t("Panel height", "面板高度"),
                    value: $preferences.panelHeight,
                    range: 360...680,
                    step: 10,
                    valueText: "\(Int(preferences.panelHeight)) px"
                )
            }

            HStack {
                Label(
                    t(
                        "Changes apply to the next expansion.",
                        "下次展开时应用更改。"
                    ),
                    systemImage: "bolt.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Spacer()

                Button(t("Reset to 640 × 560", "重置为 640 × 560")) {
                    withAnimation(.spring(response: 0.3)) {
                        preferences.resetPanelSize()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var usageSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsTitle(
                t("Usage limits", "用量限制"),
                caption: t(
                    "A compact readout at the top of the expanded notch",
                    "在展开刘海顶部显示紧凑用量信息"
                )
            )

            settingsCard {
                settingToggle(
                    t("Show usage limits", "显示用量限制"),
                    detail: t(
                        "Read Claude and Codex limits from local session data.",
                        "从本地会话数据读取 Claude 与 Codex 用量。"
                    ),
                    isOn: $preferences.showUsageLimits
                )

                Divider()

                UsageDisplayModeSetting()
                    .disabled(!preferences.showUsageLimits)
                    .opacity(preferences.showUsageLimits ? 1 : 0.45)
            }

            HStack(spacing: 10) {
                sourcePill("Claude", color: Color(red: 0.95, green: 0.48, blue: 0.27))
                sourcePill("Codex", color: Color(red: 0.32, green: 0.67, blue: 0.95))
                Spacer()
                Text(t("Local only", "仅限本地"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsTitle(
                t("Agent bridge", "智能体桥接"),
                caption: t(
                    "Local connections for Claude Code, Codex, and CodeBuddy",
                    "连接本地 Claude Code、Codex 与 CodeBuddy"
                )
            )

            settingsCard {
                settingToggle(
                    t("Launch at login", "登录时启动"),
                    detail: t(
                        "Keep the notch ready after signing in.",
                        "登录后自动保持刘海可用。"
                    ),
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { _ in toggleLaunchAtLogin() }
                    )
                )
                Divider()
                settingToggle(
                    t("Claude hooks", "Claude 钩子"),
                    detail: t(
                        "Receive lifecycle and permission events locally.",
                        "在本地接收生命周期与权限事件。"
                    ),
                    isOn: Binding(
                        get: { hooksInstalled },
                        set: { _ in toggleHooks() }
                    )
                )
            }

            settingsTitle(
                t("Environment", "运行环境"),
                caption: t(
                    "Display, sound and agent paths",
                    "屏幕、声音与智能体路径"
                )
            )

            settingsCard {
                HStack {
                    settingLabel(
                        t("Display", "显示屏"),
                        detail: t(
                            "Choose where the notch should live.",
                            "选择刘海所在的屏幕。"
                        )
                    )
                    Spacer()
                    Picker("", selection: screenBinding) {
                        Text(t("Automatic", "自动")).tag("automatic")
                        ForEach(screenSelector.availableScreens, id: \.self) { screen in
                            Text(screen.localizedName).tag(screen.localizedName)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                Divider()

                HStack {
                    settingLabel(
                        t("Completion sound", "完成提示音"),
                        detail: t(
                            "Played when an agent is ready.",
                            "智能体完成任务时播放。"
                        )
                    )
                    Spacer()
                    Picker("", selection: $notificationSound) {
                        ForEach(NotificationSound.allCases, id: \.rawValue) { sound in
                            Text(sound.rawValue).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .onChange(of: notificationSound) { _, sound in
                        AppSettings.notificationSound = sound
                        if let name = sound.soundName {
                            NSSound(named: name)?.play()
                        }
                    }
                }

                Divider()

                HStack {
                    settingLabel(
                        t("Claude directory", "Claude 目录"),
                        detail: shortenedClaudeDirectory
                    )
                    Spacer()
                    Button(t("Auto", "自动")) {
                        applyClaudeDirectory("")
                    }
                    .buttonStyle(.bordered)
                    Button(t("Choose…", "选择…")) {
                        chooseClaudeDirectory()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            settingsCard {
                HStack {
                    settingLabel(
                        t("Accessibility", "辅助功能"),
                        detail: AXIsProcessTrusted()
                            ? t(
                                "Enabled for precise window switching.",
                                "已启用，可精确切换窗口。"
                            )
                            : t(
                                "Optional, used for precise window switching.",
                                "可选，用于精确切换窗口。"
                            )
                    )
                    Spacer()
                    if AXIsProcessTrusted() {
                        Label(
                            t("Enabled", "已启用"),
                            systemImage: "checkmark.circle.fill"
                        )
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Button(t("Open Settings", "打开设置")) {
                            openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                HStack {
                    settingLabel(
                        t("Software update", "软件更新"),
                        detail: t(
                            "Check the installed build for updates.",
                            "检查当前安装版本的更新。"
                        )
                    )
                    Spacer()
                    Button(updateButtonTitle) {
                        updateManager.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var screenBinding: Binding<String> {
        Binding(
            get: {
                if screenSelector.selectionMode == .automatic {
                    return "automatic"
                }
                return screenSelector.selectedScreen?.localizedName ?? "automatic"
            },
            set: { value in
                if value == "automatic" {
                    screenSelector.selectAutomatic()
                } else if let screen = screenSelector.availableScreens.first(
                    where: { $0.localizedName == value }
                ) {
                    screenSelector.selectScreen(screen)
                }
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: nil
                )
            }
        )
    }

    private var shortenedClaudeDirectory: String {
        let path = ClaudePaths.claudeDir.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count)
            : path
    }

    private var updateButtonTitle: String {
        switch updateManager.state {
        case .checking: return t("Checking…", "正在检查…")
        case .upToDate: return t("Up to date", "已是最新版本")
        case .found: return t("Update available", "有可用更新")
        default: return t("Check now", "立即检查")
        }
    }

    private func t(_ english: String, _ chinese: String) -> String {
        preferences.language.text(english, chinese)
    }

    private func updateWindowTitle() {
        DispatchQueue.main.async {
            NSApp.windows
                .first {
                    $0.identifier?.rawValue ==
                        "com_apple_SwiftUI_Settings_window"
                }?
                .title = t("Agent Notch Settings", "Agent Notch 设置")
        }
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func refreshSystemState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hooksInstalled = HookInstaller.isInstalled()
        notificationSound = AppSettings.notificationSound
        screenSelector.refreshScreens()
    }

    private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func toggleHooks() {
        if hooksInstalled {
            HookInstaller.uninstall()
        } else {
            HookInstaller.installIfNeeded()
        }
        hooksInstalled = HookInstaller.isInstalled()
    }

    private func chooseClaudeDirectory() {
        let panel = NSOpenPanel()
        panel.title = t(
            "Choose Claude Config Directory",
            "选择 Claude 配置目录"
        )
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = ClaudePaths.claudeDir

        if panel.runModal() == .OK, let url = panel.url {
            applyClaudeDirectory(url.path)
        }
    }

    private func applyClaudeDirectory(_ path: String) {
        AppSettings.claudeDirectoryName = path
        ClaudePaths.invalidateCache()
        HookInstaller.installIfNeeded()
        hooksInstalled = HookInstaller.isInstalled()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func behaviorCard(
        behavior: IdleNotchBehavior,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        let selected = preferences.idleBehavior == behavior

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                preferences.idleBehavior = behavior
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        selected
                            ? Color(red: 0.95, green: 0.48, blue: 0.27)
                            : .secondary
                    )
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(
                            selected
                                ? Color(red: 0.95, green: 0.48, blue: 0.27)
                                    .opacity(0.14)
                                : Color.primary.opacity(0.05)
                        )
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        selected
                            ? Color(red: 0.95, green: 0.48, blue: 0.27)
                            : Color.secondary.opacity(0.4)
                    )
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(
                        selected
                            ? Color(red: 0.95, green: 0.48, blue: 0.27)
                                .opacity(0.08)
                            : Color.primary.opacity(0.035)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(
                        selected
                            ? Color(red: 0.95, green: 0.48, blue: 0.27)
                                .opacity(0.45)
                            : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    private func compactStyleCard(
        style: CompactNotchStyle,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        let selected = preferences.compactStyle == style

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                preferences.compactStyle = style
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        selected
                            ? Color(red: 0.36, green: 0.67, blue: 0.98)
                            : .secondary
                    )
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(
                            selected
                                ? Color(red: 0.36, green: 0.67, blue: 0.98)
                                    .opacity(0.14)
                                : Color.primary.opacity(0.05)
                        )
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        selected
                            ? Color(red: 0.36, green: 0.67, blue: 0.98)
                            : Color.secondary.opacity(0.4)
                    )
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(
                        selected
                            ? Color(red: 0.36, green: 0.67, blue: 0.98)
                                .opacity(0.08)
                            : Color.primary.opacity(0.035)
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(
                        selected
                            ? Color(red: 0.36, green: 0.67, blue: 0.98)
                                .opacity(0.45)
                            : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
    }

    private func settingsTitle(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 14) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08))
                .allowsHitTesting(false)
        }
    }

    private func settingToggle(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.switch)
        .contentShape(Rectangle())
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(valueText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(Color(red: 0.95, green: 0.48, blue: 0.27))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
    }

    private func sourcePill(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.1)))
    }
}

private struct UsageDisplayModeSetting: View {
    @AppStorage("usageDisplayRemaining") private var displayRemaining = false
    @ObservedObject private var preferences = NotchPreferences.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(preferences.language.text("Display mode", "显示方式"))
                    .font(.system(size: 12, weight: .medium))
                Text(
                    preferences.language.text(
                        "Switch between consumed and available allowance.",
                        "切换已使用与剩余额度。"
                    )
                )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $displayRemaining) {
                Text(preferences.language.text("Used", "已使用")).tag(false)
                Text(preferences.language.text("Remaining", "剩余")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
    }
}
