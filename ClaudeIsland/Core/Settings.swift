//
//  Modified by lihao505 for Agent Notch, 2026.
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Combine
import CoreGraphics
import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }
}

enum IdleNotchBehavior: String, CaseIterable, Identifiable {
    case alwaysVisible
    case smartHide

    var id: String { rawValue }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case simplifiedChinese

    var id: String { rawValue }

    func text(_ english: String, _ simplifiedChinese: String) -> String {
        self == .simplifiedChinese ? simplifiedChinese : english
    }
}

enum CompactNotchStyle: String, CaseIterable, Identifiable {
    case simple
    case detailed

    var id: String { rawValue }
}

/// Controls how normal tool PermissionRequest events are handled. Interactive
/// questions and plan reviews deliberately remain manual: they require input,
/// not merely an allow/deny decision.
enum ApprovalMode: String, CaseIterable, Identifiable {
    case ask
    case auto
    case trusted

    var id: String { rawValue }
}

/// Shared compact-notch geometry used by the live notch, hover hit testing,
/// and the settings preview. Both wings stay exactly the same width; the
/// compact left composition is tightened to fit the pet and companion signal.
enum CompactNotchMetrics {
    /// Compact mode stays close to the physical notch. Opened mode uses its
    /// own larger animation metrics so shrinking this does not reduce detail
    /// in the full panel.
    static let compactAnimationSize: CGFloat = 13
    static let openedAnimationSize: CGFloat = 27
    static let openedSignalSize: CGFloat = 19

    /// A compact sprite renders inside this larger canvas so its glow and every
    /// animation frame stay away from the notch's rounded clipping boundary.
    static let animationCanvasSize: CGFloat = 18
    static let compactPetCanvasSize: CGFloat = 16
    static let compactSignalSize: CGFloat = 9
    static let openedAnimationCanvasSize: CGFloat = 33
    static let simpleWingWidth: CGFloat = 32
    static let detailedWingWidth: CGFloat = 47
    static let baseConfiguredWidth = 96.0
    static let maximumConfiguredWidth = 176.0
    static let maximumAnimationScale: CGFloat = 1.35

    static func wingWidth(for style: CompactNotchStyle) -> CGFloat {
        style == .detailed
            ? detailedWingWidth
            : simpleWingWidth
    }

    static func wingWidth(
        for style: CompactNotchStyle,
        configuredWidth: Double
    ) -> CGFloat {
        wingWidth(for: style) + userExtraWidth(for: configuredWidth) / 2
    }

    static func animationScale(for configuredWidth: Double) -> CGFloat {
        let range = maximumConfiguredWidth - baseConfiguredWidth
        let progress = min(
            1,
            max(0, (configuredWidth - baseConfiguredWidth) / range)
        )
        return 1 + CGFloat(progress) * (maximumAnimationScale - 1)
    }

    static func userExtraWidth(for configuredWidth: Double) -> CGFloat {
        max(0, CGFloat(configuredWidth - baseConfiguredWidth))
    }

    static func visibleExtension(
        style: CompactNotchStyle,
        configuredWidth: Double
    ) -> CGFloat {
        2 * wingWidth(
            for: style,
            configuredWidth: configuredWidth
        )
    }
}

/// Live preferences shared by the notch and the standalone settings window.
///
/// Keeping these values in one observable object makes settings changes visible
/// immediately without restarting either the app or an active agent session.
@MainActor
final class NotchPreferences: ObservableObject {
    static let shared = NotchPreferences()

    private enum Keys {
        static let idleBehavior = "notchIdleBehavior"
        static let expandOnHover = "notchExpandOnHover"
        static let hoverDelay = "notchHoverDelay"
        static let collapseOnMouseLeave = "notchCollapseOnMouseLeave"
        static let collapseDelay = "notchCollapseDelay"
        static let completionCompactDuration = "notchCompletionCompactDuration"
        static let panelWidth = "notchPanelWidth"
        static let panelHeight = "notchPanelHeight"
        static let showUsageLimits = "notchShowUsageLimits"
        static let language = "notchLanguage"
        static let compactStyle = "notchCompactStyle"
        static let compactWidth = "notchCompactWidth"
        static let approvalMode = "notchApprovalMode"
        static let sessionApprovalModes = "notchSessionApprovalModes"
    }

    private let defaults: UserDefaults

    @Published var idleBehavior: IdleNotchBehavior {
        didSet { defaults.set(idleBehavior.rawValue, forKey: Keys.idleBehavior) }
    }

    @Published var expandOnHover: Bool {
        didSet { defaults.set(expandOnHover, forKey: Keys.expandOnHover) }
    }

    @Published var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Keys.hoverDelay) }
    }

    @Published var collapseOnMouseLeave: Bool {
        didSet { defaults.set(collapseOnMouseLeave, forKey: Keys.collapseOnMouseLeave) }
    }

    /// Time the pointer must remain outside the expanded panel before it
    /// returns to the compact notch. This must not share `hoverDelay`: the
    /// two interactions have different intent and need independently visible
    /// controls in Notch Studio.
    @Published var collapseDelay: Double {
        didSet { defaults.set(collapseDelay, forKey: Keys.collapseDelay) }
    }

    @Published var completionCompactDuration: Double {
        didSet {
            defaults.set(
                completionCompactDuration,
                forKey: Keys.completionCompactDuration
            )
        }
    }

    @Published var panelWidth: Double {
        didSet { defaults.set(panelWidth, forKey: Keys.panelWidth) }
    }

    @Published var panelHeight: Double {
        didSet { defaults.set(panelHeight, forKey: Keys.panelHeight) }
    }

    @Published var showUsageLimits: Bool {
        didSet { defaults.set(showUsageLimits, forKey: Keys.showUsageLimits) }
    }

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var compactStyle: CompactNotchStyle {
        didSet { defaults.set(compactStyle.rawValue, forKey: Keys.compactStyle) }
    }

    /// `.auto` is intentionally ephemeral: on the next app launch it becomes
    /// `.ask`. Only an explicit `.trusted` choice is persisted across launches.
    @Published var approvalMode: ApprovalMode {
        didSet {
            if approvalMode == .trusted {
                defaults.set(approvalMode.rawValue, forKey: Keys.approvalMode)
            } else {
                defaults.removeObject(forKey: Keys.approvalMode)
            }
            writeApprovalPolicy()
        }
    }

    /// Per-conversation overrides. New conversations inherit `approvalMode`;
    /// choosing a mode in a chat stores an override for that session only.
    @Published private(set) var sessionApprovalModes: [String: ApprovalMode]

    /// Width added around the physical camera housing while compact.
    /// Keeping this independent from the hardware notch width makes every
    /// slider step produce the same visible result on different Mac models.
    static let compactWidthRange =
        CompactNotchMetrics.baseConfiguredWidth...CompactNotchMetrics.maximumConfiguredWidth
    static let defaultCompactWidth =
        CompactNotchMetrics.baseConfiguredWidth

    @Published var compactWidth: Double {
        didSet {
            let clamped = min(
                max(compactWidth, Self.compactWidthRange.lowerBound),
                Self.compactWidthRange.upperBound
            )
            if compactWidth != clamped {
                compactWidth = clamped
                return
            }
            defaults.set(compactWidth, forKey: Keys.compactWidth)
        }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        idleBehavior = IdleNotchBehavior(
            rawValue: defaults.string(forKey: Keys.idleBehavior) ?? ""
        ) ?? .alwaysVisible
        expandOnHover = defaults.object(forKey: Keys.expandOnHover) as? Bool ?? true
        hoverDelay = defaults.object(forKey: Keys.hoverDelay) as? Double ?? 0.15
        collapseOnMouseLeave =
            defaults.object(forKey: Keys.collapseOnMouseLeave) as? Bool ?? true
        collapseDelay = defaults.object(forKey: Keys.collapseDelay) as? Double ?? 0.85
        completionCompactDuration =
            defaults.object(forKey: Keys.completionCompactDuration) as? Double ?? 8
        panelWidth = defaults.object(forKey: Keys.panelWidth) as? Double ?? 640
        panelHeight = defaults.object(forKey: Keys.panelHeight) as? Double ?? 560
        showUsageLimits =
            defaults.object(forKey: Keys.showUsageLimits) as? Bool ?? true
        language = AppLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? .english
        compactStyle = CompactNotchStyle(
            rawValue: defaults.string(forKey: Keys.compactStyle) ?? ""
        ) ?? .simple
        approvalMode = defaults.string(forKey: Keys.approvalMode) == ApprovalMode.trusted.rawValue
            ? .trusted
            : .ask
        let storedSessionModes =
            defaults.dictionary(forKey: Keys.sessionApprovalModes) as? [String: String]
            ?? [:]
        sessionApprovalModes = storedSessionModes.reduce(into: [:]) { result, entry in
            guard let mode = ApprovalMode(rawValue: entry.value),
                  mode != .auto else {
                return
            }
            result[entry.key] = mode
        }
        let storedCompactWidth =
            defaults.object(forKey: Keys.compactWidth) as? Double
            ?? Self.defaultCompactWidth
        compactWidth = Self.compactWidthRange.contains(storedCompactWidth)
            ? storedCompactWidth
            : Self.defaultCompactWidth
        writeApprovalPolicy()
    }

    func resetPanelSize() {
        panelWidth = 640
        panelHeight = 560
    }

    func resetCompactWidth() {
        compactWidth = Self.defaultCompactWidth
    }

    func approvalMode(for sessionId: String) -> ApprovalMode {
        sessionApprovalModes[sessionId] ?? approvalMode
    }

    func hasApprovalOverride(for sessionId: String) -> Bool {
        sessionApprovalModes[sessionId] != nil
    }

    func setApprovalMode(_ mode: ApprovalMode, for sessionId: String) {
        guard !sessionId.isEmpty else { return }
        sessionApprovalModes[sessionId] = mode
        persistSessionApprovalModes()
        writeApprovalPolicy()
    }

    func clearApprovalMode(for sessionId: String) {
        guard sessionApprovalModes.removeValue(forKey: sessionId) != nil else {
            return
        }
        persistSessionApprovalModes()
        writeApprovalPolicy()
    }

    /// Auto approval is intentionally limited to the current app run. Explicit
    /// Ask and Trusted overrides persist so a trusted global default can still
    /// be safely disabled for one sensitive conversation.
    private func persistSessionApprovalModes() {
        let persistentModes = sessionApprovalModes.reduce(into: [String: String]()) {
            result, entry in
            guard entry.value != .auto else { return }
            result[entry.key] = entry.value.rawValue
        }
        defaults.set(persistentModes, forKey: Keys.sessionApprovalModes)
    }

    /// The bridge is a short-lived Python process, so UserDefaults alone is
    /// not visible to it. Keep a tiny, atomic policy file as the shared source
    /// of truth. It contains no credentials and is recreated at app startup.
    private func writeApprovalPolicy() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".multiagent-notch/approval-policy.json")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "mode": approvalMode.rawValue,
                    "sessions": sessionApprovalModes.mapValues(\.rawValue)
                ],
                options: [.sortedKeys]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to write approval policy: \(error)")
        }
    }
}
