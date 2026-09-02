//
//  Modified by lihao505 for Agent Notch, 2026.
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Darwin
import Foundation

/// Synchronous installer work is intentionally nonisolated. Every mutating
/// entry point is serialized by `operationLock`, and UI call sites dispatch the
/// potentially slow filesystem and Process work through `Task.detached`.
/// Keeping this type outside the app's default MainActor isolation prevents an
/// accidental actor hop back to the UI thread from those background tasks.
nonisolated struct HookInstaller {
    private static let bridgeInstallFingerprintKey = "agentBridgeInstallFingerprint"
    private static let integrationsOptInKey = "agentNotchIntegrationsOptIn.v1"
    private static let lastInstallSucceededKey = "agentNotchLastInstallSucceeded.v1"
    nonisolated private static let operationLock = NSLock()
    /// Increment whenever installer ownership/coexistence semantics change,
    /// so an app update with the same marketing/build version still repairs
    /// an already-installed bridge configuration on next launch.
    private static let bridgeInstallRevision = "ordered-lifecycle-events-v6"

    /// Configuration mutation is allowed only after an explicit onboarding or
    /// settings action. The absence of this key intentionally means `false` for
    /// upgrades from builds that installed hooks automatically.
    static var integrationsOptedIn: Bool {
        UserDefaults.standard.bool(forKey: integrationsOptInKey)
    }

    /// `true` means consent exists but the last complete installation did not.
    /// A conflict is intentionally reported as repair-needed instead of being
    /// presented as a connected bridge.
    static var integrationsNeedRepair: Bool {
        integrationsOptedIn &&
            !UserDefaults.standard.bool(forKey: lastInstallSucceededKey)
    }

    static func setIntegrationsOptIn(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: integrationsOptInKey)
    }

    /// Install hook script and update settings.json on app launch
    @discardableResult
    static func installIfNeeded() -> Bool {
        guard integrationsOptedIn else { return false }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard integrationsOptedIn else { return false }

        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent(ClaudePaths.hookScriptFileName)
        let legacyScript = hooksDir.appendingPathComponent(ClaudePaths.legacyHookScriptFileName)

        do {
            try FileManager.default.createDirectory(
                at: hooksDir,
                withIntermediateDirectories: true
            )
            guard let bundled = Bundle.main.url(
                forResource: "claude-island-state",
                withExtension: "py"
            ) else {
                print("Agent Notch hook install skipped: bundled hook is missing")
                UserDefaults.standard.set(false, forKey: lastInstallSucceededKey)
                return false
            }
            let hookData = try Data(contentsOf: bundled)
            try hookData.write(to: pythonScript, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        } catch {
            print("Agent Notch hook install failed: \(error.localizedDescription)")
            UserDefaults.standard.set(false, forKey: lastInstallSucceededKey)
            return false
        }

        try? FileManager.default.removeItem(at: legacyScript)

        guard updateSettings(at: ClaudePaths.settingsFile) else {
            UserDefaults.standard.set(false, forKey: lastInstallSucceededKey)
            return false
        }
        let succeeded = installBundledBridgeIfNeeded()
        UserDefaults.standard.set(succeeded, forKey: lastInstallSucceededKey)
        return succeeded
    }

    /// Returns false instead of replacing an unreadable existing file. A
    /// malformed agent configuration is user-owned data and must be repaired
    /// explicitly; silently treating it as `{}` would erase unrelated hooks.
    @discardableResult
    private static func updateSettings(at settingsURL: URL) -> Bool {
        guard var json = loadSettingsSafely(at: settingsURL) else {
            print("Agent Notch left unreadable settings untouched: \(settingsURL.path)")
            return false
        }

        let python = detectPython()
        let command = "\(python) \(ClaudePaths.hookScriptShellPath)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 105]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let managedPaths = managedHookScriptPaths()

        // Strip any existing Claude Island hooks from ALL event types first — even
        // events we no longer register. Fixes users who installed v1.3 on an older
        // Claude Code and now have invalid keys like PermissionDenied sitting in
        // their settings.json (issue #85).
        var cleanedHooks: [String: Any] = [:]
        for (event, value) in hooks {
            if let entries = value as? [[String: Any]] {
                let cleaned = entries.compactMap {
                    removingAgentNotchHooks(from: $0, managedPaths: managedPaths)
                }
                if !cleaned.isEmpty {
                    cleanedHooks[event] = cleaned
                }
            } else {
                cleanedHooks[event] = value
            }
        }
        hooks = cleanedHooks

        // Register only hooks the installed Claude Code version supports.
        // When detection fails, fall back to the baseline set that every
        // Claude Code version has supported (no new v1.3+ hooks).
        let installedVersion = detectClaudeCodeVersion()
        let hookEvents = supportedHookEvents(
            for: installedVersion,
            withMatcher: withMatcher,
            withoutMatcher: withoutMatcher,
            preCompactConfig: preCompactConfig
        )

        for (event, config) in hookEvents {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing + config
        }

        // A permission decision needs exactly one synchronous owner. Migrate
        // only the exact Vibe Island commands we know, keep async observers,
        // and leave every unknown synchronous hook untouched without adding
        // Agent Notch as a second decision owner.
        if let entries = hooks["PermissionRequest"] as? [[String: Any]] {
            let migrated = entries.compactMap {
                removingExactCommands(
                    from: $0,
                    commands: knownVibeIslandClaudePermissionCommands()
                )
            }
            if migrated.isEmpty {
                hooks.removeValue(forKey: "PermissionRequest")
            } else {
                hooks["PermissionRequest"] = migrated
            }
        }

        let permissionEntries = hooks["PermissionRequest"] as? [[String: Any]]
        let malformedPermissionConfiguration =
            hooks["PermissionRequest"] != nil && permissionEntries == nil
        if !malformedPermissionConfiguration,
           !containsSynchronousHook(in: permissionEntries ?? []) {
            hooks["PermissionRequest"] =
                (permissionEntries ?? []) + withMatcherAndTimeout
        } else {
            print(
                "Agent Notch did not take Claude PermissionRequest ownership " +
                "because another synchronous hook is configured."
            )
        }

        json["hooks"] = hooks

        return writeSettingsAtomically(json, to: settingsURL)
    }

    private static func loadSettingsSafely(
        at settingsURL: URL
    ) -> [String: Any]? {
        let resolvedURL = resolvedSettingsURL(settingsURL)
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: resolvedURL)
            guard let json = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                return nil
            }
            return json
        } catch {
            return nil
        }
    }

    @discardableResult
    private static func writeSettingsAtomically(
        _ json: [String: Any],
        to settingsURL: URL
    ) -> Bool {
        let fileManager = FileManager.default
        let resolvedURL = resolvedSettingsURL(settingsURL)
        do {
            try fileManager.createDirectory(
                at: resolvedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fileManager.fileExists(atPath: resolvedURL.path),
               let existing = loadSettingsSafely(at: resolvedURL),
               NSDictionary(dictionary: existing).isEqual(
                   NSDictionary(dictionary: json)
               ) {
                return true
            }

            let existingAttributes = try? fileManager.attributesOfItem(
                atPath: resolvedURL.path
            )
            if fileManager.fileExists(atPath: resolvedURL.path) {
                let backupURL = resolvedURL.appendingPathExtension(
                    "agent-notch.backup"
                )
                if !fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.copyItem(at: resolvedURL, to: backupURL)
                }
            }

            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            let permissions = existingAttributes?[.posixPermissions] ?? 0o600
            let temporaryURL = resolvedURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".agent-notch-\(UUID().uuidString).tmp"
                )
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: permissions]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? fileManager.removeItem(at: temporaryURL) }

            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()

            guard rename(temporaryURL.path, resolvedURL.path) == 0 else {
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: resolvedURL.path
            )
            return true
        } catch {
            print("Agent Notch could not update \(resolvedURL.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Follow a valid or dangling settings symlink and replace its target, not
    /// the link itself. This keeps dotfile-manager layouts intact.
    private static func resolvedSettingsURL(_ settingsURL: URL) -> URL {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: settingsURL.path
        ) else {
            return settingsURL
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = settingsURL.deletingLastPathComponent()
                .appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Claude Code Version Detection

    /// Simple semantic version used to gate which hook events we register.
    /// Claude Code rejects unknown hook keys, so we must only register
    /// events the installed version knows about.
    struct ClaudeCodeVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        static func < (lhs: ClaudeCodeVersion, rhs: ClaudeCodeVersion) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// Runs `claude --version` and parses the result. Returns nil on any
    /// failure (binary not found, non-zero exit, unparseable output).
    static func detectClaudeCodeVersion() -> ClaudeCodeVersion? {
        // Claude Code can land in a few typical spots; try each until we find one
        let fm = FileManager.default
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            "/usr/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return parseClaudeCodeVersion(from: output)
        } catch {
            return nil
        }
    }

    /// Extracts the first `X.Y.Z` token from arbitrary version output.
    /// Accepts any prefix/suffix — works for "2.1.88", "v2.1.88", "claude 2.1.88 (...)" etc.
    static func parseClaudeCodeVersion(from text: String) -> ClaudeCodeVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let patchRange = Range(match.range(at: 3), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]),
              let patch = Int(text[patchRange])
        else { return nil }
        return ClaudeCodeVersion(major: major, minor: minor, patch: patch)
    }

    /// Returns the ordered list of (event, config) pairs to register, filtered
    /// to only events the installed Claude Code version knows about.
    private static func supportedHookEvents(
        for version: ClaudeCodeVersion?,
        withMatcher: [[String: Any]],
        withoutMatcher: [[String: Any]],
        preCompactConfig: [[String: Any]]
    ) -> [(String, [[String: Any]])] {
        // Baseline — present in every Claude Code version that supports hooks
        var events: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        // Without a detected version, stick to the baseline — better to miss
        // features than to break settings.json on older Claude Code (#85).
        guard let version else { return events }

        // v2.0.x — PostToolUseFailure shipped alongside the PostToolUse redesign
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 0) {
            events.append(("PostToolUseFailure", withMatcher))
        }
        // v2.0.43 — SubagentStart, pairs with SubagentStop
        if version >= ClaudeCodeVersion(major: 2, minor: 0, patch: 43) {
            events.append(("SubagentStart", withoutMatcher))
        }
        // v2.1.76 — PostCompact, pairs with PreCompact
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 76) {
            events.append(("PostCompact", preCompactConfig))
        }
        // v2.1.78 — StopFailure on API errors (rate limit, auth, billing)
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 78) {
            events.append(("StopFailure", withoutMatcher))
        }
        // v2.1.88 — PermissionDenied for auto-mode classifier denials
        if version >= ClaudeCodeVersion(major: 2, minor: 1, patch: 88) {
            events.append(("PermissionDenied", withMatcher))
        }

        return events
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let settings = ClaudePaths.settingsFile

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        let managedPaths = managedHookScriptPaths()

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if isAgentNotchHook(hook, managedPaths: managedPaths) {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    @discardableResult
    static func uninstall() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        let hooksDir = ClaudePaths.hooksDir
        let pythonScript = hooksDir.appendingPathComponent(ClaudePaths.hookScriptFileName)
        let legacyScript = hooksDir.appendingPathComponent(ClaudePaths.legacyHookScriptFileName)
        let settings = ClaudePaths.settingsFile

        if FileManager.default.fileExists(atPath: settings.path) {
            guard var json = loadSettingsSafely(at: settings) else {
                print("Agent Notch left unreadable settings untouched: \(settings.path)")
                return false
            }
            if var hooks = json["hooks"] as? [String: Any] {
                let managedPaths = managedHookScriptPaths()

                for (event, value) in hooks {
                    if var entries = value as? [[String: Any]] {
                        entries = entries.compactMap {
                            removingAgentNotchHooks(
                                from: $0,
                                managedPaths: managedPaths
                            )
                        }

                        if entries.isEmpty {
                            hooks.removeValue(forKey: event)
                        } else {
                            hooks[event] = entries
                        }
                    }
                }

                if hooks.isEmpty {
                    json.removeValue(forKey: "hooks")
                } else {
                    json["hooks"] = hooks
                }
            }

            guard writeSettingsAtomically(json, to: settings) else { return false }
        }

        for script in [pythonScript, legacyScript]
            where FileManager.default.fileExists(atPath: script.path) {
            do {
                try FileManager.default.removeItem(at: script)
            } catch {
                print("Agent Notch could not remove \(script.path): \(error)")
                return false
            }
        }
        let bridgeResult = runBundledBridgeScript(named: "uninstall.sh")
        UserDefaults.standard.removeObject(forKey: bridgeInstallFingerprintKey)
        UserDefaults.standard.set(false, forKey: lastInstallSucceededKey)
        return bridgeResult.succeeded
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }

    /// Install or remove the bundled multi-agent adapter with the same Hooks
    /// switch as the native Claude integration. The shell scripts own exact,
    /// backed-up edits for Codex and CodeBuddy and deliberately refuse to take
    /// over a conflicting PermissionRequest decision hook by default.
    private static func installBundledBridgeIfNeeded() -> Bool {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let baseFingerprint = "\(version)-\(build)-\(bridgeInstallRevision)"
        let installedBridge = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".multiagent-notch/bin/notch-bridge.py")
        let currentSignature = bridgeConfigurationSignature()
        let completeFingerprint =
            "\(baseFingerprint)|\(currentSignature)|complete"
        let storedFingerprint = UserDefaults.standard.string(
            forKey: bridgeInstallFingerprintKey
        )

        if storedFingerprint == completeFingerprint,
           FileManager.default.isReadableFile(atPath: installedBridge.path) {
            return true
        }
        let result = runBundledBridgeScript(named: "install.sh")
        guard result.succeeded else {
            UserDefaults.standard.removeObject(forKey: bridgeInstallFingerprintKey)
            if !result.errorOutput.isEmpty {
                print("Agent Notch bridge install failed: \(result.errorOutput)")
            }
            return false
        }

        let status = result.output.contains(
            "AGENT_NOTCH_INSTALL_STATUS=partial"
        ) ? "partial" : "complete"
        let finalFingerprint =
            "\(baseFingerprint)|\(bridgeConfigurationSignature())|\(status)"
        UserDefaults.standard.set(
            finalFingerprint,
            forKey: bridgeInstallFingerprintKey
        )
        return status == "complete"
    }

    private struct BridgeScriptResult {
        let succeeded: Bool
        let output: String
        let errorOutput: String
    }

    private static func runBundledBridgeScript(
        named name: String
    ) -> BridgeScriptResult {
        guard let resources = Bundle.main.resourceURL else {
            return BridgeScriptResult(
                succeeded: false,
                output: "",
                errorOutput: "App resources are unavailable."
            )
        }
        let script = resources
            .appendingPathComponent("AgentBridge", isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            return BridgeScriptResult(
                succeeded: false,
                output: "",
                errorOutput: "Missing bundled script: \(name)"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = Foundation.ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = ClaudePaths.claudeDir.path
        environment["AGENT_NOTCH_CLAUDE_DIR"] = ClaudePaths.claudeDir.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let commonPaths = [
            "\(home)/.local/bin",
            "\(home)/.codex/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        environment["PATH"] = (
            commonPaths + [environment["PATH"] ?? "/usr/bin:/bin"]
        ).joined(separator: ":")
        process.environment = environment

        // Capture to private temporary files instead of pipes. The installer
        // can print conflict details; waiting before draining a full pipe would
        // deadlock the app.
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-notch-installer-\(UUID().uuidString)",
                isDirectory: true
            )
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        do {
            try FileManager.default.createDirectory(
                at: captureDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ), FileManager.default.createFile(
                atPath: errorURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            return BridgeScriptResult(
                succeeded: false,
                output: "",
                errorOutput: error.localizedDescription
            )
        }
        defer { try? FileManager.default.removeItem(at: captureDirectory) }

        do {
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()
            process.waitUntilExit()
            try outputHandle.close()
            try errorHandle.close()
            let output = String(
                data: try Data(contentsOf: outputURL),
                encoding: .utf8
            ) ?? ""
            let errorOutput = String(
                data: try Data(contentsOf: errorURL),
                encoding: .utf8
            ) ?? ""
            return BridgeScriptResult(
                succeeded: process.terminationStatus == 0,
                output: output,
                errorOutput: errorOutput
            )
        } catch {
            // Keep the native Claude hook functional if an optional agent bridge
            // cannot be installed on this machine.
            return BridgeScriptResult(
                succeeded: false,
                output: "",
                errorOutput: error.localizedDescription
            )
        }
    }

    private static func bridgeConfigurationSignature() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            ClaudePaths.settingsFile,
            home.appendingPathComponent(".codex/hooks.json"),
            home.appendingPathComponent(".codebuddy/settings.json"),
        ]
        return paths.map { url in
            let resolved = resolvedSettingsURL(url)
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: resolved.path
            ) else {
                return "\(url.path)=missing"
            }
            let size = attributes[.size] as? NSNumber ?? 0
            let modified = (attributes[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            return "\(url.path)=\(size):\(modified)"
        }.joined(separator: "|")
    }

    private static func managedHookScriptPaths() -> Set<String> {
        let hooksDirectory = ClaudePaths.hooksDir.path
        return Set([
            (hooksDirectory as NSString).appendingPathComponent(ClaudePaths.hookScriptFileName),
            (hooksDirectory as NSString).appendingPathComponent(ClaudePaths.legacyHookScriptFileName),
        ].map { ($0 as NSString).standardizingPath })
    }

    private static func knownVibeIslandClaudePermissionCommands() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            #"/bin/sh -c '[ -x "$HOME/.vibe-island/bin/vibe-island-bridge" ] && "$HOME/.vibe-island/bin/vibe-island-bridge" --source claude; exit 0'"#,
            "'\(home)/.vibe-island/bin/vibe-island-bridge' --source claude",
        ]
    }

    nonisolated private static func removingExactCommands(
        from entry: [String: Any],
        commands: Set<String>
    ) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            // Preserve an unfamiliar schema. The caller treats it as a
            // synchronous conflict rather than trying to normalize it.
            return entry
        }
        entryHooks.removeAll {
            guard let command = $0["command"] as? String else { return false }
            return commands.contains(
                command.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    nonisolated private static func containsSynchronousHook(
        in entries: [[String: Any]]
    ) -> Bool {
        for entry in entries {
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                return true
            }
            for hook in entryHooks where hook["async"] as? Bool != true {
                return true
            }
        }
        return false
    }

    nonisolated private static func removingAgentNotchHooks(
        from entry: [String: Any],
        managedPaths: Set<String>
    ) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll {
            isAgentNotchHook($0, managedPaths: managedPaths)
        }
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    nonisolated private static func isAgentNotchHook(
        _ hook: [String: Any],
        managedPaths: Set<String>
    ) -> Bool {
        guard let rawCommand = hook["command"] as? String else { return false }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = command.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard parts.count == 2 else { return false }

        let interpreter = URL(fileURLWithPath: String(parts[0])).lastPathComponent
        guard interpreter == "python" || interpreter == "python3" else { return false }

        var scriptPath = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if scriptPath.count >= 2,
           let first = scriptPath.first,
           let last = scriptPath.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            scriptPath.removeFirst()
            scriptPath.removeLast()
        }

        let candidate = ((scriptPath as NSString).expandingTildeInPath as NSString)
            .standardizingPath
        return managedPaths.contains(candidate)
    }
}
