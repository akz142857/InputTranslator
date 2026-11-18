//
//  InputTranslatorUITests.swift
//  InputTranslatorUITests
//
//  Created by ziy on 14/11/26.
//

import AppKit
import XCTest

final class InputTranslatorUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testTopDockDragPinAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-topDockPanelDetached", "NO", "-panelPinned", "NO",
                               "-keepDockedPanelBesideLauncher", "NO", "-interfaceLanguage", "zh-Hans"]
        app.launch()
        defer { app.terminate() }

        let launcher = app.buttons["top-dock-toggle"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        let panel = app.dialogs["InputTranslator"].firstMatch
        launcher.hover()
        XCTAssertFalse(panel.exists)
        let capsule = launcher.frame
        launcher.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let docked = panel.frame
        XCTAssertEqual(docked.midX, capsule.midX, accuracy: 2)
        XCTAssertEqual(docked.minY, capsule.minY, accuracy: 2)
        XCTAssertFalse(launcher.exists)
        panel.buttons["top-dock-collapse"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        XCTAssertEqual(launcher.frame, capsule)
        launcher.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))

        let grip = panel.descendants(matching: .any)["top-dock-drag-handle"].firstMatch
        XCTAssertTrue(grip.exists)
        let gripCenter = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        gripCenter.click(forDuration: 0.1, thenDragTo: gripCenter.withOffset(CGVector(dx: 132, dy: 125)))
        let placement = panel.buttons["top-dock-placement"]
        XCTAssertEqual(placement.label, "停靠到顶部")
        XCTAssertGreaterThan(panel.frame.minY, docked.minY + 90)

        let resizeStart = panel.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        resizeStart.click(forDuration: 0.1, thenDragTo: resizeStart.withOffset(CGVector(dx: 80, dy: 72)))
        let detached = panel.frame
        XCTAssertGreaterThan(detached.width, docked.width + 35)
        XCTAssertGreaterThan(detached.height, docked.height + 30)
        panel.buttons["panel-pin"].click()
        XCTAssertEqual(panel.buttons["panel-pin"].label, "取消置顶")
        app.terminate()

        app.launchArguments = ["-interfaceLanguage", "zh-Hans"]
        app.launch()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(placement.label, "停靠到顶部")
        XCTAssertEqual(panel.frame, detached)
        placement.click()
        XCTAssertEqual(placement.label, "移出为浮窗")
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        XCTAssertEqual(panel.frame.size, docked.size)
        XCTAssertEqual(panel.frame.midX, launcher.frame.midX, accuracy: 2)
        XCTAssertEqual(panel.frame.minY - launcher.frame.maxY, 5, accuracy: 2)
        let belowCapsule = launcher.frame
        let belowWindow = panel.frame
        panel.buttons["top-dock-collapse"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        XCTAssertEqual(launcher.frame, belowCapsule)
        launcher.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(launcher.exists)
        XCTAssertEqual(panel.frame, belowWindow)
        XCTAssertEqual(launcher.frame, belowCapsule)

        placement.click()
        let screenTop = try XCTUnwrap(NSScreen.screens.first?.frame.maxY)
        let display = try XCTUnwrap(NSScreen.screens.first {
            ($0.visibleFrame.minX...$0.visibleFrame.maxX).contains(launcher.frame.midX)
        })
        let capsuleCenter = launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let distanceToBottom = screenTop - display.visibleFrame.minY - launcher.frame.midY - 22
        capsuleCenter.click(forDuration: 0.1, thenDragTo: capsuleCenter.withOffset(CGVector(dx: 0, dy: distanceToBottom)))
        let bottomCapsule = launcher.frame
        placement.click()
        XCTAssertEqual(launcher.frame, bottomCapsule)
        XCTAssertEqual(panel.frame.midX, bottomCapsule.midX, accuracy: 2)
        XCTAssertEqual(bottomCapsule.minY - panel.frame.maxY, 5, accuracy: 2)
        let aboveWindow = panel.frame
        panel.buttons["top-dock-collapse"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        XCTAssertEqual(launcher.frame, bottomCapsule)
        launcher.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertTrue(launcher.exists)
        XCTAssertEqual(panel.frame, aboveWindow)
        XCTAssertEqual(launcher.frame, bottomCapsule)
    }

    @MainActor
    func testLauncherDragPersistsAndWindowCollapsesBackToMovedCapsule() {
        let app = XCUIApplication()
        app.launchArguments = ["-topDockPanelDetached", "NO", "-panelPinned", "NO",
                               "-keepDockedPanelBesideLauncher", "NO", "-interfaceLanguage", "zh-Hans"]
        app.launch()
        defer { app.terminate() }

        let launcher = app.buttons["top-dock-toggle"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        launcher.rightClick()
        app.menuItems["恢复默认"].firstMatch.click()
        let initial = launcher.frame
        let handle = launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        handle.click(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 96, dy: 88)))
        let moved = launcher.frame
        XCTAssertGreaterThan(moved.minX, initial.minX + 60)
        XCTAssertGreaterThan(moved.minY, initial.minY + 55)

        let panel = app.dialogs["InputTranslator"].firstMatch
        XCTAssertFalse(panel.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertEqual(launcher.frame, moved)

        launcher.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(panel.frame.midX, moved.midX, accuracy: 2)
        XCTAssertEqual(panel.frame.minY, moved.minY, accuracy: 2)
        XCTAssertFalse(launcher.exists)
        panel.buttons["top-dock-collapse"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(launcher.waitForExistence(timeout: 3))
        XCTAssertEqual(launcher.frame, moved)

        launcher.rightClick()
        app.menuItems["恢复默认"].firstMatch.click()
        XCTAssertEqual(launcher.frame, initial)
    }

    @MainActor
    func testPreviewResizesWithWindowAndDivider() {
        let app = XCUIApplication()
        app.launchArguments = ["-topDockPanelDetached", "NO", "-panelPinned", "NO",
                               "-keepDockedPanelBesideLauncher", "YES", "-interfaceLanguage", "en",
                               "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }

        let panel = openComposer(in: app)
        let text = (1...16).map { "Check step \($0)." }.joined(separator: "\n")
        panel.typeText(text)
        let preview = panel.scrollViews["translation-scroll"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let placement = panel.buttons["top-dock-placement"]
        let launcher = app.buttons["top-dock-toggle"].firstMatch
        let capsule = launcher.frame

        func enlargeWindow() {
            let windowFrame = panel.frame
            let previewFrame = preview.frame
            let corner = panel.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            corner.click(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 80, dy: 150)))
            XCTAssertGreaterThan(panel.frame.width, windowFrame.width + 40)
            XCTAssertGreaterThan(panel.frame.height, windowFrame.height + 80)
            XCTAssertGreaterThan(preview.frame.height, previewFrame.height + 40)
        }

        enlargeWindow()
        XCTAssertEqual(launcher.frame, capsule)
        XCTAssertEqual(panel.frame.minY - capsule.maxY, 5, accuracy: 2)
        let resized = panel.frame
        panel.buttons["top-dock-collapse"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        launcher.click()
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertEqual(panel.frame, resized)

        let divider = panel.splitters.firstMatch
        XCTAssertTrue(divider.exists)
        let handle = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let initialPreview = preview.frame.height
        handle.click(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: -65)))
        let expandedPreview = preview.frame.height
        XCTAssertGreaterThan(expandedPreview, initialPreview + 45)
        XCTAssertEqual(panel.frame, resized)
        handle.click(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: 95)))
        XCTAssertLessThan(preview.frame.height, expandedPreview - 75)
        XCTAssertEqual(panel.frame, resized)

        placement.click()
        enlargeWindow()
    }

    @MainActor
    func testFocusFailurePreservesPreviewAndOnlyOffersAuthorizationWhenNeeded() {
        let app = XCUIApplication()
        app.launchArguments = ["-panelPinned", "NO", "-topDockEnabled", "YES",
                               "-interfaceLanguage", "en", "-AppleLanguages", "(en)", "-autoSubmit", "YES"]
        app.launch()
        defer { app.terminate() }

        let panel = openComposer(in: app)
        let editor = panel.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("123")
        XCTAssertEqual(editor.value as? String, "123")
        let preview = panel.staticTexts["translation-result"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let authorization = panel.descendants(matching: .any)["terminal-accessibility-settings"].firstMatch
        let offeredAuthorization = authorization.exists
        let paste = panel.buttons["paste-to-terminal"].firstMatch
        let status = panel.staticTexts["translation-status"].firstMatch
        XCTAssertTrue(paste.label.contains("Paste & Submit"))
        paste.click()
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(authorization.exists, offeredAuthorization)
        if offeredAuthorization {
            XCTAssertTrue(authorization.isEnabled)
            XCTAssertTrue(authorization.isHittable)
        }
        XCTAssertTrue(preview.exists)
    }

    @MainActor
    func testSettingsButtonFollowsPinAndOpensSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-panelPinned", "NO", "-topDockEnabled", "YES", "-interfaceLanguage", "zh-Hans"]
        app.launch()
        defer { app.terminate() }

        let panel = openComposer(in: app)
        let gear = panel.buttons["panel-settings"]
        XCTAssertTrue(gear.exists)
        XCTAssertEqual(gear.label, "设置…")
        XCTAssertGreaterThan(gear.frame.minX, panel.buttons["panel-pin"].frame.minX)

        panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "读回复")).firstMatch.click()
        gear.click()
        XCTAssertTrue(app.windows["InputTranslator 设置"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsSelectAndRememberNonDefaultLanguagePair() {
        let app = XCUIApplication()
        app.launchArguments = ["-panelPinned", "NO", "-interfaceLanguage", "zh-Hans"]
        app.launch()
        defer { app.terminate() }

        let panel = openComposer(in: app)
        XCTAssertFalse(panel.popUpButtons["target-language"].exists)
        let settings = openLanguageSettings(in: app, from: panel)
        let target = settings.popUpButtons["target-language"]
        let source = settings.popUpButtons["source-language"]
        if source.value as? String == "法语" {
            settings.buttons["交换语言"].click()
        }
        target.click()
        let french = app.menuItems["法语"].firstMatch
        XCTAssertTrue(french.waitForExistence(timeout: 5))
        french.click()
        source.click()
        let japanese = app.menuItems["日语"].firstMatch
        XCTAssertTrue(japanese.waitForExistence(timeout: 5))
        japanese.click()
        XCTAssertEqual(source.value as? String, "日语")
        XCTAssertEqual(target.value as? String, "法语")
        settings.buttons["交换语言"].click()
        XCTAssertEqual(source.value as? String, "法语")
        XCTAssertEqual(target.value as? String, "日语")

        app.terminate()
        app.launch()
        let reopened = openComposer(in: app)
        _ = openLanguageSettings(in: app, from: reopened)
        XCTAssertEqual(source.value as? String, "法语")
        XCTAssertEqual(target.value as? String, "日语")
    }

    @MainActor
    func testReplyModeHasClearReadAndClipboardActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-panelPinned", "NO", "-interfaceLanguage", "zh-Hans", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let panel = openComposer(in: app)
        let frame = panel.frame
        let prompt = panel.textViews["提示词"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        panel.typeText("123")
        XCTAssertEqual(prompt.value as? String, "123")
        panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "读回复")).firstMatch.click()
        let empty = panel.descendants(matching: .any)["reply-empty-state"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(panel.frame, frame)
        XCTAssertFalse(panel.buttons["复制译文"].exists)
        let readClipboard = panel.buttons["read-reply-from-clipboard"]
        XCTAssertTrue(readClipboard.exists)

        let clipboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = clipboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        clipboard.clearContents()
        let reply = """
        # Rollout

        - **Ready:** Run `npm test`.
        - Review [the guide](https://example.com).

        ```sh
        npm test
        ```

        | Check | Result |
        | --- | --- |
        | Build | Ready |
        """
        XCTAssertTrue(clipboard.setString(reply, forType: .string))
        var testClipboard = clipboard.changeCount
        defer {
            if clipboard.changeCount == testClipboard {
                clipboard.clearContents()
                if !saved.isEmpty { clipboard.writeObjects(saved) }
            }
        }
        readClipboard.click()
        let translated = panel.scrollViews["reply-translation"].firstMatch
        XCTAssertTrue(translated.waitForExistence(timeout: 5))
        XCTAssertTrue(translated.staticTexts["Rollout"].exists)
        XCTAssertTrue(translated.staticTexts["reply-code"].exists)
        let original = panel.scrollViews["reply-original"].firstMatch
        panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "原文")).firstMatch.click()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertTrue(original.staticTexts["Rollout"].exists)
        XCTAssertFalse(translated.exists)
        XCTAssertEqual(panel.frame, frame)
        panel.buttons["edit-reply-source"].click()
        let editor = panel.textViews["回复原文"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, reply)
        panel.buttons["edit-reply-source"].click()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "译文")).firstMatch.click()
        XCTAssertTrue(translated.waitForExistence(timeout: 5))
        XCTAssertFalse(original.exists)
        XCTAssertEqual(panel.frame, frame)

        clipboard.clearContents()
        XCTAssertTrue(clipboard.setString("   ", forType: .string))
        testClipboard = clipboard.changeCount
        readClipboard.click()
        let status = panel.staticTexts["translation-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue([status.label, status.value as? String ?? ""].contains { $0.contains("剪贴板里没有") })
        XCTAssertTrue(translated.exists)

        panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "写提示词")).firstMatch.click()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertEqual(prompt.value as? String, "123")
        panel.typeText("4")
        XCTAssertEqual((prompt.value as? String)?.sorted(), Array("1234"))
        XCTAssertEqual(panel.frame, frame)
    }

    @MainActor
    private func openComposer(in app: XCUIApplication) -> XCUIElement {
        let launcher = app.buttons["top-dock-toggle"].firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        app.activate()
        launcher.click()
        let panel = app.dialogs["InputTranslator"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        return panel
    }

    @MainActor
    private func openLanguageSettings(in app: XCUIApplication, from panel: XCUIElement) -> XCUIElement {
        panel.buttons["panel-settings"].click()
        let settings = app.descendants(matching: .any)["InputTranslator 设置"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "语言")).firstMatch.click()
        XCTAssertTrue(settings.popUpButtons["source-language"].waitForExistence(timeout: 5))
        return settings
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
