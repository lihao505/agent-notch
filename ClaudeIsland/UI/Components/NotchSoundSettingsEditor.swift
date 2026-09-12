// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import SwiftUI

struct NotchSoundSettingsEditor: View {
    let language: AppLanguage
    @AppStorage(NotchSoundSettings.enabledKey) private var enabled = true

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(language.text("Automatic sounds", "自动提醒音"))
                    .font(.system(size: 12))
                Spacer()
                Toggle(language.text("Automatic sounds", "自动提醒音"), isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            ForEach(NotchSoundEvent.allCases) { event in
                NotchSoundRow(event: event, language: language)
            }
            Text(language.text(
                "Quiet scenes, quiet hours and silence rules apply to automatic sounds. Preview plays only when you press the play button.",
                "自动声音遵循静默场景、静默时段和静默规则。试听仅在点击播放按钮时响起。"
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
    }
}

private struct NotchSoundRow: View {
    let event: NotchSoundEvent
    let language: AppLanguage
    @AppStorage private var selected: String
    @AppStorage("notificationSound") private var completionChoice = "Pop"

    init(event: NotchSoundEvent, language: AppLanguage) {
        self.event = event
        self.language = language
        _selected = AppStorage(wrappedValue: "", event.key)
    }

    private var title: String {
        switch event {
        case .completion: return language.text("Completion", "任务完成")
        case .approval: return language.text("Approval / plan", "审批 / 计划确认")
        case .question: return language.text("Question", "等待回答")
        case .followUp: return language.text("Follow-up", "跟进提醒")
        }
    }

    private var sound: NotificationSound {
        if event == .followUp, NotificationSound(rawValue: selected) == nil {
            return NotificationSound(rawValue: completionChoice) ?? .pop
        }
        return NotificationSound(rawValue: selected) ?? NotchSoundSettings.sound(for: event)
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Picker(title, selection: Binding(
                get: {
                    event == .followUp && NotificationSound(rawValue: selected) == nil
                        ? "" : sound.rawValue
                },
                set: { selected = $0 }
            )) {
                if event == .followUp {
                    Text(language.text("Same as completion", "跟随任务完成")).tag("")
                }
                ForEach(NotificationSound.allCases, id: \.rawValue) { choice in
                    Text(choice == .none ? language.text("None", "无") : choice.rawValue)
                        .tag(choice.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button {
                if let name = sound.soundName { NSSound(named: name)?.play() }
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(sound == .none)
            .help(language.text("Preview sound", "试听声音"))
            .accessibilityLabel(language.text("Preview \(title)", "试听\(title)"))
        }
    }
}
