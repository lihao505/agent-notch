// Modified by lihao505 for Agent Notch, 2026.
import Combine
import KeyboardShortcuts
import SwiftUI

struct NotchShortcutSettingsEditor: View {
    let language: AppLanguage
    @State private var conflicts: Set<NotchShortcutAction> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(NotchShortcutAction.allCases) { action in
                if action != .toggle { Divider() }
                KeyboardShortcuts.Recorder(action.title(language), name: action.name) { _ in
                    refreshConflicts()
                }
                .accessibilityIdentifier("notch.\(action.rawValue)ShortcutRecorder")

                if conflicts.contains(action) {
                    Label(language.text(
                        "This combination has multiple actions. Change or clear one; conflicting actions are paused.",
                        "此组合键分配了多个动作，请修改或清除其中一个；冲突动作已暂停。"
                    ), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(language.text(
                "Previous / next opens conversations in list order, wrapping at either end. It does not jump to a terminal or answer requests. All shortcuts start unassigned.",
                "上一个 / 下一个按列表顺序循环打开刘海内的会话，不跳转终端、不回答请求。所有快捷键默认未绑定。"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Text(language.text(
                "Click to record. Escape cancels; the clear button removes a shortcut. System and menu conflicts are checked. Approval shortcuts remain local to the notch.",
                "点击录制；Escape 取消，清除按钮移除快捷键。会检查系统和菜单快捷键冲突。审批快捷键仍仅在刘海内生效。"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .onAppear { refreshConflicts() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in refreshConflicts() }
    }

    private func refreshConflicts() {
        let current = NotchShortcutConflictPolicy.currentConflicts()
        if conflicts != current { conflicts = current }
    }
}
