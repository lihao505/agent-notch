// Modified by lihao505 for Agent Notch, 2026.
import AppKit
import QuartzCore
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private static let onboardingCompletedKey =
        "agentNotchOnboardingCompleted.v1"

    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private var onboardingWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var settingsPresentationTask: Task<Void, Never>?
    private weak var trackedSettingsWindow: NSWindow?
    private var terminationRequested = false

    private static var isRunningUnitTests: Bool {
        Foundation.ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] != nil
    }

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
        // A hosted XCTest process uses the app executable as its bundle loader.
        // Do not start windows, hooks, or single-instance arbitration there;
        // otherwise an installed Agent Notch makes the test host exit before
        // XCTest establishes its control connection.
        if Self.isRunningUnitTests {
            return
        }
        if !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        // Never infer consent from files that an older build may have written.
        // Self-healing is allowed only after an explicit onboarding/settings
        // opt-in, which is persisted independently from onboarding completion.
        if UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey),
           HookInstaller.integrationsOptedIn {
            Task.detached(priority: .utility) {
                HookInstaller.installIfNeeded()
            }
        }
        NSApplication.shared.setActivationPolicy(.accessory)

        windowManager = WindowManager()
        _ = windowManager?.setupNotchWindow()

        screenObserver = ScreenObserver { [weak self] in
            self?.handleScreenChange()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showOnboardingIfNeeded()
        }
    }

    private func handleScreenChange() {
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A clean shutdown must make the app immediately indistinguishable
        // from an offline bridge. Leaving the Unix socket behind made a real
        // quit look ineffective and forced the next launch to recover stale
        // state before it could accept hooks.
        HookSocketServer.shared.stop()
        screenObserver = nil
        settingsPresentationTask?.cancel()
        settingsPresentationTask = nil
        removeOnboardingWindowObserver()
        removeSettingsWindowObservers()
        trackedSettingsWindow = nil
    }

    /// Close every Agent Notch surface and terminate the process. Keeping this
    /// in AppDelegate gives the in-notch button one explicit, testable exit
    /// path instead of relying on the source SwiftUI hierarchy to survive the
    /// same click that dismisses the panel.
    func quitCompletely() {
        guard !terminationRequested else { return }
        terminationRequested = true

        settingsPresentationTask?.cancel()
        settingsPresentationTask = nil
        onboardingWindowController?.window?.orderOut(nil)
        settingsWindowController?.window?.orderOut(nil)
        windowController?.window?.orderOut(nil)
        HookSocketServer.shared.stop()
        NSApplication.shared.terminate(nil)
    }

    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(
            forKey: Self.onboardingCompletedKey
        ) else {
            return
        }
        showOnboarding()
    }

    func showOnboarding() {
        if let window = onboardingWindowController?.window {
            presentOnboardingWindow(window)
            return
        }

        let contentController = NSHostingController(
            rootView: OnboardingView { [weak self] enableIntegrations in
                self?.finishOnboarding(enableIntegrations: enableIntegrations)
            }
        )
        let window = NSWindow(contentViewController: contentController)
        window.identifier = NSUserInterfaceItemIdentifier(
            "agent_notch_onboarding_window"
        )
        window.title = NotchPreferences.shared.language.text(
            "Welcome to Agent Notch",
            "欢迎使用 Agent Notch"
        )
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 720, height: 480))
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onboardingWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        let controller = NSWindowController(window: window)
        onboardingWindowController = controller
        presentOnboardingWindow(window)

        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, let window, window.isVisible else { return }
            self.presentOnboardingWindow(window)
        }
    }

    private func presentOnboardingWindow(_ window: NSWindow) {
        NSApplication.shared.setActivationPolicy(.regular)
        window.collectionBehavior.insert(.moveToActiveSpace)
        onboardingWindowController?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
    }

    private func finishOnboarding(enableIntegrations: Bool) {
        UserDefaults.standard.set(
            true,
            forKey: Self.onboardingCompletedKey
        )
        HookInstaller.setIntegrationsOptIn(enableIntegrations)
        if enableIntegrations {
            Task.detached(priority: .userInitiated) {
                HookInstaller.installIfNeeded()
            }
        }
        onboardingWindowController?.window?.close()
    }

    @objc
    private func onboardingWindowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(
            true,
            forKey: Self.onboardingCompletedKey
        )
        removeOnboardingWindowObserver()
        onboardingWindowController = nil

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            if self.settingsWindow?.isVisible != true {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }

    private func removeOnboardingWindowObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: onboardingWindowController?.window
        )
    }

    /// Opens Studio from the non-activating notch panel without depending on
    /// SwiftUI's environment-based `openSettings`, which can be dropped when
    /// the source panel disappears during the same event cycle.
    func showDetailedSettings() {
        settingsPresentationTask?.cancel()
        settingsPresentationTask = nil
        presentDetailedSettingsNow()
    }

    /// Coordinates the compact panel's close animation with Studio's
    /// presentation. AppDelegate owns the delayed task so it survives the
    /// source SwiftUI hierarchy disappearing and repeated requests cannot
    /// leave stale presentations queued.
    func showDetailedSettings(afterCollapsing viewModel: NotchViewModel) {
        viewModel.notchClose()

        settingsPresentationTask?.cancel()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            settingsPresentationTask = nil
            presentDetailedSettingsNow()
            return
        }

        settingsPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self else { return }

            self.settingsPresentationTask = nil
            self.presentDetailedSettingsNow()
        }
    }

    private func presentDetailedSettingsNow() {
        let window = settingsWindow ?? makeSettingsWindow()
        presentSettingsWindow(
            window,
            animated: !window.isVisible
        )

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
        settingsWindowController?.window
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
        window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        return window
    }

    private func presentSettingsWindow(
        _ window: NSWindow,
        animated: Bool = false
    ) {
        let shouldAnimate =
            animated &&
            !window.isVisible &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let finalFrame = window.frame

        if shouldAnimate {
            var initialFrame = finalFrame.insetBy(dx: 14, dy: 10)
            initialFrame.origin.y += 8
            window.setFrame(initialFrame, display: false)
            window.alphaValue = 0
        } else if !window.isVisible {
            window.alphaValue = 1
        }

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

        guard shouldAnimate else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(
                name: .easeOut
            )
            context.allowsImplicitAnimation = true

            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        } completionHandler: { [weak window] in
            guard let window else { return }
            window.alphaValue = 1
            window.setFrame(finalFrame, display: true)
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
