//
//  OnboardingView.swift
//  ClaudeIsland
//
//  Short, skippable first-run guide for Agent Notch.
//

import SwiftUI

@MainActor
struct OnboardingView: View {
    /// `true` means the user explicitly chose to enable local agent hooks.
    /// Skipping or closing the guide keeps every agent config untouched.
    let onFinish: (Bool) -> Void

    @StateObject private var preferences = NotchPreferences.shared
    @State private var page = 0
    @State private var glowExpanded = false

    private let pageCount = 3

    var body: some View {
        ZStack {
            onboardingBackground

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 22)

                ZStack {
                    pageContent
                        .id(page)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing)
                                    .combined(with: .opacity),
                                removal: .move(edge: .leading)
                                    .combined(with: .opacity)
                            )
                        )
                }
                .animation(
                    .spring(response: 0.48, dampingFraction: 0.86),
                    value: page
                )

                footer
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .frame(width: 720, height: 480)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 2.8)
                    .repeatForever(autoreverses: true)
            ) {
                glowExpanded = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.49, blue: 0.30),
                                Color(red: 0.48, green: 0.31, blue: 0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Notch")
                    .font(.system(size: 15, weight: .bold))
                Text(t("First minute", "一分钟上手"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Button {
                preferences.language =
                    preferences.language == .english
                    ? .simplifiedChinese
                    : .english
            } label: {
                Text(
                    preferences.language == .english
                        ? "中文"
                        : "EN"
                )
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 38, height: 26)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.07))
                        .overlay {
                            Capsule()
                                .strokeBorder(.white.opacity(0.10))
                        }
                )
            }
            .buttonStyle(.plain)

            Button(t("Skip", "跳过")) {
                onFinish(false)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.52))
            .padding(.leading, 4)
        }
    }

    private var pageContent: some View {
        VStack(spacing: 20) {
            animatedNotch

            VStack(spacing: 8) {
                Text(pageTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text(pageSubtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 510)
            }

            pageDetails
        }
        .padding(.top, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var animatedNotch: some View {
        HStack(spacing: 18) {
            VibePetIcon(
                size: 54,
                motion: petMotion
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .bold))
                Text(statusCaption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.43))
            }

            Spacer()

            statusAnimation
                .frame(width: 34, height: 34)
        }
        .padding(.horizontal, 24)
        .frame(width: 430, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 25)
                .fill(.black.opacity(0.94))
                .overlay {
                    RoundedRectangle(cornerRadius: 25)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    accentColor.opacity(0.52),
                                    .white.opacity(0.06)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
                .shadow(
                    color: accentColor.opacity(
                        glowExpanded ? 0.24 : 0.10
                    ),
                    radius: glowExpanded ? 22 : 10
                )
        )
    }

    @ViewBuilder
    private var statusAnimation: some View {
        switch page {
        case 0:
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.14))
                    .frame(
                        width: glowExpanded ? 26 : 18,
                        height: glowExpanded ? 26 : 18
                    )
                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: accentColor, radius: 5)
            }
        case 1:
            PixelLoaderIcon(size: 30)
        default:
            WaitingPixelIndicatorIcon(size: 30)
        }
    }

    @ViewBuilder
    private var pageDetails: some View {
        switch page {
        case 0:
            HStack(spacing: 8) {
                compactFeature("sparkles", t("Always ready", "随时可用"))
                compactFeature("eye", t("One glance", "一眼掌握"))
                compactFeature("hand.tap", t("One click", "一点即达"))
            }
        case 1:
            HStack(spacing: 9) {
                agentChip(
                    name: "Claude",
                    color: Color(red: 0.88, green: 0.48, blue: 0.33)
                )
                agentChip(
                    name: "Codex",
                    color: Color(red: 0.20, green: 0.67, blue: 0.88)
                )
                agentChip(
                    name: "CodeBuddy",
                    color: Color(red: 0.48, green: 0.74, blue: 0.48)
                )
            }
        default:
            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    compactFeature(
                        "bubble.left.and.text.bubble.right",
                        t("Reply", "直接回复")
                    )
                    compactFeature(
                        "checkmark.shield",
                        t("Approve", "处理审批")
                    )
                    compactFeature(
                        "arrow.up.forward.app",
                        t("Switch", "切换对话")
                    )
                }
                Text(t(
                    "Get started enables local hooks for supported agents. No conversation data is uploaded by Agent Notch.",
                    "“启用并开始”会为受支持的智能体安装本地 Hook；Agent Notch 不会上传对话数据。"
                ))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.40))
                .multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(
                            index == page
                                ? accentColor
                                : .white.opacity(0.15)
                        )
                        .frame(
                            width: index == page ? 22 : 7,
                            height: 7
                        )
                        .animation(
                            .spring(response: 0.35, dampingFraction: 0.8),
                            value: page
                        )
                }
            }

            Spacer()

            if page > 0 {
                Button(t("Back", "返回")) {
                    page -= 1
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.54))
                .padding(.trailing, 12)
            }

            Button {
                if page == pageCount - 1 {
                    onFinish(true)
                } else {
                    page += 1
                }
            } label: {
                HStack(spacing: 8) {
                    Text(
                        page == pageCount - 1
                            ? t("Enable & start", "启用并开始")
                            : t("Continue", "继续")
                    )
                    Image(
                        systemName: page == pageCount - 1
                            ? "checkmark"
                            : "arrow.right"
                    )
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black.opacity(0.84))
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(
                    Capsule()
                        .fill(accentColor)
                        .shadow(
                            color: accentColor.opacity(0.30),
                            radius: 10
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var onboardingBackground: some View {
        ZStack {
            Color(red: 0.035, green: 0.042, blue: 0.061)

            Circle()
                .fill(accentColor.opacity(0.16))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: glowExpanded ? 230 : 180, y: -170)

            Circle()
                .fill(
                    Color(red: 0.50, green: 0.28, blue: 0.86)
                        .opacity(0.10)
                )
                .frame(width: 300, height: 300)
                .blur(radius: 100)
                .offset(x: -270, y: 210)

            Canvas { context, size in
                for x in stride(from: 18.0, to: size.width, by: 26.0) {
                    for y in stride(from: 18.0, to: size.height, by: 26.0) {
                        context.fill(
                            Path(
                                CGRect(x: x, y: y, width: 1.4, height: 1.4)
                            ),
                            with: .color(.white.opacity(0.035))
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func compactFeature(
        _ icon: String,
        _ title: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accentColor)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.64))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(.white.opacity(0.055))
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.07))
                }
        )
    }

    private func agentChip(
        name: String,
        color: Color
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.65), radius: 4)
            Text(name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(color.opacity(0.10))
                .overlay {
                    Capsule()
                        .strokeBorder(color.opacity(0.22))
                }
        )
    }

    private var accentColor: Color {
        switch page {
        case 0:
            return Color(red: 0.25, green: 0.78, blue: 0.59)
        case 1:
            return Color(red: 0.35, green: 0.62, blue: 0.94)
        default:
            return Color(red: 0.95, green: 0.56, blue: 0.31)
        }
    }

    private var petMotion: VibePetMotion {
        switch page {
        case 0: return .idle
        case 1: return .working
        default: return .waiting
        }
    }

    private var pageTitle: String {
        switch page {
        case 0:
            return t(
                "Meet your agent workspace",
                "认识你的智能体工作台"
            )
        case 1:
            return t(
                "Every agent, one notch",
                "所有智能体，一个刘海"
            )
        default:
            return t(
                "Stay in your flow",
                "无需离开当前工作"
            )
        }
    }

    private var pageSubtitle: String {
        switch page {
        case 0:
            return t(
                "Agent Notch keeps active tasks visible without taking over your desktop.",
                "Agent Notch 将进行中的任务放在顶部，不打断你的桌面工作。"
            )
        case 1:
            return t(
                "Claude Code, Codex and CodeBuddy share one clear live view.",
                "Claude Code、Codex 与 CodeBuddy 的状态统一呈现。"
            )
        default:
            return t(
                "Open a conversation, reply, or handle approvals directly from the notch.",
                "从刘海直接打开对话、回复消息或处理审批。"
            )
        }
    }

    private var statusTitle: String {
        switch page {
        case 0: return t("Ready when you are", "随时待命")
        case 1: return t("Agents are working", "智能体正在工作")
        default: return t("Your input is needed", "等待你的处理")
        }
    }

    private var statusCaption: String {
        switch page {
        case 0: return t("Calm when idle", "空闲时保持安静")
        case 1: return t("Live progress at a glance", "进度一眼可见")
        default: return t("Reply or approve in place", "原地回复或审批")
        }
    }

    private func t(_ english: String, _ chinese: String) -> String {
        preferences.language.text(english, chinese)
    }
}

#Preview {
    OnboardingView { _ in }
}
