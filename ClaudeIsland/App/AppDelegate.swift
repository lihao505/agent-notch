// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?

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
