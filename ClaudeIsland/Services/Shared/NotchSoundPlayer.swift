// Modified by lihao505 for Agent Notch, 2026.
import AppKit

@MainActor
protocol NotchSoundPlayback: AnyObject {
    var volume: Float { get set }
    func play() -> Bool
    func stop() -> Bool
}

extension NSSound: NotchSoundPlayback {}

/// Own only one short alert at a time. No audio object is created for a muted
/// event, and preference changes can adjust/stop playback but never start it.
@MainActor
final class NotchSoundPlayer {
    static let shared = NotchSoundPlayer()

    private let defaults: UserDefaults
    private let directory: URL
    private let makeSound: @MainActor (NotchSoundSource) -> (any NotchSoundPlayback)?
    private var currentSound: (any NotchSoundPlayback)?
    private var automaticEvent: NotchSoundEvent?
    private var settingsObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        observeChanges: Bool = true,
        directory: URL = NotchCustomSoundStore.directory,
        makeSound: (@MainActor (NotchSoundSource) -> (any NotchSoundPlayback)?)? = nil
    ) {
        self.defaults = defaults
        self.directory = directory
        self.makeSound = makeSound ?? {
            // Named sounds are cached by AppKit; own a copy so gain and stop
            // changes cannot alter other users of the named sound instance.
            switch $0 {
            case .system(let sound):
                guard let name = sound.soundName else { return nil }
                return NSSound(named: name)?.copy() as? NSSound
            case .file(let record):
                guard NotchCustomSoundStore.isAvailable(record, in: directory) else { return nil }
                return NSSound(contentsOf: NotchCustomSoundStore.fileURL(for: record, in: directory), byReference: false)
            }
        }
        if observeChanges {
            settingsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSettings() }
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    @discardableResult
    func playAutomatic(for event: NotchSoundEvent) -> Bool {
        play(NotchSoundSettings.automaticSource(for: event, defaults: defaults, directory: directory), automaticEvent: event)
    }

    @discardableResult
    func preview(_ sound: NotificationSound) -> Bool {
        play(sound == .none ? nil : .system(sound), automaticEvent: nil)
    }

    @discardableResult
    func preview(for event: NotchSoundEvent) -> Bool {
        play(NotchSoundSettings.source(for: event, defaults: defaults, directory: directory), automaticEvent: nil)
    }

    func refreshSettings() {
        let volume = NotchSoundSettings.volume(defaults: defaults)
        if volume == 0 || automaticEvent.map({
            NotchSoundSettings.automaticSource(for: $0, defaults: defaults, directory: directory) == nil
        }) == true {
            stop()
        } else {
            currentSound?.volume = Float(volume)
        }
    }

    func stop() {
        _ = currentSound?.stop()
        currentSound = nil
        automaticEvent = nil
    }

    private func play(_ source: NotchSoundSource?, automaticEvent: NotchSoundEvent?) -> Bool {
        let volume = NotchSoundSettings.volume(defaults: defaults)
        guard volume > 0, let source,
              let nextSound = makeSound(source) else { return false }
        stop()
        nextSound.volume = Float(volume)
        guard nextSound.play() else { return false }
        currentSound = nextSound
        self.automaticEvent = automaticEvent
        return true
    }
}
