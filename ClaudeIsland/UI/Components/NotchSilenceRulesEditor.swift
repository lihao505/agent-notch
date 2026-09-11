//
//  Modified by lihao505 for Agent Notch, 2026.
//  NotchSilenceRulesEditor.swift
//  ClaudeIsland
//
//  Compact, immediate editor with live matching against current sessions.
//

import Combine
import SwiftUI

@MainActor
private final class NotchSilencePreviewSource: ObservableObject {
    @Published private(set) var contexts: [NotchSilenceContext] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.contexts = sessions.map(NotchSilenceContext.init)
            }
            .store(in: &cancellables)
    }
}

struct NotchSilenceRulesEditor: View {
    @ObservedObject var store: NotchSilenceRuleStore
    let language: AppLanguage

    @StateObject private var previewSource = NotchSilencePreviewSource()
    @State private var draftScope: NotchSilenceRuleScope = .project
    @State private var draftPattern = ""
    @State private var editingRuleId: UUID?
    @FocusState private var isPatternFocused: Bool

    private let accent = Color(red: 0.95, green: 0.48, blue: 0.27)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker("", selection: $draftScope) {
                    ForEach(NotchSilenceRuleScope.allCases) { scope in
                        Text(scopeTitle(scope)).tag(scope)
                    }
                }
                .labelsHidden()
                .frame(width: 132)

                TextField(patternPlaceholder, text: $draftPattern)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPatternFocused)
                    .onSubmit(saveDraftRule)
                    .onExitCommand { cancelEditing() }

                Button(action: saveDraftRule) {
                    Label(
                        editingRuleId == nil ? t("Add", "添加") : t("Save", "保存"),
                        systemImage: editingRuleId == nil ? "plus" : "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!canAddDraftRule)
            }

            if editingRuleId != nil {
                HStack {
                    Text(t("Editing rule · changes apply when saved", "正在编辑规则 · 保存后生效"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Cancel", "取消"), action: cancelEditing)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Label(previewMessage, systemImage: previewSymbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(previewColor)

                Spacer(minLength: 8)

                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(shortDisplay(suggestion)) {
                                draftPattern = suggestion
                            }
                        }
                    } label: {
                        Label(
                            t("Suggestions", "建议"),
                            systemImage: "sparkle.magnifyingglass"
                        )
                        .font(.system(size: 10, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if store.rules.isEmpty {
                Divider()
                Label(
                    t(
                        "No rules yet. All sessions can request attention.",
                        "尚无规则，所有会话均可请求提醒。"
                    ),
                    systemImage: "bell"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(store.rules.enumerated()), id: \.element.id) {
                        index, rule in
                        ruleRow(rule)
                        if index < store.rules.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }

            Text(
                t(
                    "Rules suppress automatic expansion, completion bounce, sounds and follow-up reminders. The session and every approval remain available when you open the notch.",
                    "规则会抑制自动展开、完成弹跳、声音和跟进提醒；打开刘海后，会话与所有审批仍然可见。"
                )
            )
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ruleRow(_ rule: NotchSilenceRule) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { store.setEnabled($0, for: rule.id) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(scopeTitle(rule.scope))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(rule.isEnabled ? accent : .secondary)
                    Text(rule.pattern)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(ruleMatchMessage(rule))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                editingRuleId = rule.id
                draftScope = rule.scope
                draftPattern = rule.pattern
                isPatternFocused = true
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(t("Edit rule", "编辑规则"))
            .accessibilityLabel(t("Edit rule", "编辑规则"))

            Button {
                store.removeRule(id: rule.id)
                if editingRuleId == rule.id { cancelEditing() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(t("Remove rule", "删除规则"))
            .accessibilityLabel(t("Remove rule", "删除规则"))
        }
        .padding(.vertical, 9)
        .opacity(rule.isEnabled ? 1 : 0.62)
    }

    private var cleanedDraftPattern: String? {
        NotchSilenceRuleStore.cleanedPattern(draftPattern)
    }

    private var canAddDraftRule: Bool {
        guard let pattern = cleanedDraftPattern else { return false }
        return (editingRuleId != nil || store.rules.count < NotchSilenceRuleStore.maximumRuleCount) &&
            !store.contains(scope: draftScope, pattern: pattern, excluding: editingRuleId)
    }

    private var draftMatchCount: Int {
        guard let pattern = cleanedDraftPattern else { return 0 }
        let rule = NotchSilenceRule(scope: draftScope, pattern: pattern)
        return NotchSilenceRuleMatcher.matchCount(
            for: rule,
            in: previewSource.contexts
        )
    }

    private var previewMessage: String {
        if draftPattern.trimmingCharacters(in: .whitespacesAndNewlines).count >
            NotchSilenceRuleStore.maximumPatternLength {
            return t(
                "Use up to 256 characters; your rule will not be shortened.",
                "最多输入 256 个字符；规则不会自动截断。"
            )
        }
        guard let pattern = cleanedDraftPattern else {
            return t(
                "Enter text to see live matches",
                "输入文本即可实时查看匹配"
            )
        }
        if store.contains(scope: draftScope, pattern: pattern, excluding: editingRuleId) {
            return t("This rule already exists", "这条规则已存在")
        }
        if editingRuleId == nil && store.rules.count >= NotchSilenceRuleStore.maximumRuleCount {
            return t("Rule limit reached", "已达到规则数量上限")
        }
        guard !previewSource.contexts.isEmpty else {
            return t(
                "No active sessions; future sessions will still be matched",
                "当前无活跃会话；后续会话仍会应用规则"
            )
        }
        return t(
            "Matches \(draftMatchCount) of \(previewSource.contexts.count) active sessions",
            "匹配 \(previewSource.contexts.count) 个活跃会话中的 \(draftMatchCount) 个"
        )
    }

    private var previewSymbol: String {
        guard cleanedDraftPattern != nil else { return "text.magnifyingglass" }
        return draftMatchCount > 0 ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var previewColor: Color {
        draftMatchCount > 0 ? accent : .secondary
    }

    private var suggestions: [String] {
        var seen: Set<String> = []
        return previewSource.contexts
            .flatMap { $0.values(for: draftScope) }
            .compactMap { suggestionValue($0) }
            .filter { value in
                let key = value.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                return seen.insert(key).inserted
            }
            .prefix(6)
            .map { $0 }
    }

    private var patternPlaceholder: String {
        switch draftScope {
        case .project:
            return t("Project name or path contains…", "项目名或路径包含…")
        case .prompt:
            return t("Title or initial prompt contains…", "标题或首条提示词包含…")
        case .agent:
            return t("Agent or CLI contains…", "Agent 或 CLI 包含…")
        case .tool:
            return t("Tool name contains…", "工具名包含…")
        }
    }

    private func ruleMatchMessage(_ rule: NotchSilenceRule) -> String {
        guard rule.isEnabled else { return t("Disabled", "已停用") }
        let count = NotchSilenceRuleMatcher.matchCount(
            for: rule,
            in: previewSource.contexts
        )
        return t(
            "\(count) current session\(count == 1 ? "" : "s") matched",
            "当前命中 \(count) 个会话"
        )
    }

    private func scopeTitle(_ scope: NotchSilenceRuleScope) -> String {
        switch scope {
        case .project: return t("Project", "项目")
        case .prompt: return t("Prompt / title", "提示词 / 标题")
        case .agent: return t("Agent / CLI", "Agent / CLI")
        case .tool: return t("Tool", "工具")
        }
    }

    private func suggestionValue(_ value: String) -> String? {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return nil }
        switch draftScope {
        case .prompt:
            return String(singleLine.prefix(96))
        default:
            return String(singleLine.prefix(
                NotchSilenceRuleStore.maximumPatternLength
            ))
        }
    }

    private func shortDisplay(_ value: String) -> String {
        value.count > 72 ? String(value.prefix(69)) + "…" : value
    }

    private func saveDraftRule() {
        let saved: Bool
        if let id = editingRuleId {
            saved = store.updateRule(id: id, scope: draftScope, pattern: draftPattern)
        } else {
            saved = store.addRule(scope: draftScope, pattern: draftPattern)
        }
        guard saved else { return }
        cancelEditing()
    }

    private func cancelEditing() {
        editingRuleId = nil
        draftPattern = ""
    }

    private func t(_ english: String, _ chinese: String) -> String {
        language.text(english, chinese)
    }
}
