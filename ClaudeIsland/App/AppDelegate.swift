// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private weak var trackedSettingsWindow: NSWindow?

    static var shared: AppDelegate?
    let updater: SPUUpdater
    private let userDriver: NotchUserDriver

    var windowController: NotchWindowController? {
        windowManager?.windowController
    }

    override init() {
        userDriver = NotchUserDriver()
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        AppDelegate.shared = self

        do {
            try updater.start()
        } catch {
            print("Failed to start Sparkle updater: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        HookInstaller.installIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenObserver = nil
        removeSettingsWindowObservers()
        trackedSettingsWindow = nil
    }

    /// Switch to a regular app while Studio is open so its window is represented
    /// in the Dock. Returns `true` when SwiftUI still needs to create the window.
    func prepareForSettingsPresentation() -> Bool {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard let window = settingsWindow else {
            return true
        }

        trackSettingsWindow(window)
        window.makeKeyAndOrderFront(nil)
        return false
    }

    /// Called after SwiftUI receives `openSettings()`. The retry covers the short
    /// interval between Scene creation and the NSWindow entering `NSApp.windows`.
    func settingsPresentationRequested(attempt: Int = 0) {
        if let window = settingsWindow {
            trackSettingsWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard attempt < 20 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.settingsPresentationRequested(attempt: attempt + 1)
        }
    }

    /// The settings root view calls this once its window content is on screen.
    func settingsWindowDidAppear() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsPresentationRequested()
    }

    private var settingsWindow: NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
        }
    }

    private func trackSettingsWindow(_ window: NSWindow) {
        guard trackedSettingsWindow !== window else { return }

        removeSettingsWindowObservers()
        trackedSettingsWindow = window

        for notificationName in [
            NSWindow.willCloseNotification,
            NSWindow.didResignKeyNotification
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(settingsWindowVisibilityChanged(_:)),
                name: notificationName,
                object: window
            )
        }
    }

    @objc
    private func settingsWindowVisibilityChanged(_ notification: Notification) {
        settingsWindowMayHaveHidden(notification.object as? NSWindow)
    }

    private func settingsWindowMayHaveHidden(_ window: NSWindow?) {
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            guard window == nil || self.trackedSettingsWindow === window else {
                return
            }
            guard window?.isVisible != true else { return }

            self.removeSettingsWindowObservers()
            self.trackedSettingsWindow = nil
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func removeSettingsWindowObservers() {
        for notificationName in [
            NSWindow.willCloseNotification,
            NSWindow.didResignKeyNotification
        ] {
            NotificationCenter.default.removeObserver(
                self,
                name: notificationName,
                object: trackedSettingsWindow
            )
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.lihao505.AgentNotch"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }

    static var hasConfiguredUpdateSigningKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !key.isEmpty && key != "AGENT_NOTCH_SPARKLE_PUBLIC_KEY_NOT_CONFIGURED"
    }
}
