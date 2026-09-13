// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var importing = false
    @State private var errorMessage: String?

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

    private var pickerSelection: String {
        if selected.hasPrefix("custom:") || NotificationSound(rawValue: selected) != nil { return selected }
        switch event {
        case .followUp: return ""
        case .completion: return NotificationSound.pop.rawValue
        case .approval, .question: return NotificationSound.none.rawValue
        }
    }

    private var effectiveSelection: String {
        event == .followUp && pickerSelection.isEmpty ? completionChoice : pickerSelection
    }

    private var customUnavailable: Bool {
        guard effectiveSelection.hasPrefix("custom:") else { return false }
        guard let record = NotchImportedSound.decode(effectiveSelection) else { return true }
        return !NotchCustomSoundStore.isAvailable(record)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Picker(title, selection: Binding(
                get: { pickerSelection },
                set: { newValue in
                    let oldRecord = NotchImportedSound.decode(selected)
                    NotchSoundPlayer.shared.stop()
                    selected = newValue
                    errorMessage = nil
                    if let oldRecord { NotchCustomSoundStore.removeIfUnreferenced(oldRecord) }
                }
            )) {
                if event == .followUp {
                    Text(language.text("Same as completion", "跟随任务完成")).tag("")
                }
                if selected.hasPrefix("custom:") {
                    Text(language.text("File: ", "文件：") +
                         (NotchImportedSound.decode(selected)?.displayName ?? language.text("Unavailable", "不可用")))
                        .tag(selected)
                }
                ForEach(NotificationSound.allCases, id: \.rawValue) { choice in
                    Text(choice == .none ? language.text("None", "无") : choice.rawValue)
                        .tag(choice.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button(action: chooseFile) {
                if importing { ProgressView().controlSize(.small) }
                else { Image(systemName: "doc.badge.plus") }
            }
            .help(language.text("Import WAV, MP3 or AIFF · up to 10 MB / 30 seconds", "导入 WAV、MP3 或 AIFF · 不超过 10 MB / 30 秒"))
            .accessibilityLabel(language.text("Import \(title) sound", "导入\(title)提醒音"))
            Button {
                if !NotchSoundPlayer.shared.preview(for: event) {
                    errorMessage = language.text("Could not play this sound. Choose another file or a system sound.",
                                                 "无法播放此声音，请重新导入或选择系统声音。")
                }
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(NotchSoundSettings.source(for: event) == nil || volume == 0)
            .help(language.text("Preview sound", "试听声音"))
            .accessibilityLabel(language.text("Preview \(title)", "试听\(title)"))
        }
        .disabled(importing)
        if importing {
            Text(language.text("Checking and importing audio…", "正在校验并导入音频…"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if let message = errorMessage ?? (customUnavailable
            ? language.text("Custom sound unavailable. Import it again or choose a system sound.",
                            "自定义声音不可用，请重新导入或选择系统声音。") : nil) {
            Text(message).font(.system(size: 10)).foregroundStyle(.red)
        }
      }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = language.text("Choose a short alert sound (up to 10 MB / 30 seconds). A local copy is kept; the original is not changed.",
                                      "选择不超过 10 MB / 30 秒的短提醒音。应用会保留副本，不修改原文件。")
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let previousSelection = selected
            importing = true
            errorMessage = nil
            Task { @MainActor in
                defer { importing = false }
                do {
                    let record = try await Task.detached(priority: .userInitiated) {
                        try NotchCustomSoundStore.importSound(from: url)
                    }.value
                    // Do not overwrite a preference changed in another view
                    // while the file was being copied/decoded.
                    guard (UserDefaults.standard.string(forKey: event.key) ?? "") == previousSelection else {
                        NotchCustomSoundStore.removeIfUnreferenced(record)
                        errorMessage = language.text("Sound changed during import. Please try again.", "导入期间声音设置已改变，请重试。")
                        return
                    }
                    let raw = try record.rawValue
                    NotchSoundPlayer.shared.stop()
                    selected = raw
                    if let oldRecord = NotchImportedSound.decode(previousSelection) {
                        NotchCustomSoundStore.removeIfUnreferenced(oldRecord)
                    }
                } catch {
                    errorMessage = (error as? NotchSoundImportError)?.message(language: language)
                        ?? language.text("Import failed. The previous sound has been kept.", "导入失败，已保留原声音设置。")
                }
            }
        }
        if let window = NSApp.keyWindow, window.styleMask.contains(.titled) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
