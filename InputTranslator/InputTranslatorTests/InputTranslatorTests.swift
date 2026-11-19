import AppKit
import ApplicationServices
import Translation
import XCTest
@testable import InputTranslator

final class InputTranslatorTests: XCTestCase {
    @MainActor private func terminalFocusFixture() throws -> (NSRunningApplication, ApplicationTarget) {
        let terminal = (NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2")
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")).first
        guard let terminal else { throw XCTSkip("A running Terminal or iTerm2 is required for focus capture tests") }
        let element = AXUIElementCreateApplication(terminal.processIdentifier)
        return (terminal, ApplicationTarget(pid: terminal.processIdentifier, launchDate: terminal.launchDate,
                                         window: element, input: element))
    }

    @MainActor func testActivationRetainsVerifiedTerminalDuringTransientFocusReadFailure() async throws {
        let (terminal, target) = try terminalFocusFixture()
        var reads = 0
        let controller = InputController(settings: try isolatedSettings(), readFocusedTarget: { _ in
            reads += 1
            return reads == 1 ? target : nil
        }, accessibilityAccess: { true })
        controller.activeApplicationChanged(to: terminal)
        await waitForTarget(controller)
        XCTAssertEqual(controller.target, target)
        controller.activeApplicationChanged(to: terminal)
        XCTAssertEqual(controller.target, target)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(controller.target, target)
    }

    @MainActor func testTerminalFocusCaptureRetriesAndRejectsAnOutdatedCapture() async throws {
        let (terminal, target) = try terminalFocusFixture()
        var reads = 0
        let controller = InputController(settings: try isolatedSettings(), readFocusedTarget: { app in
            guard app.processIdentifier == terminal.processIdentifier else { return nil }
            reads += 1
            return reads >= 3 ? target : nil
        }, accessibilityAccess: { true })
        controller.activeApplicationChanged(to: terminal)
        XCTAssertNil(controller.target)
        for _ in 0..<60 where controller.target == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.target, target)
        reads = 0
        controller.activeApplicationChanged(to: terminal)
        await Task.yield()
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        controller.activeApplicationChanged(to: finder)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(controller.target)
        XCTAssertEqual(controller.targetName, finder.localizedName)
    }

    @MainActor private func waitForTarget(_ controller: InputController) async {
        for _ in 0..<60 where controller.target == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor func testChangingApplicationChoiceInvalidatesTheEarlierTarget() async throws {
        let (terminal, target) = try terminalFocusFixture()
        let settings = try isolatedSettings()
        let controller = InputController(settings: settings, readFocusedTarget: { _ in target },
                                         accessibilityAccess: { true })
        controller.activeApplicationChanged(to: terminal)
        await waitForTarget(controller)
        XCTAssertEqual(controller.target, target)
        controller.selectPasteDestination(terminal.bundleIdentifier == "com.googlecode.iterm2" ? .terminal : .iTerm)
        controller.text = "Check the patch."
        controller.requestPrimaryAction()
        XCTAssertNil(controller.target)
        XCTAssertTrue(controller.showsError)
        XCTAssertFalse(controller.offersAccessibilitySettings)
        XCTAssertEqual(controller.result, "Check the patch.")
    }

    @MainActor func testUnverifiedTerminalFocusDoesNotOfferPermissionSettingsWhenAuthorized() throws {
        let controller = InputController(settings: try isolatedSettings(), accessibilityAccess: { true })
        controller.text = "Check the patch."
        controller.requestPrimaryAction()
        XCTAssertTrue(controller.hasAccessibilityAccess)
        XCTAssertTrue(controller.showsError)
        XCTAssertFalse(controller.offersAccessibilitySettings)
        XCTAssertEqual(controller.text, "Check the patch.")
        XCTAssertEqual(controller.result, "Check the patch.")
    }

    @MainActor func testMissingAccessibilityPermissionKeepsAuthorizationAvailable() throws {
        let controller = InputController(settings: try isolatedSettings(), accessibilityAccess: { false })
        controller.text = "Check the patch."
        controller.requestPrimaryAction()
        XCTAssertFalse(controller.hasAccessibilityAccess)
        XCTAssertTrue(controller.showsError)
        XCTAssertTrue(controller.offersAccessibilitySettings)
        XCTAssertEqual(controller.result, "Check the patch.")
    }

    @MainActor func testProtectedCodeRoundTrip() throws {
        let source = """
        检查 `getUserInfo()` 和 ``含有 ` 的代码``：

        ```sql
        SELECT user_id FROM users;
        ```

        ~~~json
        {"key":"保留"}
        ~~~
        """
        let prompt = ProtectedPrompt(source)
        XCTAssertFalse(prompt.source.contains("SELECT"))
        XCTAssertFalse(prompt.source.contains("getUserInfo"))
        XCTAssertFalse(prompt.source.contains("含有"))
        XCTAssertFalse(prompt.source.contains("保留"))
        let translated = prompt.source.replacingOccurrences(of: "检查", with: "Check")
        XCTAssertEqual(try prompt.restore(in: translated), source.replacingOccurrences(of: "检查", with: "Check"))
    }

    @MainActor func testFencedBlockWithCRLFAndUnclosedFence() throws {
        let source = "检查\r\n````md\r\n```\r\n内容"
        let prompt = ProtectedPrompt(source)
        XCTAssertFalse(prompt.source.contains("内容"))
        XCTAssertEqual(try prompt.restore(in: prompt.source), source)
    }

    @MainActor func testMissingDuplicatedAndReorderedCodeFails() throws {
        let prompt = ProtectedPrompt("`alpha` `beta`")
        let tokens = prompt.source.split(separator: " ").map(String.init)
        XCTAssertEqual(tokens.count, 2)
        guard tokens.count == 2 else { return }
        XCTAssertThrowsError(try prompt.restore(in: "Inspect \(tokens[0])"))
        XCTAssertThrowsError(try prompt.restore(in: "\(prompt.source) \(tokens[1])"))
        XCTAssertThrowsError(try prompt.restore(in: tokens.reversed().joined(separator: " ")))
        XCTAssertThrowsError(try prompt.restore(in: prompt.source.lowercased()))
    }

    @MainActor func testFenceMustStayOnOwnLine() throws {
        let prompt = ProtectedPrompt("检查\n```sh\nprintf hello\n```")
        XCTAssertThrowsError(try prompt.restore(in: prompt.source.replacingOccurrences(of: "\n", with: " ")))
    }

    func testTranslatedNumberedLinesDoNotGainBlankParagraphs() throws {
        let source = "1、对 halro-rate-limit-recovery 推送到远程\n2、对当前项目 halro commit and push，open pr"
        let translated = "1. Push halro-rate-limit-recovery to the remote\n\n2. Commit and push the current halro project, open a PR"
        XCTAssertEqual(try ProtectedPrompt(source).restore(in: translated),
                       translated.replacingOccurrences(of: "\n\n", with: "\n"))
        XCTAssertEqual(try ProtectedPrompt("First line\nSecond line").restore(in: "第一行\n\n第二行"), "第一行\n第二行")
    }

    func testTranslationKeepsOriginalIndentationBlankLinesAndLineEndings() throws {
        let source = "  第一行  \r\n\t\r\n\r\n\t第二行\t\r\n"
        XCTAssertEqual(try ProtectedPrompt(source).restore(in: "\nFirst line\n\nSecond line\n"),
                       "  First line  \r\n\t\r\n\r\n\tSecond line\t\r\n")
    }

    func testTranslationRestoresLayoutBeforeReinsertingExactCode() throws {
        let source = "检查 `user_id`\n\n```sh\n  echo '保留'\n\n  printf hello\n```\n最后一行\n"
        let prompt = ProtectedPrompt(source)
        let translated = prompt.source.replacingOccurrences(of: "检查", with: "Check")
            .replacingOccurrences(of: "最后一行", with: "Last line")
            .replacingOccurrences(of: "\n", with: "\n\n")
        XCTAssertEqual(try prompt.restore(in: translated), source.replacingOccurrences(of: "检查", with: "Check")
            .replacingOccurrences(of: "最后一行", with: "Last line"))
    }

    func testChangedContentLineCountRequiresFallbackWithoutDroppingText() {
        XCTAssertThrowsError(try ProtectedPrompt("第一行\n第二行").restore(in: "Merged translation"))
        XCTAssertThrowsError(try ProtectedPrompt("一行").restore(in: "First part\nSecond part"))
    }

    @MainActor func testProseFallbackBatchesLinesAndPreservesCodeAndBlankLines() async throws {
        let source = "  第一行\r\n\r\n\t第二行 `literal`\r\n```sh\n  echo 保留\n\n```\r\n第三行\r\n"
        var batches = 0
        let result = try await ProtectedPrompt(source).translateProse(in: .chineseToEnglish) { requests in
            batches += 1
            XCTAssertEqual(requests.map(\.sourceText), ["第一行", "第二行", "第三行"])
            return Dictionary(uniqueKeysWithValues: requests.reversed().map {
                ($0.clientIdentifier!, "Translated\n\n" + $0.sourceText)
            })
        }
        XCTAssertEqual(batches, 1)
        XCTAssertEqual(result, "  Translated 第一行\r\n\r\n\tTranslated 第二行 `literal`\r\n```sh\n  echo 保留\n\n```\r\nTranslated 第三行\r\n")
        do {
            _ = try await ProtectedPrompt("检查\n日志").translateProse(in: .chineseToEnglish) { _ in [:] }
            XCTFail("An incomplete response must not silently omit a line")
        } catch TranslationFailure.emptyResponse { }
    }

    @MainActor func testInstalledNumberedTranslationKeepsTwoAdjacentLines() async throws {
        let pair = TranslationPair.chineseToEnglish
        let status = await LanguageAvailability().status(from: pair.source.localeLanguage, to: pair.target.localeLanguage)
        try XCTSkipUnless(status == .installed, "Chinese and English system translation models are required")
        let controller = InputController(settings: try isolatedSettings())
        controller.showComposer()
        defer { controller.dismissPanel() }
        let source = "1、对 halro-rate-limit-recovery 推送到远程\n2、对当前项目 halro commit and push，open pr"
        controller.text = source
        await waitForResult(controller)
        XCTAssertFalse(controller.result.isEmpty, controller.message ?? "No translation")
        XCTAssertEqual(controller.result.filter(\.isNewline).count, 1)
        XCTAssertEqual(controller.text, source)
    }

    @MainActor func testHeaderDraggingDetachesDockAndPreservesSizeAndPin() throws {
        let existingWindows = Set(NSApp.windows)
        let settings = try isolatedSettings()
        settings.panelPinned = true
        let controller = InputController(settings: settings)
        controller.showComposer()
        defer { controller.dismissPanel() }
        let panel = try newFloatingPanel(excluding: existingWindows)
        XCTAssertTrue(panel.isMovable, "The native title bar must remain draggable while docked")
        let size = panel.frame.size
        XCTAssertTrue(panel.beginGripDrag())
        XCTAssertNil(panel.dockLayout)
        XCTAssertTrue(settings.panelDetached)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 20, y: panel.frame.minY - 40))
        panel.endGripDrag(at: NSPoint(x: -100_000, y: -100_000))
        XCTAssertEqual(panel.frame.size, size)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(settings.panelPinned)
        XCTAssertEqual(settings.pinnedPanelPlacement?.frame, panel.frame)

        settings.topDockEnabled = false
        XCTAssertTrue(panel.beginGripDrag())
        panel.endGripDrag(at: NSEvent.mouseLocation)
        XCTAssertFalse(settings.topDockEnabled)
        XCTAssertNil(panel.dockLayout)
    }

    @MainActor func testReplyMarkdownPreservesAssistantStructureAndLiteralCode() {
        let source = """
        # Release

        - **Important:** Review `origin/main` and [the guide](https://example.com/guide).
          1. Check the logs.

        > Keep this note.

        | Check | Result |
        | --- | --- |
        | Build | Ready |

        ```sh
        npm test
        ```
        """
        let document = ReplyMarkdown(source)
        let display = ReplyMarkdown(source, retainSourcePositions: false)
        XCTAssertEqual(display.blocks.map(\.path), document.blocks.map(\.path))
        XCTAssertEqual(display.blocks.map { String($0.text.characters) }, document.blocks.map { String($0.text.characters) })
        let ranges = document.translationRanges(in: TranslationPair.chineseToEnglish.reverse)
        let replacements = Dictionary(uniqueKeysWithValues: ranges.indices.map { ($0, "译文") })
        let translated = document.replacingProse(at: ranges, with: replacements)
        let result = ReplyMarkdown(translated)
        XCTAssertTrue(document.hasFormatting)
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertEqual(result.blocks.map(\.path), document.blocks.map(\.path))
        XCTAssertTrue(translated.contains("**译文**"))
        XCTAssertTrue(translated.contains("`origin/main`"))
        XCTAssertTrue(translated.contains("(https://example.com/guide)"))
        XCTAssertTrue(translated.contains("```sh\nnpm test\n```"))
    }

    @MainActor func testEnglishAndCodeOnlyDoNotRequireTranslation() {
        XCTAssertFalse(ProtectedPrompt("Review `中文字段`").requiresTranslation(in: .chineseToEnglish))
        XCTAssertTrue(ProtectedPrompt("检查 `user_id`").requiresTranslation(in: .chineseToEnglish))
    }

    @MainActor func testPasteConfirmationAndControlCharacters() {
        XCTAssertFalse(PasteService.requiresConfirmation(text: "Review"))
        XCTAssertTrue(PasteService.requiresConfirmation(text: "Review\nx"))
        XCTAssertTrue(PasteService.allowsPaste("Review 👩‍💻\n\tsecond line"))
        XCTAssertFalse(PasteService.allowsPaste("Review\u{1B}[201~"))
        XCTAssertFalse(PasteService.allowsPaste("Review\r"))
        XCTAssertFalse(PasteService.allowsPaste("Review\u{2028}"))
    }

    @MainActor func testClipboardSnapshotLimitAndDeclaredOwnership() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let owned = board.declareTypes([.string], owner: nil)
        XCTAssertTrue(board.setString("existing clipboard", forType: .string))
        XCTAssertEqual(board.changeCount, owned)
        XCTAssertThrowsError(try PasteService.snapshot(board, byteLimit: 4))
        XCTAssertEqual(board.changeCount, owned)
        XCTAssertEqual(try PasteService.snapshot(board).first?.string(forType: .string), "existing clipboard")
    }

    @MainActor func testSingleLineAutomaticSubmissionIsOptIn() throws {
        let settings = try isolatedSettings()
        let controller = InputController(settings: settings)
        controller.selectPasteDestination(.terminal)
        controller.text = "Review the patch."
        XCTAssertFalse(controller.willSubmitPrompt)
        settings.setAutomaticallySubmits(true, to: PasteDestination.terminal.rawValue)
        XCTAssertTrue(controller.willSubmitPrompt)
        XCTAssertFalse(PasteService.requiresConfirmation(text: controller.text))
        controller.text += "\nThen run the tests."
        XCTAssertFalse(controller.willSubmitPrompt)
        XCTAssertTrue(PasteService.requiresConfirmation(text: controller.text))
    }

    @MainActor func testPanelPreviewPreservesSource() async throws {
        let existingWindows = Set(NSApp.windows)
        let controller = InputController(settings: try isolatedSettings())
        controller.showComposer()
        defer { controller.dismissPanel() }
        let panel = try newFloatingPanel(excluding: existingWindows)
        for _ in 0..<20 where !(panel.firstResponder is PromptTextView) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(panel.firstResponder is PromptTextView)
        controller.updateComposition(true)
        controller.text = "Review"
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertTrue(controller.result.isEmpty)
        controller.text = "Review `user_id`."
        controller.updateComposition(false)
        await waitForResult(controller)
        XCTAssertEqual(controller.result, "Review `user_id`.")
        XCTAssertEqual(controller.text, "Review `user_id`.")
        XCTAssertTrue(panel.isVisible)
        controller.text = "Review another field."
        XCTAssertTrue(controller.result.isEmpty)
    }

    @MainActor func testInstalledTranslationThroughPanel() async throws {
        let status = await LanguageAvailability().status(from: TranslationPair.chineseToEnglish.source.localeLanguage, to: TranslationPair.chineseToEnglish.target.localeLanguage)
        try XCTSkipUnless(status == .installed, "Chinese and English system translation models are required")

        let controller = InputController(settings: try isolatedSettings())
        controller.showComposer()
        defer { controller.dismissPanel() }
        controller.text = "你好，请列出文件。"
        await waitForResult(controller)
        let firstResult = controller.result
        XCTAssertFalse(firstResult.isEmpty, controller.message ?? "No result from Apple Translation")
        XCTAssertFalse(firstResult.unicodeScalars.contains { $0.properties.isIdeographic })
        XCTAssertEqual(controller.text, "你好，请列出文件。")

        controller.text = "请检查数据库结构。"
        XCTAssertTrue(controller.result.isEmpty)
        await waitForResult(controller)
        XCTAssertFalse(controller.result.isEmpty, controller.message ?? "No updated result from Apple Translation")
        XCTAssertNotEqual(controller.result, firstResult)
        XCTAssertEqual(controller.text, "请检查数据库结构。")
    }

    @MainActor func testCommandReturnRequestsPasteAfterTranslation() async throws {
        let status = await LanguageAvailability().status(from: TranslationPair.chineseToEnglish.source.localeLanguage, to: TranslationPair.chineseToEnglish.target.localeLanguage)
        try XCTSkipUnless(status == .installed, "Chinese and English system translation models are required")

        let existingWindows = Set(NSApp.windows)
        let controller = InputController(settings: try isolatedSettings())
        controller.showComposer()
        defer { controller.dismissPanel() }
        let panel = try newFloatingPanel(excluding: existingWindows)
        controller.text = "你好，请列出文件。"
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        panel.sendEvent(event)

        await waitForResult(controller)
        XCTAssertFalse(controller.result.isEmpty, controller.message ?? "No translation after Command-Return")
        XCTAssertTrue(controller.showsError)
        XCTAssertTrue(controller.offersAccessibilitySettings)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(controller.text, "你好，请列出文件。")
    }

    @MainActor func testInstalledTranslationSurvivesRepeatedReplacementAndCancellation() async throws {
        let pair = TranslationPair.chineseToEnglish
        let status = await LanguageAvailability().status(from: pair.source.localeLanguage,
                                                         to: pair.target.localeLanguage)
        try XCTSkipUnless(status == .installed, "Chinese and English system translation models are required")

        let settings = try isolatedSettings()
        settings.topDockEnabled = false
        let controller = InputController(settings: settings)
        controller.showComposer()
        defer { controller.dismissPanel() }
        let prompts = [
            "使用 harness2 的经验检查修改的了什么？",
            "请检查数据库结构。",
            "请列出这次修改的文件。",
            "请解释这个函数的作用。"
        ]
        for round in 0..<12 {
            controller.text = String(repeating: "请检查数据库结构和代码中的问题。", count: 100)
            for _ in 0..<40 where controller.requestID == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(controller.requestID, "Round \(round) did not start")
            if round.isMultiple(of: 2) { controller.cancel() }
            controller.updateComposition(true)
            controller.text = ""
            controller.text = prompts[round % prompts.count]
            controller.updateComposition(false)
            if round.isMultiple(of: 3) {
                controller.dismissPanel()
                controller.showComposer()
            }
            await waitForResult(controller)
            try XCTUnwrap(controller.result.isEmpty ? nil : controller.result,
                          "Round \(round) stalled: \(controller.message ?? "no status")")
            XCTAssertFalse(controller.busy)
            XCTAssertFalse(controller.result.unicodeScalars.contains { $0.properties.isIdeographic })
            XCTAssertEqual(controller.text, prompts[round % prompts.count])
        }
    }

    @MainActor func testUnresponsiveTranslationRestartsOnceAndAcceptsAnotherRequest() async throws {
        let pair = TranslationPair.chineseToEnglish
        let status = await LanguageAvailability().status(from: pair.source.localeLanguage,
                                                         to: pair.target.localeLanguage)
        try XCTSkipUnless(status == .installed, "Chinese and English system translation models are required")

        // With no panel, the session callback never starts. Exercise the actual watchdog.
        let controller = InputController(settings: try isolatedSettings(),
                                         translationResponseTimeout: .milliseconds(200))
        controller.text = "请检查数据库结构。"
        controller.requestPrimaryAction()
        defer { controller.cancel() }
        for _ in 0..<100 where controller.sessionRequest == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try XCTUnwrap(controller.sessionRequest)
        for _ in 0..<100 where controller.sessionRequest?.id == first.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        let retry = try XCTUnwrap(controller.sessionRequest)
        XCTAssertNotEqual(retry.id, first.id)
        XCTAssertEqual(retry.requestID, first.requestID)
        if #available(macOS 26, *) {
            let staleSession = TranslationSession(installedSource: pair.source.localeLanguage,
                                                  target: pair.target.localeLanguage)
            await controller.useTranslationSession(staleSession, for: first)
            XCTAssertEqual(controller.sessionRequest?.id, retry.id)
            XCTAssertTrue(controller.result.isEmpty)
        }
        await waitForResult(controller)
        XCTAssertTrue(controller.showsError)
        XCTAssertFalse(controller.busy)
        XCTAssertNil(controller.requestID)
        XCTAssertNil(controller.sessionRequest)
        XCTAssertEqual(controller.text, "请检查数据库结构。")

        controller.text = "请解释这个函数。"
        controller.requestPrimaryAction()
        for _ in 0..<100 where controller.sessionRequest == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let next = try XCTUnwrap(controller.sessionRequest)
        XCTAssertNotEqual(next.requestID, first.requestID)
        controller.cancel()
        XCTAssertNil(controller.requestID)
        XCTAssertNil(controller.sessionRequest)
        XCTAssertFalse(controller.busy)
    }

    @MainActor func testVisibleReplyAutomaticallyTranslatesTwoCompletedTurns() async throws {
        let settings = try isolatedSettings()
        let reverse = settings.translationPair.reverse
        let status = await LanguageAvailability().status(from: reverse.source.localeLanguage,
                                                         to: reverse.target.localeLanguage)
        try XCTSkipUnless(status == .installed, "English and Chinese system translation models are required")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalReplyStore(directory: directory.appendingPathComponent("replies"))
        let job = TerminalJob(device: 1, group: 42, startedSeconds: 67, startedMicroseconds: 89)
        let config = directory.appendingPathComponent("claude.json")
        try TerminalHookInstaller(.claude, configuration: config).update(install: true)
        let controller = InputController(
            settings: settings, hookInstaller: { TerminalHookInstaller($0, configuration: config) },
            readTerminalReply: { _ in
                guard let reply = try store.latest(for: job) else { throw TerminalReplyReader.Failure.replyUnavailable }
                return reply
            }
        )
        controller.showComposer()
        controller.showReplyMode()
        defer { controller.dismissPanel() }
        let changes = try store.observeChanges { controller.refreshLiveReply() }
        defer { changes.cancel() }

        var previousResult = ""
        let sources = [
            "# Quick check\n\n- **Open the window.**\n- Run `npm test`.\n\n```sh\nnpm test\n```",
            "# Schedule\n\n**The meeting starts tomorrow.**"
        ]
        for source in sources {
            try store.receive(TerminalHookInput(event: .finishedReply, session: "session", message: source),
                              assistant: .claude, from: job)
            for _ in 0..<60 where controller.text != source || controller.result.isEmpty {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(controller.text, source)
            XCTAssertTrue(controller.result.unicodeScalars.contains { $0.properties.isIdeographic })
            XCTAssertEqual(ReplyMarkdown(controller.result).blocks.map(\.path),
                           ReplyMarkdown(source).blocks.map(\.path))
            XCTAssertNotEqual(controller.result, previousResult)
            previousResult = controller.result
        }
    }

    @MainActor func testInFlightLiveReplyDoesNotReplaceManualClipboardReply() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("A reply chosen from the clipboard.", forType: .string))
        let started = expectation(description: "Live reply lookup started")
        let completed = expectation(description: "Live reply lookup returned")
        var pending: CheckedContinuation<Void, Never>?
        let controller = InputController(pasteboard: board, settings: try isolatedSettings(), readTerminalReply: { _ in
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
            completed.fulfill()
            return TerminalReply(assistant: .claude, text: "Stale terminal reply")
        })
        controller.showComposer()
        controller.showReplyMode()
        defer { controller.dismissPanel() }
        controller.refreshLiveReply()
        await fulfillment(of: [started], timeout: 2)
        controller.translateClipboard()
        pending?.resume()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(controller.replyOrigin, .clipboard)
        XCTAssertEqual(controller.text, "A reply chosen from the clipboard.")
    }

    @MainActor func testReverseTranslationFromClipboardAndDraftRestoration() async throws {
        let pair = TranslationPair.chineseToEnglish.reverse
        let status = await LanguageAvailability().status(from: pair.source.localeLanguage, to: pair.target.localeLanguage)
        try XCTSkipUnless(status == .installed, "Chinese and English system translation models are required")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let existingWindows = Set(NSApp.windows)
        let controller = InputController(pasteboard: board, settings: try isolatedSettings())
        controller.showComposer()
        defer { controller.dismissPanel() }
        let panel = try newFloatingPanel(excluding: existingWindows)
        let draft = "请列出文件。"
        controller.text = draft

        let reply = """
        The database stores customer orders.

        ```sql
        SELECT user_id FROM orders;
        ```

        The query lists the users who placed orders.
        """
        XCTAssertTrue(board.setString(reply, forType: .string))
        let importShortcut = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "V",
            charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9
        ))
        panel.sendEvent(importShortcut)

        XCTAssertEqual(controller.mode, .readReply)
        XCTAssertEqual(controller.text, reply)
        await waitForResult(controller)
        let translated = controller.result
        XCTAssertTrue(translated.unicodeScalars.contains { $0.properties.isIdeographic },
                      controller.message ?? "No Chinese preview")
        XCTAssertTrue(translated.contains("```sql\nSELECT user_id FROM orders;\n```"))
        XCTAssertEqual(board.string(forType: .string), reply)

        controller.requestPrimaryAction()
        XCTAssertEqual(board.string(forType: .string), translated)
        XCTAssertTrue(panel.isVisible)

        controller.showComposer()
        XCTAssertEqual(controller.mode, .compose)
        XCTAssertEqual(controller.text, draft)
        XCTAssertTrue(controller.result.isEmpty)
        await waitForResult(controller)
        XCTAssertFalse(controller.result.isEmpty)
        XCTAssertFalse(controller.result.unicodeScalars.contains { $0.properties.isIdeographic })

        XCTAssertTrue(board.setString(reply, forType: .string))
        controller.openReplyFromClipboard()
        XCTAssertEqual(controller.text, reply)
        XCTAssertEqual(controller.result, translated)
        XCTAssertFalse(controller.showsSource)
        controller.showReplySource(true)
        XCTAssertTrue(controller.showsSource)
    }

    @MainActor func testReverseTranslationSkipsCodeOnlyInput() {
        XCTAssertFalse(ProtectedPrompt("`user_id`").requiresTranslation(in: .chineseToEnglish.reverse))
        XCTAssertFalse(ProtectedPrompt("检查 `user_id`").requiresTranslation(in: .chineseToEnglish.reverse))
        XCTAssertTrue(ProtectedPrompt("Review `user_id`").requiresTranslation(in: .chineseToEnglish.reverse))
    }

    @MainActor func testLanguagePairFollowsModeAndClearsPreviousPreview() async throws {
        let suite = "InputTranslatorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = InputController(pasteboard: board, settings: AppSettings(defaults: defaults, preferredLanguage: "zh-Hans"))
        controller.text = "Review `user_id`."
        controller.requestPrimaryAction()
        XCTAssertEqual(controller.result, controller.text)

        controller.selectTargetLanguage(TranslationLanguage("ja"))
        XCTAssertEqual(controller.languagePair.target.id, "ja")
        XCTAssertTrue(controller.result.isEmpty)
        XCTAssertEqual(controller.text, "Review `user_id`.")
        XCTAssertTrue(board.setString("テストを実行してください。", forType: .string))
        controller.translateClipboard()
        XCTAssertEqual(controller.languagePair.source.id, "ja")
        XCTAssertEqual(controller.languagePair.target, TranslationPair.chineseToEnglish.source)
        controller.selectSourceLanguage(TranslationLanguage("fr"))
        XCTAssertEqual(AppSettings(defaults: defaults).translationPair,
                       TranslationPair(source: TranslationLanguage("fr"), target: TranslationLanguage("ja")))

        controller.swapLanguages()
        XCTAssertEqual(controller.languagePair.source.id, "fr")
        XCTAssertEqual(controller.languagePair.target.id, "ja")
        XCTAssertEqual(controller.text, "テストを実行してください。")
    }

    @MainActor func testReplyModePreservesComposerDraft() throws {
        let controller = InputController(settings: try isolatedSettings())
        controller.showComposer()
        defer { controller.dismissPanel() }
        controller.text = "请检查迁移脚本。"
        controller.showReplyMode()
        XCTAssertEqual(controller.mode, .readReply)
        XCTAssertTrue(controller.text.isEmpty)
        XCTAssertFalse(controller.showsSource)
        controller.showComposer()
        XCTAssertEqual(controller.mode, .compose)
        XCTAssertEqual(controller.text, "请检查迁移脚本。")
    }

    @MainActor func testNonDefaultLanguagesUseUnicodeProseAndPreserveCode() {
        let pair = TranslationPair(source: TranslationLanguage("ja"), target: TranslationLanguage("fr"))
        let prompt = ProtectedPrompt("構成を確認してください `config.toml`。")
        XCTAssertTrue(prompt.requiresTranslation(in: pair))
        XCTAssertFalse(ProtectedPrompt("`構成` 123…").requiresTranslation(in: pair))
        let translated = prompt.source.replacingOccurrences(of: "構成を確認してください", with: "Vérifiez la configuration")
        XCTAssertEqual(try prompt.restore(in: translated), "Vérifiez la configuration `config.toml`。")
    }

    @MainActor func testEmptyClipboardOpensReplyInputAndKeepsComposerDraft() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = InputController(pasteboard: board, settings: try isolatedSettings())
        controller.showComposer()
        defer { controller.dismissPanel() }
        controller.text = "检查迁移脚本。"

        controller.openReplyFromClipboard()
        XCTAssertEqual(controller.mode, .readReply)
        XCTAssertTrue(controller.showsSource)
        XCTAssertTrue(controller.showsError)
        XCTAssertTrue(controller.text.isEmpty)

        controller.toggleComposer()
        XCTAssertEqual(controller.mode, .compose)
        XCTAssertEqual(controller.text, "检查迁移脚本。")
        XCTAssertTrue(controller.showsSource)
    }

    @MainActor private func isolatedSettings() throws -> AppSettings {
        let suite = "InputTranslatorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults, preferredLanguage: "zh-Hans")
    }

    @MainActor private func waitForResult(_ controller: InputController) async {
        for _ in 0..<100 {
            if !controller.result.isEmpty || controller.showsError { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor private func newFloatingPanel(excluding existingWindows: Set<NSWindow>) throws -> FloatingPanel {
        let windows = NSApp.windows.compactMap { $0 as? FloatingPanel }
        return try XCTUnwrap(windows.first { $0.isVisible && !existingWindows.contains($0) })
    }

    @MainActor func testSettingsDefaultsAndPersistence() throws {
        let suite = "InputTranslatorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, preferredLanguage: "fr-CA")
        XCTAssertFalse(settings.automaticallySubmits(to: PasteDestination.terminal.rawValue))
        XCTAssertEqual(settings.pasteDestination, .currentApplication)
        XCTAssertTrue(settings.clearAfterPaste)
        XCTAssertTrue(settings.preserveClipboard)
        XCTAssertFalse(settings.panelPinned)
        XCTAssertTrue(settings.topDockEnabled)
        XCTAssertTrue(settings.prefersTopDock)
        XCTAssertEqual(settings.hotkey, .standard)
        XCTAssertEqual(settings.interfaceLanguage, .system)
        XCTAssertEqual(settings.translationPair.source, TranslationLanguage("fr"))
        XCTAssertEqual(settings.translationPair.target, TranslationPair.english)
        XCTAssertNil(defaults.object(forKey: "translationLanguages"))
        settings.setAutomaticallySubmits(true, to: PasteDestination.iTerm.rawValue)
        settings.pasteDestination = .iTerm
        settings.clearAfterPaste = false
        settings.preserveClipboard = false
        settings.panelPinned = true
        settings.topDockEnabled = false
        settings.panelDetached = true
        settings.interfaceLanguage = .japanese
        let hotkey = Hotkey(keyCode: 0, modifiers: 4096, keyLabel: "A")
        settings.saveHotkey(hotkey)
        let reloaded = AppSettings(defaults: defaults, preferredLanguage: "zh-HK")
        XCTAssertTrue(reloaded.automaticallySubmits(to: PasteDestination.iTerm.rawValue))
        XCTAssertEqual(reloaded.pasteDestination, .iTerm)
        XCTAssertFalse(reloaded.clearAfterPaste)
        XCTAssertFalse(reloaded.preserveClipboard)
        XCTAssertTrue(reloaded.panelPinned)
        XCTAssertFalse(reloaded.topDockEnabled)
        XCTAssertTrue(reloaded.panelDetached)
        XCTAssertFalse(reloaded.prefersTopDock)
        XCTAssertEqual(reloaded.hotkey, hotkey)
        XCTAssertEqual(reloaded.interfaceLanguage, .japanese)
        XCTAssertEqual(reloaded.translationPair.source, TranslationLanguage("zh-Hant"))
        XCTAssertEqual(reloaded.translationPair.target, TranslationPair.english)

        reloaded.translationPair = TranslationPair(source: TranslationLanguage("ar"), target: TranslationLanguage("ko"))
        let afterManualPair = AppSettings(defaults: defaults, preferredLanguage: "en-SG")
        XCTAssertEqual(afterManualPair.translationPair, reloaded.translationPair)
    }

    @MainActor func testEnglishSystemLanguageUsesCurrentTextWithoutAServiceRequest() throws {
        let suite = "InputTranslatorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, preferredLanguage: "en-GB")
        let english = TranslationPair.english
        XCTAssertEqual(settings.translationPair, TranslationPair(source: english, target: english))
        let controller = InputController(settings: settings)
        controller.text = "Review `user_id`."
        controller.requestPrimaryAction()
        XCTAssertEqual(controller.result, controller.text)
        XCTAssertNil(controller.requestID)
    }

    @MainActor func testReopenPreservesTheEarlierRedockPreferenceAfterUpgrade() throws {
        let suite = "InputTranslatorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(AppSettings(defaults: defaults).dockedBesideLauncher)
        defaults.set(false, forKey: "dockedBesideLauncher")
        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.dockedBesideLauncher)
        restored.dockedBesideLauncher = true
        defaults.removeObject(forKey: "dockedBesideLauncher")
        XCTAssertTrue(AppSettings(defaults: defaults).dockedBesideLauncher)
    }

    @MainActor func testDockMorphExpandsTheCapsuleAndCancelsBackToItsExactFrame() async throws {
        let settings = try isolatedSettings()
        let controller = InputController(settings: settings)
        let panel = FloatingPanel(controller: controller)
        let layout = try XCTUnwrap(NSScreen.main).topDockLayout
        panel.applyTopDock(layout)
        let restingFrame = panel.frame
        let launcher = TopDockPanel(action: {})
        launcher.show(at: layout, expanded: false)
        defer {
            launcher.cancelMorph()
            launcher.orderOut(nil)
            panel.orderOut(nil)
        }

        var frames = [NSRect]()
        let opened = expectation(description: "Dock morph opened")
        launcher.animate(layout: layout, panelFrame: restingFrame, opening: true) { _ in
            frames.append(launcher.frame)
        } completion: { opened.fulfill() }
        await fulfillment(of: [opened], timeout: 1)
        XCTAssertEqual(frames.first, layout.launcherFrame)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(frames.last, restingFrame)
            XCTAssertTrue(frames.contains { $0.width > layout.launcherFrame.width && $0.width < restingFrame.width })
            XCTAssertTrue(frames.contains { $0.height > layout.launcherFrame.height && $0.height < restingFrame.height })
        }
        XCTAssertEqual(panel.frame, restingFrame)

        let closed = expectation(description: "Canceled morph did not complete")
        closed.isInverted = true
        launcher.animate(layout: layout, panelFrame: restingFrame, opening: false, onChange: { _ in }) {
            closed.fulfill()
        }
        launcher.cancelMorph()
        await fulfillment(of: [closed], timeout: 0.4)
        XCTAssertNil(launcher.activeLayout)
        XCTAssertEqual(launcher.frame, layout.launcherFrame)
        XCTAssertEqual(launcher.alphaValue, 1, accuracy: 0.001)
        XCTAssertFalse(launcher.ignoresMouseEvents)

        let collapsed = expectation(description: "The same capsule remains visible at the end of the close animation")
        launcher.animate(layout: layout, panelFrame: restingFrame, opening: false, onChange: { _ in }) {
            XCTAssertTrue(launcher.isVisible)
            XCTAssertEqual(launcher.frame, layout.launcherFrame)
            XCTAssertEqual(launcher.alphaValue, 1, accuracy: 0.001)
            collapsed.fulfill()
        }
        await fulfillment(of: [collapsed], timeout: 1)
    }

    @MainActor func testAdjacentDockMorphGrowsAndShrinksFromBothCapsuleEdges() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let launcher = TopDockPanel(action: {})
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        defer {
            launcher.cancelMorph()
            launcher.orderOut(nil)
        }

        for opensAbove in [false, true] {
            let visible = screen.visibleFrame
            let placement = opensAbove ? PinnedPanelPlacement(
                frame: NSRect(origin: NSPoint(x: visible.minX + 5, y: visible.minY + 5),
                              size: TopDockLayout.launcherSize),
                screenFrame: visible, displayNumber: screen.displayNumber
            ) : nil
            let layout = screen.topDockLayout(launcherPlacement: placement)
            let capsule = layout.launcherFrame
            let panel = layout.panelFrame(size: NSSize(width: 580, height: 350), besideLauncher: true)
            launcher.show(at: layout, expanded: false)

            for opening in [true, false] {
                var frames = [NSRect]()
                var opacity = [CGFloat]()
                let finished = expectation(description: "The adjacent window completed its dock animation")
                launcher.animate(layout: layout, panelFrame: panel, opening: opening, besideLauncher: true) { alpha in
                    XCTAssertEqual(launcher.frame, capsule)
                    XCTAssertEqual(launcher.alphaValue, 1)
                    XCTAssertFalse(launcher.ignoresMouseEvents)
                    if let surface = launcher.adjacentSurface {
                        XCTAssertTrue(surface.ignoresMouseEvents)
                        frames.append(surface.frame)
                    }
                    opacity.append(alpha)
                } completion: { finished.fulfill() }
                await fulfillment(of: [finished], timeout: 1)

                XCTAssertTrue(launcher.isVisible)
                XCTAssertFalse(launcher.adjacentSurface?.isVisible ?? false)
                XCTAssertEqual(opacity.first, opening ? 0 : 1)
                XCTAssertEqual(opacity.last, opening ? 1 : 0)
                if reduceMotion {
                    XCTAssertTrue(frames.isEmpty)
                    continue
                }
                let collapsed = try XCTUnwrap(opening ? frames.first : frames.last)
                XCTAssertEqual(opensAbove ? collapsed.minY : collapsed.maxY,
                               opensAbove ? capsule.maxY : capsule.minY, accuracy: 1)
                XCTAssertEqual(collapsed.height, 1, accuracy: 0.5)
                XCTAssertEqual(collapsed.midX, capsule.midX, accuracy: 1)
                XCTAssertEqual(opening ? frames.last : frames.first, panel)
                XCTAssertTrue(frames.allSatisfy { opensAbove ? $0.minY >= capsule.maxY : $0.maxY <= capsule.minY })
                XCTAssertTrue(frames.contains { $0.width > collapsed.width && $0.width < panel.width
                                              && $0.height > collapsed.height && $0.height < panel.height })
            }
        }
    }

    @MainActor func testAdjacentDockMorphReversesFromTheCurrentFrame() async throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            throw XCTSkip("This check samples the shape animation.")
        }
        let layout = try XCTUnwrap(NSScreen.main).topDockLayout
        let panel = layout.panelFrame(size: NSSize(width: 580, height: 350), besideLauncher: true)
        let launcher = TopDockPanel(action: {})
        launcher.show(at: layout, expanded: false)
        defer {
            launcher.cancelMorph()
            launcher.orderOut(nil)
        }
        let intermediate = expectation(description: "The surface reached an intermediate frame")
        let canceled = expectation(description: "The original opening completion is canceled")
        canceled.isInverted = true
        var reachedIntermediateFrame = false
        launcher.animate(layout: layout, panelFrame: panel, opening: true, besideLauncher: true) { _ in
            if !reachedIntermediateFrame, let height = launcher.adjacentSurface?.frame.height, height > 30 {
                reachedIntermediateFrame = true
                intermediate.fulfill()
            }
        } completion: { canceled.fulfill() }
        await fulfillment(of: [intermediate], timeout: 1)

        let surface = try XCTUnwrap(launcher.adjacentSurface)
        let previousFrame = surface.frame
        XCTAssertLessThan(previousFrame.height, panel.height)
        let reversed = expectation(description: "The surface collapsed after reversing")
        launcher.animate(layout: layout, panelFrame: panel, opening: false, besideLauncher: true) { _ in
            XCTAssertTrue(launcher.isVisible)
            XCTAssertEqual(launcher.frame, layout.launcherFrame)
        } completion: { reversed.fulfill() }
        XCTAssertEqual(surface.frame, previousFrame)
        XCTAssertTrue(surface.isVisible)
        await fulfillment(of: [reversed, canceled], timeout: 0.5)
        XCTAssertFalse(surface.isVisible)
    }

    @MainActor func testPinKeepsPanelVisibleAfterDismissAndRestoresWithoutFocus() throws {
        let suite = "InputTranslatorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existingWindows = Set(NSApp.windows)
        let settings = AppSettings(defaults: defaults)
        settings.topDockEnabled = false
        let controller = InputController(settings: settings)
        controller.togglePanelPin()
        defer { controller.dismissPanel() }

        let panel = try newFloatingPanel(excluding: existingWindows)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(panel.level, .floating)

        let visible = try XCTUnwrap(panel.screen?.visibleFrame)
        let newSize = NSSize(width: 528, height: 308)
        panel.setContentSize(newSize)
        XCTAssertEqual(AppSettings(defaults: defaults).pinnedPanelPlacement?.frame, panel.frame)
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width, y: visible.maxY - panel.frame.height))
        let pinnedFrame = panel.frame
        XCTAssertEqual(panel.contentRect(forFrameRect: pinnedFrame).size, newSize)
        XCTAssertEqual(AppSettings(defaults: defaults).pinnedPanelPlacement?.frame, pinnedFrame)

        controller.dismissPanel(keepPinned: true)
        XCTAssertTrue(panel.isVisible)
        panel.performClose(nil)
        XCTAssertFalse(panel.isVisible)

        let restarted = InputController(settings: AppSettings(defaults: defaults))
        restarted.restorePinnedPanel()
        defer { restarted.dismissPanel() }
        let restored = try newFloatingPanel(excluding: existingWindows.union([panel]))
        XCTAssertFalse(restored.isKeyWindow)
        XCTAssertFalse(restored.hidesOnDeactivate)
        XCTAssertEqual(restored.frame, pinnedFrame)
        restarted.togglePanelPin()
        XCTAssertTrue(restored.hidesOnDeactivate)
        XCTAssertTrue(restored.collectionBehavior.contains(.moveToActiveSpace))
        restored.setFrameOrigin(NSPoint(x: visible.minX + 32, y: visible.minY + 32))
        XCTAssertEqual(AppSettings(defaults: defaults).pinnedPanelPlacement?.frame, pinnedFrame)
    }

    @MainActor func testDefaultTopDockPreservesExistingPinnedFloatingPlacement() throws {
        let suite = "InputTranslatorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.panelPinned = true
        let placement = PinnedPanelPlacement(
            frame: NSRect(x: 50, y: 100, width: 540, height: 320),
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 950),
            displayNumber: nil
        )
        settings.savePanelPlacement(placement, docked: false)

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.topDockEnabled)
        XCTAssertTrue(restored.panelDetached)
        XCTAssertEqual(restored.pinnedPanelPlacement, placement)
    }

    func testTopDockUsesCameraPositionAndFitsTheVisibleScreen() {
        let screen = NSRect(x: -1000, y: 0, width: 1000, height: 800)
        let visible = NSRect(x: -980, y: 45, width: 980, height: 719)
        let notch = TopDockLayout(visibleFrame: visible, screenFrame: screen,
                                  topLeft: NSRect(x: -1000, y: 764, width: 520, height: 36),
                                  topRight: NSRect(x: -360, y: 764, width: 360, height: 36))
        XCTAssertEqual(notch.launcherFrame.midX, -420)
        XCTAssertLessThan(notch.launcherFrame.maxY, visible.maxY)
        let fitted = notch.panelFrame(size: NSSize(width: 1200, height: 900))
        XCTAssertTrue(visible.contains(fitted))
        let regular = notch.panelFrame(size: NSSize(width: 580, height: 350))
        XCTAssertEqual(regular.maxY, notch.launcherFrame.maxY)

        let movedFrame = NSRect(origin: NSPoint(x: -215, y: 63), size: TopDockLayout.launcherSize)
        let saved = PinnedPanelPlacement(frame: movedFrame, screenFrame: visible, displayNumber: 1)
        let moved = TopDockLayout(visibleFrame: visible, screenFrame: screen, topLeft: nil, topRight: nil,
                                  launcherPlacement: saved)
        let movedPanel = moved.panelFrame(size: regular.size)
        XCTAssertEqual(moved.launcherFrame, movedFrame)
        XCTAssertTrue(visible.contains(movedPanel))
        XCTAssertTrue(movedPanel.contains(moved.launcherFrame))
        let below = notch.panelFrame(size: regular.size, besideLauncher: true)
        XCTAssertEqual(below.maxY, notch.launcherFrame.minY - 5)
        XCTAssertTrue(visible.contains(below))
        let above = moved.panelFrame(size: regular.size, besideLauncher: true)
        XCTAssertEqual(above.minY, moved.launcherFrame.maxY + 5)
        XCTAssertEqual(above.size, regular.size)
        XCTAssertTrue(visible.contains(above))
        let flat = TopDockLayout(visibleFrame: visible, screenFrame: screen, topLeft: nil, topRight: nil)
        XCTAssertEqual(flat.launcherFrame.midX, screen.midX)
    }

    @MainActor func testDockPasteFeedbackClearsOnOpenAndExpiresWithoutFocus() async throws {
        let layout = try XCTUnwrap(NSScreen.main).topDockLayout
        let launcher = TopDockPanel(action: {})
        launcher.show(at: layout, expanded: false)
        defer { launcher.orderOut(nil) }
        let frame = launcher.frame

        launcher.acknowledgePaste(submitted: false)
        XCTAssertEqual(launcher.pasteFeedback, L10n.text("已粘贴"))
        XCTAssertEqual(launcher.frame, frame)
        XCTAssertFalse(launcher.isKeyWindow)
        launcher.show(at: layout, expanded: true)
        XCTAssertNil(launcher.pasteFeedback)

        launcher.show(at: layout, expanded: false)
        launcher.acknowledgePaste(submitted: true)
        XCTAssertEqual(launcher.pasteFeedback, L10n.text("已提交"))
        for _ in 0..<30 where launcher.pasteFeedback != nil {
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertNil(launcher.pasteFeedback)
        XCTAssertFalse(launcher.isKeyWindow)
    }

    func testPinnedPanelPlacementFitsAnotherDisplay() {
        let placement = PinnedPanelPlacement(
            frame: NSRect(x: -610, y: 448, width: 600, height: 400),
            screenFrame: NSRect(x: -1440, y: 0, width: 1440, height: 860),
            displayNumber: 2
        )
        let replacement = NSRect(x: 0, y: 32, width: 1024, height: 640)
        XCTAssertEqual(placement.restoredFrame(in: replacement), NSRect(x: 414, y: 260, width: 600, height: 400))
        let smaller = NSRect(x: 0, y: 32, width: 580, height: 420)
        XCTAssertEqual(placement.restoredFrame(in: smaller), NSRect(x: 0, y: 40, width: 580, height: 400))
    }
}

private extension TranslationPair {
    static let chineseToEnglish = Self(source: TranslationLanguage("zh-Hans"), target: english)
}
