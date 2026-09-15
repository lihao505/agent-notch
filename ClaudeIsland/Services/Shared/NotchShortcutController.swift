// Modified by lihao505 for Agent Notch, 2026.
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Intentionally unbound: never take over an existing global combination.
    static let toggleNotch = Self("agentNotch.toggleNotch")
}

/// One app-owned listener, independent of settings and display/window rebuilds.
/// Cancellation removes the package's stream handler; queued events from an
/// older registration cannot act on a newly started controller.
@MainActor
final class NotchShortcutController {
    private var task: Task<Void, Never>?
    private var generation = 0
    private let events: @MainActor () -> AsyncStream<KeyboardShortcuts.EventType>
    private let canToggle: @MainActor () -> Bool
    private let toggle: @MainActor () -> Void

    init(
        events: @escaping @MainActor () -> AsyncStream<KeyboardShortcuts.EventType> = {
            KeyboardShortcuts.events(for: .toggleNotch)
        },
        canToggle: @escaping @MainActor () -> Bool,
        toggle: @escaping @MainActor () -> Void
    ) {
        self.events = events
        self.canToggle = canToggle
        self.toggle = toggle
    }

    func start() {
        guard task == nil else { return }
        generation += 1
        let currentGeneration = generation
        let stream = events()
        task = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled,
                      let self, self.generation == currentGeneration else { return }
                // Key-up toggles once, not repeatedly while a key is held.
                guard event == .keyUp, self.canToggle() else { continue }
                self.toggle()
            }
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
