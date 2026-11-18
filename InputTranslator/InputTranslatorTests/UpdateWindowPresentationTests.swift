import AppKit
import Sparkle
import XCTest
@testable import InputTranslator

final class UpdateWindowPresentationTests: XCTestCase {
    @MainActor private func window(level: NSWindow.Level = .normal) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 120),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = level
        window.orderFront(nil)
        return window
    }

    @MainActor func testOnlyUpdateWindowsRiseAbovePinnedPanelAndRestoreTheirOriginalLevel() {
        let panel = window(level: .floating)
        let update = window()
        let settings = window()
        defer { panel.close(); update.close(); settings.close() }
        var environment = UpdateWindowPresentation.Environment()
        environment.notifications = NotificationCenter()
        environment.windows = { [panel, update, settings] }
        environment.applicationIsActive = { true }
        environment.isUpdateWindow = { $0 === update }
        let presentation = UpdateWindowPresentation(environment: environment)
        presentation.beginSession()
        presentation.refresh()
        presentation.refresh()
        XCTAssertGreaterThan(update.level.rawValue, panel.level.rawValue)
        XCTAssertEqual(settings.level, .normal)
        XCTAssertEqual(panel.level, .floating)
        presentation.finishSession()
        XCTAssertEqual(update.level, .normal)
        XCTAssertEqual(panel.level, .floating)
    }

    @MainActor func testBackgroundSwitchRestoresLevelsAndReturningRaisesUpdateAgain() {
        let update = window()
        defer { update.close() }
        let center = NotificationCenter()
        var active = false
        var environment = UpdateWindowPresentation.Environment()
        environment.notifications = center
        environment.windows = { [update] }
        environment.applicationIsActive = { active }
        environment.pinnedPanelIsVisible = { false }
        environment.isUpdateWindow = { $0 === update }
        let presentation = UpdateWindowPresentation(environment: environment)
        presentation.beginSession()
        presentation.refresh()
        XCTAssertEqual(update.level, .normal)
        active = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertGreaterThan(update.level.rawValue, NSWindow.Level.floating.rawValue)
        active = false
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(update.level, .normal)
        active = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertGreaterThan(update.level.rawValue, NSWindow.Level.floating.rawValue)
        presentation.finishSession()
        center.post(name: NSWindow.didBecomeKeyNotification, object: update)
        XCTAssertEqual(update.level, .normal)
    }

    @MainActor func testVisiblePinnedPanelKeepsUpdateVisibleWhileAnotherAppIsActive() {
        let update = window()
        defer { update.close() }
        let center = NotificationCenter()
        var pinnedPanelVisible = true
        var environment = UpdateWindowPresentation.Environment()
        environment.notifications = center
        environment.windows = { [update] }
        environment.applicationIsActive = { false }
        environment.pinnedPanelIsVisible = { pinnedPanelVisible }
        environment.isUpdateWindow = { $0 === update }
        let presentation = UpdateWindowPresentation(environment: environment)
        presentation.beginSession()
        presentation.refresh()
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertGreaterThan(update.level.rawValue, NSWindow.Level.floating.rawValue)
        pinnedPanelVisible = false
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: update)
        XCTAssertEqual(update.level, .normal)
        presentation.finishSession()
    }

    @MainActor func testModalAlertOutsideUpdateSessionRestoresItsLevel() {
        let alert = window()
        defer { alert.close() }
        var environment = UpdateWindowPresentation.Environment()
        environment.notifications = NotificationCenter()
        environment.windows = { [] }
        environment.applicationIsActive = { true }
        environment.modalWindow = { alert }
        let presentation = UpdateWindowPresentation(environment: environment)
        XCTAssertTrue(presentation.responds(to: #selector(SPUStandardUserDriverDelegate.standardUserDriverWillShowModalAlert)))
        XCTAssertTrue(presentation.responds(to: #selector(SPUStandardUserDriverDelegate.standardUserDriverDidShowModalAlert)))
        XCTAssertTrue(presentation.responds(to: #selector(SPUStandardUserDriverDelegate.standardUserDriverWillFinishUpdateSession)))
        presentation.standardUserDriverWillShowModalAlert()
        presentation.refresh()
        XCTAssertGreaterThan(alert.level.rawValue, NSWindow.Level.floating.rawValue)
        presentation.standardUserDriverDidShowModalAlert()
        XCTAssertEqual(alert.level, .normal)
    }

    @MainActor func testSparkleCheckAndDownloadWindowsStayAbovePinnedPanel() throws {
        let suite = "UpdateWindowPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.panelPinned = true
        settings.topDockEnabled = false
        let controller = InputController(settings: settings)
        let panel = FloatingPanel(controller: controller)
        panel.setFrame(NSRect(x: 120, y: 120, width: 600, height: 400), display: false)
        panel.orderFront(nil)
        let originalFrame = panel.frame
        defer { panel.close() }

        var environment = UpdateWindowPresentation.Environment()
        environment.notifications = NotificationCenter()
        environment.applicationIsActive = { true }
        let presentation = UpdateWindowPresentation(environment: environment)
        let driver = UpdateUserDriver(hostBundle: Bundle.main, presentation: presentation)
        defer { driver.dismissUpdateInstallation() }
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        var windows = NSApp.windows.filter { $0.isVisible && environment.isUpdateWindow($0) }
        XCTAssertFalse(windows.isEmpty, "The real Sparkle checking window must be visible")
        for window in windows { XCTAssertGreaterThan(window.level.rawValue, panel.level.rawValue) }
        driver.dismissUpdateInstallation()

        driver.showDownloadInitiated(cancellation: {})
        windows = NSApp.windows.filter { $0.isVisible && environment.isUpdateWindow($0) }
        XCTAssertFalse(windows.isEmpty, "The real Sparkle download window must be visible")
        for window in windows { XCTAssertGreaterThan(window.level.rawValue, panel.level.rawValue) }
        driver.dismissUpdateInstallation()
        XCTAssertTrue(settings.panelPinned)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.frame, originalFrame)
        XCTAssertTrue(panel.isVisible)
    }
}
