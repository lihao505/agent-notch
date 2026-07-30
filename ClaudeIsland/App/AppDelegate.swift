// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var settingsWindowController: NSWindowController?
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

    /// Opens Studio from the non-activating notch panel without depending on
    /// SwiftUI's environment-based `openSettings`, which can be dropped when
    /// the source panel disappears during the same event cycle.
    func showDetailedSettings() {
        let window = settingsWindow ?? makeSettingsWindow()
        presentSettingsWindow(window)

        // Reassert frontmost status after the notch finishes its close
        // animation and after macOS completes the activation-policy change.
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, let window, window.isVisible else { return }
            self.presentSettingsWindow(window)
        }
    }

    /// The settings root view calls this once its window content is on screen.
    func settingsWindowDidAppear() {
        guard let window = settingsWindow else { return }
        presentSettingsWindow(window)
    }

    private var settingsWindow: NSWindow? {
        if let window = settingsWindowController?.window {
            return window
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
        }
    }

    private func makeSettingsWindow() -> NSWindow {
        let contentController = NSHostingController(
            rootView: NotchStudioSettingsView()
        )
        let window = NSWindow(contentViewController: contentController)
        window.identifier = NSUserInterfaceItemIdentifier(
            "com_apple_SwiftUI_Settings_window"
        )
        window.title = "Agent Notch Settings"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 780, height: 560)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        return window
    }

    private func presentSettingsWindow(_ window: NSWindow) {
        NSApplication.shared.setActivationPolicy(.regular)
        window.level = .normal
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.deminiaturize(nil)

        settingsWindowController?.showWindow(nil)
        trackSettingsWindow(window)

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
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
