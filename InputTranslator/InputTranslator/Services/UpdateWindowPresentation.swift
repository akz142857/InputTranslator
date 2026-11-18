import AppKit
import Sparkle

/// Keep Sparkle's UI above our floating panels without changing the user's Pin preference.
@MainActor
final class UpdateWindowPresentation: NSObject, SPUStandardUserDriverDelegate {
    struct Environment {
        var notifications: NotificationCenter = .default
        var windows: () -> [NSWindow] = { NSApp.windows }
        var applicationIsActive: () -> Bool = { NSApp.isActive }
        var pinnedPanelIsVisible: () -> Bool = {
            NSApp.windows.contains { window in
                window is FloatingPanel && window.isVisible && !window.hidesOnDeactivate
            }
        }
        var modalWindow: () -> NSWindow? = { NSApp.modalWindow }
        var isUpdateWindow: (NSWindow) -> Bool = { window in
            guard let controller = window.windowController else { return false }
            return Bundle(for: type(of: controller)).bundleURL == Bundle(for: SPUStandardUserDriver.self).bundleURL
        }
    }

    private struct SavedWindow {
        weak var window: NSWindow?
        let level: NSWindow.Level
    }

    private let environment: Environment
    private var savedWindows: [ObjectIdentifier: SavedWindow] = [:]
    private var sessionActive = false
    private var modalAlerts = 0

    init(environment: Environment? = nil) {
        self.environment = environment ?? Environment()
        super.init()
        let center = self.environment.notifications
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowVisibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationResignedActive), name: NSApplication.didResignActiveNotification, object: nil)
    }

    deinit { environment.notifications.removeObserver(self) }

    func beginSession() {
        sessionActive = true
    }

    func refresh() {
        guard sessionActive || modalAlerts > 0 else { return }
        guard environment.applicationIsActive() || environment.pinnedPanelIsVisible() else {
            restoreLevels()
            return
        }
        savedWindows = savedWindows.filter { $0.value.window != nil }
        for window in environment.windows() where window.isVisible && environment.isUpdateWindow(window) {
            elevate(window)
        }
        if modalAlerts > 0, let window = environment.modalWindow() {
            elevate(window)
        }
    }

    private func elevate(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if savedWindows[id] == nil { savedWindows[id] = SavedWindow(window: window, level: window.level) }
        let minimum = NSWindow.Level.floating.rawValue + 1
        let level = NSWindow.Level(rawValue: max(savedWindows[id]?.level.rawValue ?? window.level.rawValue, minimum))
        if window.level != level { window.level = level }
    }

    private func restoreLevels() {
        for saved in savedWindows.values where saved.window?.level != saved.level { saved.window?.level = saved.level }
    }

    func finishSession() {
        sessionActive = false
        restoreLevels()
        savedWindows.removeAll()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        refresh()
    }

    @objc private func applicationBecameActive() { refresh() }
    @objc private func applicationResignedActive() { refresh() }
    @objc private func windowVisibilityChanged() { refresh() }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                  forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        beginSession()
        refresh()
    }

    func standardUserDriverWillShowModalAlert() {
        modalAlerts += 1
        // runModal establishes NSApp.modalWindow after the delegate is called.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func standardUserDriverDidShowModalAlert() {
        modalAlerts = max(0, modalAlerts - 1)
        if !sessionActive && modalAlerts == 0 { finishSession() }
    }

    func standardUserDriverWillFinishUpdateSession() { finishSession() }
}
