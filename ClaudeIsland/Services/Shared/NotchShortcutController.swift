// Modified by lihao505 for Agent Notch, 2026.
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Intentionally unbound: never take over an existing global combination.
    static let toggleNotch = Self("agentNotch.toggleNotch")
    static let previousNotchSession = Self("agentNotch.previousSession")
    static let nextNotchSession = Self("agentNotch.nextSession")
}

enum NotchShortcutAction: String, CaseIterable, Identifiable {
    case toggle, previousSession, nextSession
    var id: String { rawValue }

    var name: KeyboardShortcuts.Name {
        switch self {
        case .toggle: return .toggleNotch
        case .previousSession: return .previousNotchSession
        case .nextSession: return .nextNotchSession
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .toggle: return language.text("Toggle notch", "展开 / 收起刘海")
        case .previousSession: return language.text("Previous session", "上一个会话")
        case .nextSession: return language.text("Next session", "下一个会话")
        }
    }
}

enum NotchShortcutConflictPolicy {
    static func conflictingActions(
        in bindings: [NotchShortcutAction: KeyboardShortcuts.Shortcut]
    ) -> Set<NotchShortcutAction> {
        Set(bindings.keys.filter { action in
            bindings.contains { $0.key != action && $0.value == bindings[action] }
        })
    }

    static func currentConflicts() -> Set<NotchShortcutAction> {
        let bindings = Dictionary(uniqueKeysWithValues: NotchShortcutAction.allCases.compactMap {
            action -> (NotchShortcutAction, KeyboardShortcuts.Shortcut)? in
            guard let shortcut = KeyboardShortcuts.getShortcut(for: action.name) else { return nil }
            return (action, shortcut)
        })
        return conflictingActions(in: bindings)
    }
}

/// One app-owned listener, independent of settings and display/window rebuilds.
/// Cancellation removes the package's stream handler; queued events from an
/// older registration cannot act on a newly started controller.
@MainActor
final class NotchShortcutController {
    private var tasks: [NotchShortcutAction: Task<Void, Never>] = [:]
    private var generation = 0
    private let actions: [NotchShortcutAction]
    private let events: @MainActor (NotchShortcutAction) -> AsyncStream<KeyboardShortcuts.EventType>
    private let canPerform: @MainActor (NotchShortcutAction) -> Bool
    private let perform: @MainActor (NotchShortcutAction) -> Void

    init(
        actions: [NotchShortcutAction] = NotchShortcutAction.allCases,
        events: @escaping @MainActor (NotchShortcutAction) -> AsyncStream<KeyboardShortcuts.EventType> = {
            KeyboardShortcuts.events(for: $0.name)
        },
        canPerform: @escaping @MainActor (NotchShortcutAction) -> Bool,
        perform: @escaping @MainActor (NotchShortcutAction) -> Void
    ) {
        self.actions = actions
        self.events = events
        self.canPerform = canPerform
        self.perform = perform
    }

    func start() {
        guard tasks.isEmpty else { return }
        generation += 1
        let currentGeneration = generation
        for action in actions where tasks[action] == nil {
            let stream = events(action)
            tasks[action] = Task { @MainActor [weak self] in
                for await event in stream {
                    guard !Task.isCancelled,
                          let self, self.generation == currentGeneration else { return }
                    // Key-up acts once, not repeatedly while a key is held.
                    guard event == .keyUp, self.canPerform(action) else { continue }
                    self.perform(action)
                }
            }
        }
    }

    func stop() {
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    deinit { tasks.values.forEach { $0.cancel() } }
}
