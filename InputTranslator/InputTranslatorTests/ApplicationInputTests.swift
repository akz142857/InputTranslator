import AppKit
import ApplicationServices
import Carbon
import XCTest
@testable import InputTranslator

final class ApplicationInputTests: XCTestCase {
    @MainActor private func settings(_ seed: [String: Any] = [:]) throws -> AppSettings {
        let suite = "ApplicationInputTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.setPersistentDomain(seed, forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults, preferredLanguage: "en")
    }

    @MainActor func testLegacyTerminalSettingsMigrateWithoutEnablingSubmitForOtherApps() throws {
        let settings = try settings(["autoSubmit": true, "targetTerminal": "iTerm"])
        XCTAssertEqual(settings.pasteDestination, .iTerm)
        XCTAssertTrue(settings.automaticallySubmits(to: PasteDestination.iTerm.rawValue))
        XCTAssertTrue(settings.automaticallySubmits(to: PasteDestination.terminal.rawValue))
        XCTAssertFalse(settings.automaticallySubmits(to: PasteDestination.herdr.rawValue))
        XCTAssertFalse(settings.automaticallySubmits(to: "com.apple.TextEdit"))
        XCTAssertFalse(settings.automaticallySubmits(to: nil))
        settings.setAutomaticallySubmits(false, to: PasteDestination.iTerm.rawValue)
        settings.setAutomaticallySubmits(true, to: PasteDestination.herdr.rawValue)
        XCTAssertFalse(settings.automaticallySubmits(to: PasteDestination.iTerm.rawValue))
        XCTAssertTrue(settings.automaticallySubmits(to: PasteDestination.terminal.rawValue))
        XCTAssertTrue(settings.automaticallySubmits(to: PasteDestination.herdr.rawValue))
    }

    @MainActor func testPerApplicationSubmissionAndArbitraryFixedDestinationSurviveRelaunch() throws {
        let suite = "ApplicationInputTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "autoSubmit")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.pasteDestination, .currentApplication)
        settings.pasteDestination = PasteDestination(rawValue: "com.apple.TextEdit")
        settings.setAutomaticallySubmits(true, to: PasteDestination.herdr.rawValue)
        settings.setAutomaticallySubmits(false, to: PasteDestination.terminal.rawValue)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.pasteDestination.bundleIdentifier, "com.apple.TextEdit")
        XCTAssertTrue(reloaded.automaticallySubmits(to: PasteDestination.herdr.rawValue))
        XCTAssertFalse(reloaded.automaticallySubmits(to: PasteDestination.terminal.rawValue))
        XCTAssertTrue(reloaded.automaticallySubmits(to: PasteDestination.iTerm.rawValue))
        XCTAssertFalse(reloaded.automaticallySubmits(to: "com.apple.TextEdit"))
    }

    @MainActor func testCurrentApplicationCapturesNonTerminalAndKeepsReplyCapabilitySeparate() async throws {
        let app = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let target = ApplicationTarget(pid: app.processIdentifier, launchDate: app.launchDate, window: element, input: element)
        let controller = InputController(settings: try settings(["autoSubmit": true]), readFocusedTarget: { _ in target },
                                         accessibilityAccess: { true })
        controller.activeApplicationChanged(to: app)
        for _ in 0..<50 where controller.target == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.target, target)
        XCTAssertEqual(controller.targetName, app.localizedName)
        XCTAssertFalse(controller.supportsReplyReading)
        XCTAssertFalse(controller.automaticallySubmitsToTarget)
        XCTAssertEqual(controller.pasteActionTitle, L10n.text("粘贴到 %@", try XCTUnwrap(app.localizedName)))
        controller.setAutomaticallySubmitsToTarget(true)
        controller.text = "Review the patch."
        XCTAssertTrue(controller.willSubmitPrompt)
        controller.text += "\nThen run tests."
        XCTAssertFalse(controller.willSubmitPrompt)
    }

    @MainActor func testEditableRolesExcludeSecureDisabledAndReadOnlyFields() {
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] {
            XCTAssertTrue(ApplicationTargetManager.acceptsTextInput(role: role, subrole: nil, enabled: true, editable: true))
            XCTAssertFalse(ApplicationTargetManager.acceptsTextInput(role: role, subrole: nil, enabled: false, editable: true))
            XCTAssertFalse(ApplicationTargetManager.acceptsTextInput(role: role, subrole: nil, enabled: true, editable: false))
        }
        XCTAssertFalse(ApplicationTargetManager.acceptsTextInput(role: kAXTextFieldRole,
            subrole: kAXSecureTextFieldSubrole, enabled: true, editable: true))
        XCTAssertFalse(ApplicationTargetManager.acceptsTextInput(role: kAXWindowRole, subrole: nil, enabled: true, editable: nil))
        XCTAssertFalse(ApplicationTargetManager.acceptsTextInput(role: kAXGroupRole, subrole: nil, enabled: true, editable: nil))
        XCTAssertFalse(ApplicationTargetManager.acceptsTextInput(role: kAXTextAreaRole, subrole: nil,
            enabled: true, editable: nil, valueSettable: false))
        XCTAssertTrue(TerminalReplyReader.supports(PasteDestination.terminal.rawValue))
        XCTAssertTrue(TerminalReplyReader.supports(PasteDestination.iTerm.rawValue))
        XCTAssertFalse(TerminalReplyReader.supports(PasteDestination.herdr.rawValue))
    }

    func testHerdrRequiresMatchingActiveTerminalPaneAndNoOverlay() throws {
        let status = Data(#"{"space":"s1","tab":"t1","focused_pane":"p1","overlays":[]}"#.utf8)
        let layout = Data(#"{"spaces":[{"id":"s1","active":true,"tabs":[{"id":"t1","active":true,"terminals":[{"terminal":"remote/t7","pane":"p1"}]}]}]}"#.utf8)
        let focus = try HerdrAdapter.decodeFocus(status: status, layout: layout)
        XCTAssertEqual(focus, HerdrFocus(space: "s1", tab: "t1", pane: "p1", terminal: "remote/t7"))
        for invalid in [
            #"{"space":"s1","tab":"t1","focused_pane":"p2","overlays":[]}"#,
            #"{"space":"s1","tab":"t2","focused_pane":"p1","overlays":[]}"#,
            #"{"space":"s1","tab":"t1","focused_pane":"p1","overlays":["settings"]}"#,
            #"{"space":"s1","tab":"t1","focused_pane":null,"overlays":[]}"#
        ] {
            XCTAssertThrowsError(try HerdrAdapter.decodeFocus(status: Data(invalid.utf8), layout: layout))
        }
        let inactive = Data(String(decoding: layout, as: UTF8.self).replacingOccurrences(of: "true", with: "false").utf8)
        XCTAssertThrowsError(try HerdrAdapter.decodeFocus(status: status, layout: inactive))
    }

    @MainActor func testInstalledHerdrAdapterReadsCurrentPaneWithoutChangingIt() async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: PasteDestination.herdr.rawValue).first,
              let executable = app.executableURL else { throw XCTSkip("A running Herdr window is required") }
        let first = try await HerdrAdapter.focus(in: executable)
        let second = try await HerdrAdapter.focus(in: executable)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.terminal.isEmpty)
    }

    @MainActor func testPasteOnlySendsCommandVAndPreservesClipboard() async throws {
        let (target, board) = makePasteFixture()
        var events: [Int64] = []
        let environment = PasteService.Environment(board: board, restoreFocus: { _ in }, matchesFocus: { _ in true },
            post: { event, _ in events.append(event.getIntegerValueField(.keyboardEventKeycode)) }, waitForPaste: {})
        let outcome = try await PasteService.paste("Translated text", into: target, autoSubmit: false,
            preserveClipboard: true, willPostPaste: {}, environment: environment)
        XCTAssertEqual(outcome, .pastePosted)
        XCTAssertEqual(events, [Int64(kVK_ANSI_V), Int64(kVK_ANSI_V)])
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    @MainActor func testFocusChangeAfterPasteSkipsEnter() async throws {
        let (target, board) = makePasteFixture()
        var focusMatches = true
        var events: [Int64] = []
        let environment = PasteService.Environment(board: board, restoreFocus: { _ in }, matchesFocus: { _ in focusMatches },
            post: { event, _ in events.append(event.getIntegerValueField(.keyboardEventKeycode)) },
            waitForPaste: { focusMatches = false })
        let outcome = try await PasteService.paste("Translated text", into: target, autoSubmit: true,
            preserveClipboard: true, willPostPaste: {}, environment: environment)
        XCTAssertEqual(outcome, .enterSkipped)
        XCTAssertFalse(events.contains(Int64(kVK_Return)))
        XCTAssertEqual(board.string(forType: .string), "Original clipboard")
    }

    @MainActor func testOptInSubmitsOnlySingleLineText() async throws {
        for text in ["Translated text", "First line\nSecond line"] {
            let (target, board) = makePasteFixture()
            var events: [Int64] = []
            let environment = PasteService.Environment(board: board, restoreFocus: { _ in }, matchesFocus: { _ in true },
                post: { event, _ in events.append(event.getIntegerValueField(.keyboardEventKeycode)) }, waitForPaste: {})
            let outcome = try await PasteService.paste(text, into: target, autoSubmit: true,
                preserveClipboard: true, willPostPaste: {}, environment: environment)
            XCTAssertEqual(outcome, text.contains("\n") ? .enterSkipped : .enterPosted)
            XCTAssertEqual(events.filter { $0 == Int64(kVK_Return) }.count, text.contains("\n") ? 0 : 2)
        }
    }

    @MainActor func testPastePreservesNewClipboardContentAndSkipsEnter() async throws {
        let (target, board) = makePasteFixture()
        var events: [Int64] = []
        let environment = PasteService.Environment(board: board, restoreFocus: { _ in }, matchesFocus: { _ in true },
            post: { event, _ in events.append(event.getIntegerValueField(.keyboardEventKeycode)) }, waitForPaste: {
                board.clearContents()
                board.setString("New clipboard", forType: .string)
            })
        let outcome = try await PasteService.paste("Translated text", into: target, autoSubmit: true,
            preserveClipboard: true, willPostPaste: {}, environment: environment)
        XCTAssertEqual(outcome, .enterSkipped)
        XCTAssertFalse(events.contains(Int64(kVK_Return)))
        XCTAssertEqual(board.string(forType: .string), "New clipboard")
    }

    @MainActor func testUnverifiedTargetDoesNotTouchClipboardOrPostEvents() async throws {
        let (target, board) = makePasteFixture()
        let changeCount = board.changeCount
        var events = 0
        let environment = PasteService.Environment(board: board, restoreFocus: { _ in }, matchesFocus: { _ in false },
            post: { _, _ in events += 1 }, waitForPaste: {})
        do {
            _ = try await PasteService.paste("Translated text", into: target, autoSubmit: true,
                preserveClipboard: true, willPostPaste: {}, environment: environment)
            XCTFail("A changed target must stop delivery")
        } catch { XCTAssertEqual(error as? PasteFailure, .focusChanged) }
        XCTAssertEqual(events, 0)
        XCTAssertEqual(board.changeCount, changeCount)
    }

    @MainActor private func makePasteFixture() -> (ApplicationTarget, NSPasteboard) {
        let app = NSRunningApplication.current
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let board = NSPasteboard.withUniqueName()
        board.setString("Original clipboard", forType: .string)
        addTeardownBlock { board.releaseGlobally() }
        return (ApplicationTarget(pid: app.processIdentifier, launchDate: app.launchDate,
                                  window: element, input: element), board)
    }
}
