// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import SwiftUI

struct NotchSoundSettingsEditor: View {
    let language: AppLanguage
    @AppStorage(NotchSoundSettings.enabledKey) private var enabled = true
    @AppStorage(NotchSoundSettings.volumeKey) private var storedVolume = 1.0

    private var volume: Double { NotchSoundSettings.normalizedVolume(storedVolume) }

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
            HStack(spacing: 12) {
                Text(language.text("Sound volume", "提醒音量"))
                    .font(.system(size: 12))
                Slider(value: Binding(
                    get: { volume },
                    set: { storedVolume = $0 }
                ), in: 0...1, step: 0.01)
                    .accessibilityLabel(language.text("Sound volume", "提醒音量"))
                    .accessibilityValue("\(Int((volume * 100).rounded()))%")
                Text("\(Int((volume * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            ForEach(NotchSoundEvent.allCases) { event in
                NotchSoundRow(event: event, language: language, volume: volume)
            }
            Text(language.text(
                "Volume applies to alerts and previews, not system volume. At 0%, both are silent. Automatic sounds follow quiet scenes, quiet hours and silence rules. Preview only plays when you press play.",
                "音量同时用于提醒和试听，不修改系统音量；0% 时均无声。自动声音遵循静默场景、静默时段和静默规则。试听仅在点击播放时响起。"
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .onChange(of: storedVolume) { _, _ in
            NotchSoundPlayer.shared.refreshSettings()
        }
        .onChange(of: enabled) { _, _ in
            NotchSoundPlayer.shared.refreshSettings()
        }
    }
}

private struct NotchSoundRow: View {
    let event: NotchSoundEvent
    let language: AppLanguage
    let volume: Double
    @AppStorage private var selected: String
    @AppStorage("notificationSound") private var completionChoice = "Pop"

    init(event: NotchSoundEvent, language: AppLanguage, volume: Double) {
        self.event = event
        self.language = language
        self.volume = volume
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
                NotchSoundPlayer.shared.preview(sound)
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(sound == .none || volume == 0)
            .help(language.text("Preview sound", "试听声音"))
            .accessibilityLabel(language.text("Preview \(title)", "试听\(title)"))
        }
    }
}
