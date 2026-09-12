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
    private let makeSound: (String) -> (any NotchSoundPlayback)?
    private var currentSound: (any NotchSoundPlayback)?
    private var automaticEvent: NotchSoundEvent?
    private var settingsObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        observeChanges: Bool = true,
        makeSound: @escaping (String) -> (any NotchSoundPlayback)? = {
            // Named sounds are cached by AppKit; own a copy so gain and stop
            // changes cannot alter other users of the named sound instance.
            NSSound(named: $0)?.copy() as? NSSound
        }
    ) {
        self.defaults = defaults
        self.makeSound = makeSound
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
        play(NotchSoundSettings.automaticSound(for: event, defaults: defaults), automaticEvent: event)
    }

    @discardableResult
    func preview(_ sound: NotificationSound) -> Bool {
        play(sound, automaticEvent: nil)
    }

    func refreshSettings() {
        let volume = NotchSoundSettings.volume(defaults: defaults)
        if volume == 0 || automaticEvent.map({
            NotchSoundSettings.automaticSound(for: $0, defaults: defaults) == .none
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

    private func play(_ sound: NotificationSound, automaticEvent: NotchSoundEvent?) -> Bool {
        let volume = NotchSoundSettings.volume(defaults: defaults)
        guard volume > 0, let name = sound.soundName,
              let nextSound = makeSound(name) else { return false }
        stop()
        nextSound.volume = Float(volume)
        guard nextSound.play() else { return false }
        currentSound = nextSound
        self.automaticEvent = automaticEvent
        return true
    }
}
