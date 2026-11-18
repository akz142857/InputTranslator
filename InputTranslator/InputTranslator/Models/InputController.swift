import AppKit
import Combine
import OSLog
import SwiftUI
import Translation

@MainActor
final class InputController: ObservableObject {
    private struct Request {
        nonisolated enum Input: Sendable {
            case prompt(ProtectedPrompt)
            case reply(ReplyMarkdown, [Range<String.Index>])
        }

        let id = UUID()
        let input: Input
        let pair: TranslationPair
        var availability: LanguageAvailability.Status?
        var hasRetried = false
    }

    struct SessionRequest: Identifiable {
        let id = UUID()
        let requestID: UUID
        let configuration: TranslationSession.Configuration
    }

    private struct Draft {
        let text: String
        let translation: String
        let pair: TranslationPair
    }

    private struct Delivery {
        let target: TerminalTarget
        let text: String
        let autoSubmit: Bool
    }

    enum ReplyRecovery: Equatable { case connections, automation }
    enum ReplyOrigin: Equatable {
        case clipboard, terminal(String?)

        var title: String {
            switch self {
            case .clipboard: L10n.text("剪贴板")
            case .terminal(let name): name ?? L10n.text("终端会话")
            }
        }

        var symbol: String {
            switch self {
            case .clipboard: "clipboard"
            case .terminal: "terminal"
            }
        }
    }
    private enum State {
        case idle, waiting, translating, preview, confirmation(Delivery), pasting, pastePosted
        case error(Error, recovery: ReplyRecovery?), notice(LocalizedMessage)
    }

    private enum AssistantReplyFailure: LocalizedError {
        case connections, unconfigured(TerminalAssistant)

        var errorDescription: String? {
            switch self {
            case .connections: L10n.text("请先在设置中连接一个终端助手。")
            case .unconfigured(let assistant): L10n.text("请检查 %@ 的接入配置。", assistant.name)
            }
        }
    }

    private let logger = Logger(subsystem: "com.claycosmos.InputTranslator", category: "workflow")
    let updater = AppUpdater()
    let settings: AppSettings
    @Published var hotkeyMessage: LocalizedMessage?
    @Published var settingsPane = SettingsPane.general
    @Published private(set) var hookStatuses: [TerminalAssistant: TerminalHookInstaller.Status] = [:]
    @Published private(set) var hookMessages: [TerminalAssistant: Error] = [:]
    var onOpenSettings: (() -> Void)?
    var onOpenConnections: (() -> Void)?
    var onInterfaceLanguageChange: (() -> Void)?
    @Published var replyShortcutAvailable = false
    @Published var loginMessage: LocalizedMessage?
    @Published var text = "" {
        didSet {
            guard text != oldValue, !isDelivering, !isSwitchingMode else { return }
            if mode == .readReply { replyOrigin = nil }
            resetPreview()
        }
    }
    @Published private(set) var result = ""
    @Published private(set) var mode = TranslationMode.compose
    @Published private(set) var supportedLanguages: [TranslationLanguage]
    @Published private var revealsReplySource = false
    @Published private(set) var isEditingReplySource = false
    @Published private(set) var replyOrigin: ReplyOrigin?
    @Published private(set) var targetName: String?
    @Published private(set) var hasAccessibilityAccess = false
    @Published private(set) var sessionRequest: SessionRequest?
    var requestID: UUID? { request?.id }

    @Published private var state = State.idle
    private var request: Request?
    private var target: TerminalTarget?
    private var previousApp: NSRunningApplication?
    private var lastReplyTerminal: NSRunningApplication?
    private var panel: FloatingPanel?
    private var topDock: TopDockPanel?
    private var topDockDisplayNumber: UInt32?
    private var debounce: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    @Published private(set) var isComposing = false
    private var drafts: [TranslationMode: Draft] = [:]
    private var isSwitchingMode = false
    private let pasteboard: NSPasteboard
    private let hookInstaller: (TerminalAssistant) -> TerminalHookInstaller
    private let readTerminalReply: @MainActor (NSRunningApplication?) async throws -> TerminalReply
    private var replyReadTask: Task<Void, Never>?
    private var liveReplyTask: Task<Void, Never>?
    private var liveReplyPending = false
    private var performActionWhenReady = false
    private var timeout: Task<Void, Never>?
    private var activeSession: TranslationSession?
    private let translationResponseTimeout: Duration
    private var languageCheck: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?

    init(
        pasteboard: NSPasteboard = .general,
        settings: AppSettings? = nil,
        hookInstaller: @escaping (TerminalAssistant) -> TerminalHookInstaller = { TerminalHookInstaller($0) },
        readTerminalReply: @escaping @MainActor (NSRunningApplication?) async throws -> TerminalReply = {
            try await TerminalReplyReader.latest(in: $0)
        },
        translationResponseTimeout: Duration = .seconds(15)
    ) {
        self.pasteboard = pasteboard
        let activeSettings = settings ?? AppSettings()
        self.settings = activeSettings
        let pair = activeSettings.translationPair
        supportedLanguages = Array(Set([pair.source, pair.target]))
        self.hookInstaller = hookInstaller
        self.readTerminalReply = readTerminalReply
        self.translationResponseTimeout = translationResponseTimeout
    }

    var busy: Bool {
        switch state {
        case .translating, .pasting, .pastePosted: true
        default: false
        }
    }

    var isDelivering: Bool {
        switch state {
        case .pasting, .pastePosted: true
        default: false
        }
    }

    var canCancel: Bool {
        switch state {
        case .translating, .pasting: true
        default: false
        }
    }

    var isConfirming: Bool {
        if case .confirmation = state { return true }
        return false
    }

    var willSubmitPrompt: Bool {
        settings.autoSubmit && !PasteService.requiresConfirmation(text: text)
            && !PasteService.requiresConfirmation(text: result)
    }

    var message: String? {
        switch state {
        case .idle, .waiting: nil
        case .translating: request?.availability == .supported ? L10n.text("正在准备语言包…") : L10n.text("正在翻译…")
        case .preview: nil
        case .confirmation:
            L10n.text("请确认 %@ 中的助手能接收多行粘贴。", targetName ?? L10n.text("当前终端"))
        case .pasting, .pastePosted: L10n.text("正在向终端粘贴…")
        case .error(let error, _): error.localizedDescription
        case .notice(let message): message.text
        }
    }

    var showsError: Bool {
        if case .error = state { return true }
        return false
    }

    var offersAccessibilitySettings: Bool {
        if !hasAccessibilityAccess { return true }
        guard case .error(let error, _) = state, let failure = error as? TerminalFailure else { return false }
        return failure == .permission || failure == .unavailable
    }

    var replyRecovery: ReplyRecovery? {
        if case .error(_, let recovery) = state { return recovery }
        return nil
    }

    func refreshHookConnections() {
        for assistant in TerminalAssistant.allCases {
            do {
                hookStatuses[assistant] = try hookInstaller(assistant).status()
                hookMessages[assistant] = nil
            } catch {
                hookStatuses[assistant] = .unavailable
                hookMessages[assistant] = error
            }
        }
    }

    func updateHooks(for assistant: TerminalAssistant, install: Bool) {
        do {
            try hookInstaller(assistant).update(install: install)
            refreshHookConnections()
            if install, hookStatuses[assistant] == .configured, replyRecovery == .connections {
                state = .notice(LocalizedMessage("等助手回复完成后自动翻译。"))
            }
        } catch {
            hookMessages[assistant] = error
        }
    }

    var canSwitchMode: Bool { !isDelivering && !isConfirming && !isComposing }
    var canPerformAction: Bool { canSwitchMode && !text.allSatisfy(\.isWhitespace) }
    var showsSource: Bool { mode == .compose || revealsReplySource }
    var showsEditor: Bool { mode == .compose || (revealsReplySource && (isEditingReplySource || text.isEmpty)) }
    var languagePair: TranslationPair {
        mode == .compose ? settings.translationPair : settings.translationPair.reverse
    }

    func selectInterfaceLanguage(_ language: InterfaceLanguage) {
        guard language != settings.interfaceLanguage else { return }
        settings.interfaceLanguage = language
        topDock?.refreshLanguage()
        onInterfaceLanguageChange?()
    }

    func loadSupportedLanguages() async {
        let available = await LanguageAvailability().supportedLanguages.map(TranslationLanguage.init)
        guard !Task.isCancelled else { return }
        let pair = settings.translationPair
        supportedLanguages = Array(Set(available + [pair.source, pair.target]))
    }

    func selectSourceLanguage(_ source: TranslationLanguage) {
        setLanguagePair(TranslationPair(source: source, target: settings.translationPair.target))
    }

    func selectTargetLanguage(_ target: TranslationLanguage) {
        setLanguagePair(TranslationPair(source: settings.translationPair.source, target: target))
    }

    func swapLanguages() {
        setLanguagePair(settings.translationPair.reverse)
    }

    private func setLanguagePair(_ pair: TranslationPair) {
        guard canSwitchMode, pair.isSelectable, pair != settings.translationPair else { return }
        settings.translationPair = pair
        resetPreview()
    }

    func showReplySource(_ visible: Bool) {
        guard mode == .readReply, canSwitchMode, visible != revealsReplySource else { return }
        revealsReplySource = visible
        if !visible { isEditingReplySource = false }
    }

    func toggleReplySourceEditing() {
        guard mode == .readReply, revealsReplySource, canSwitchMode else { return }
        cancelReplyReads()
        isEditingReplySource.toggle()
        if isEditingReplySource { panel?.focusEditor() }
    }

    func translateClipboard() {
        guard canSwitchMode else { return }
        cancelReplyReads()
        guard let copied = pasteboard.string(forType: .string),
              !copied.allSatisfy(\.isWhitespace) else {
            if mode != .readReply {
                selectMode(.readReply)
            }
            clearPendingTranslation()
            if text.isEmpty {
                revealsReplySource = true
                isEditingReplySource = true
            }
            showError(TranslationFailure.emptyClipboard)
            return
        }
        displayReply(copied, origin: .clipboard)
    }

    private func displayReply(_ reply: String, origin: ReplyOrigin, preserveSourceView: Bool = false) {
        replyOrigin = origin
        if !preserveSourceView {
            revealsReplySource = false
            isEditingReplySource = false
        }
        if mode == .readReply, text == reply, !result.isEmpty {
            state = .preview
            return
        }
        selectMode(.readReply, replacingWith: reply)
    }

    private func selectMode(_ next: TranslationMode, replacingWith replacement: String? = nil) {
        if next != mode {
            cancelReplyReads()
            drafts[mode] = Draft(text: text, translation: result, pair: languagePair)
            isEditingReplySource = false
        }
        let draft = drafts[next]
        isSwitchingMode = true
        mode = next
        text = replacement ?? draft?.text ?? ""
        isSwitchingMode = false
        resetPreview(reusing: text == draft?.text && draft?.pair == languagePair ? draft?.translation ?? "" : "")
    }

    func updateComposition(_ composing: Bool) {
        guard isComposing != composing else { return }
        isComposing = composing
        resetPreview()
    }

    private func resetPreview(reusing translation: String = "") {
        clearPendingTranslation()
        result = translation
        state = translation.isEmpty ? .idle : .preview
        schedulePreview()
    }

    private func schedulePreview() {
        guard panel?.isVisible == true, canPerformAction, result.isEmpty, request == nil,
              debounce == nil, preparation == nil else { return }
        state = .waiting
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            guard self.panel?.isVisible == true, self.canPerformAction else { return }
            self.beginTranslation()
        }
    }

    func toggleComposer() {
        if panel?.isKeyWindow == true, mode == .compose {
            dismissPanel(keepPinned: true)
        } else {
            showComposer()
        }
    }

    func showComposer() {
        if mode != .compose {
            guard canSwitchMode else { return }
            selectMode(.compose)
        }
        showPanel()
        panel?.focusEditor()
    }

    func openReplyFromClipboard() {
        translateClipboard()
        showPanel()
    }

    private var replyTerminal: NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, TerminalChoice.matches(frontmost.bundleIdentifier) { return frontmost }
        guard panel?.isKeyWindow == true || (settings.panelPinned && panel?.isVisible == true) else {
            return nil
        }
        if let previousApp, !previousApp.isTerminated, TerminalChoice.matches(previousApp.bundleIdentifier) {
            return previousApp
        }
        guard let lastReplyTerminal, !lastReplyTerminal.isTerminated else { return nil }
        return lastReplyTerminal
    }

    func showReplyMode() {
        guard canSwitchMode, mode != .readReply else { return }
        if TerminalChoice.matches(replyTerminal?.bundleIdentifier) {
            openLatestTerminalReply()
        } else {
            revealsReplySource = false
            selectMode(.readReply)
            showPanel()
        }
    }

    func openLatestTerminalReply() {
        guard canSwitchMode, replyReadTask == nil else { return }
        let terminal = replyTerminal
        if mode != .readReply {
            selectMode(.readReply)
            revealsReplySource = false
        }
        showPanel(originalApp: terminal)
        liveReplyTask?.cancel()
        liveReplyTask = nil
        liveReplyPending = false
        replyReadTask = Task { [weak self] in
            guard let self else { return }
            await self.readRequestedReply(in: terminal)
            if !Task.isCancelled {
                self.replyReadTask = nil
                if self.liveReplyPending {
                    self.liveReplyPending = false
                    self.refreshLiveReply()
                }
            }
        }
    }

    private func readRequestedReply(in terminal: NSRunningApplication?) async {
        do {
            guard let terminal else { throw TerminalReplyReader.Failure.terminalRequired }
            lastReplyTerminal = terminal
            refreshHookConnections()
            guard hookStatuses.values.contains(.configured) else { throw AssistantReplyFailure.connections }
            let reply = try await readTerminalReply(terminal)
            guard !Task.isCancelled, self.replyTerminal?.processIdentifier == terminal.processIdentifier else { return }
            guard hookStatuses[reply.assistant] == .configured else {
                throw AssistantReplyFailure.unconfigured(reply.assistant)
            }
            displayReply(reply.text, origin: .terminal(terminal.localizedName))
        } catch {
            guard !Task.isCancelled, terminal?.processIdentifier == self.replyTerminal?.processIdentifier else { return }
            clearPendingTranslation()
            let terminalFailure = error as? TerminalReplyReader.Failure
            if terminalFailure == .automation {
                showError(error, recovery: .automation)
            } else if terminalFailure == .replyUnavailable {
                state = .notice(LocalizedMessage("等助手回复完成后自动翻译。"))
            } else if error is AssistantReplyFailure {
                showError(error, recovery: .connections)
            } else {
                showError(error)
            }
        }
    }

    func refreshLiveReply(in preferredTerminal: NSRunningApplication? = nil) {
        guard canRefreshLiveReply else { return }
        guard replyReadTask == nil, liveReplyTask == nil else {
            liveReplyPending = true
            return
        }
        liveReplyTask = Task { [weak self] in
            // Creating and renaming one cache file can deliver several directory notifications.
            try? await Task.sleep(for: .milliseconds(75))
            guard let self, !Task.isCancelled else { return }
            self.liveReplyPending = false
            await self.readLiveReply(in: preferredTerminal ?? self.replyTerminal)
            guard !Task.isCancelled else { return }
            self.liveReplyTask = nil
            if self.liveReplyPending {
                self.liveReplyPending = false
                self.refreshLiveReply()
            }
        }
    }

    private var canRefreshLiveReply: Bool {
        guard mode == .readReply, panel?.isVisible == true, panel?.isClosingFromDock == false,
              canSwitchMode, !isEditingReplySource, replyRecovery == nil else { return false }
        if case .terminal = replyOrigin { return true }
        return replyOrigin == nil && text.isEmpty
    }

    private func readLiveReply(in terminal: NSRunningApplication?) async {
        guard canRefreshLiveReply, let reply = try? await readTerminalReply(terminal), !Task.isCancelled,
              canRefreshLiveReply, terminal?.processIdentifier == replyTerminal?.processIdentifier else { return }
        let origin = ReplyOrigin.terminal(terminal?.localizedName)
        guard replyOrigin != origin || text != reply.text else { return }
        let installer = hookInstaller(reply.assistant)
        let isConfigured = await Task.detached { (try? installer.status()) == .configured }.value
        guard isConfigured, !Task.isCancelled, canRefreshLiveReply,
              terminal?.processIdentifier == replyTerminal?.processIdentifier else { return }
        lastReplyTerminal = terminal
        displayReply(reply.text, origin: origin, preserveSourceView: replyOrigin != nil)
    }

    private func cancelReplyReads() {
        replyReadTask?.cancel()
        replyReadTask = nil
        liveReplyTask?.cancel()
        liveReplyTask = nil
        liveReplyPending = false
    }

    func restorePinnedPanel() {
        refreshTopDock()
        guard settings.panelPinned else { return }
        showPanel(activating: false)
    }

    func savePanelPlacement() {
        panel?.savePlacement()
    }

    func setTopDockEnabled(_ enabled: Bool) {
        guard settings.topDockEnabled != enabled else { return }
        savePanelPlacement()
        settings.topDockEnabled = enabled
        refreshTopDock()
    }

    func toggleTopDockPlacement() {
        guard settings.topDockEnabled, canSwitchMode else { return }
        if settings.prefersTopDock {
            savePanelPlacement()
            settings.panelDetached = true
            refreshTopDock()
        } else {
            dockPanel(on: nil)
        }
    }

    func detachTopDockForDrag() {
        guard settings.prefersTopDock else { return }
        settings.panelDetached = true
        refreshTopDock(restoreFloating: false)
    }

    func dockPanel(on screen: NSScreen?) {
        guard settings.topDockEnabled else { return }
        savePanelPlacement()
        settings.dockedBesideLauncher = true
        settings.panelDetached = false
        refreshTopDock(on: screen)
    }

    func topDockLayout(on screen: NSScreen) -> TopDockLayout {
        let saved = settings.topDockLauncherPlacement
        let placement = saved.flatMap { position in
            let sameDisplay = position.displayNumber == screen.displayNumber || position.screenFrame == screen.visibleFrame
            return sameDisplay ? position : nil
        }
        return screen.topDockLayout(launcherPlacement: placement)
    }

    func refreshTopDock(on screen: NSScreen? = nil, restoreFloating: Bool = true) {
        guard settings.topDockEnabled else {
            let wasClosing = panel?.isClosingFromDock == true
            cancelDockMorph()
            topDock?.orderOut(nil)
            panel?.applyTopDock(nil)
            if wasClosing { dismissPanel() }
            return
        }
        let screens = NSScreen.screens
        let saved = settings.topDockLauncherPlacement ?? settings.dockedPanelPlacement
        let number = topDockDisplayNumber ?? saved?.displayNumber
        let matching = number.flatMap { number in screens.first { $0.displayNumber == number } }
        guard let display = screen ?? matching ?? screens.first(where: { $0.visibleFrame == saved?.screenFrame })
                ?? NSScreen.underPointer else { return }
        topDockDisplayNumber = display.displayNumber
        let layout = topDockLayout(on: display)
        let docked = settings.prefersTopDock ? layout : nil
        if let activeLayout = topDock?.activeLayout, activeLayout != docked {
            let wasClosing = panel?.isClosingFromDock == true
            cancelDockMorph()
            if wasClosing {
                dismissPanel()
                return
            }
        }
        panel?.applyTopDock(docked, besideLauncher: docked != nil && settings.dockedBesideLauncher,
                            restoreFloating: restoreFloating)
        if topDock == nil {
            topDock = TopDockPanel(action: { [weak self] in self?.toggleTopDockPanel() },
                                  onMove: { [weak self] frame, screen in self?.moveTopDockLauncher(frame, on: screen) },
                                  onResetPosition: { [weak self] in self?.resetTopDockLauncherPosition() })
        }
        guard topDock?.activeLayout == nil else { return }
        if docked != nil, !settings.dockedBesideLauncher, panel?.isVisible == true {
            topDock?.orderOut(nil)
        } else {
            topDock?.show(at: layout, expanded: panel?.isVisible == true)
        }
    }

    private func moveTopDockLauncher(_ frame: NSRect, on screen: NSScreen) {
        settings.saveTopDockLauncherPlacement(PinnedPanelPlacement(
            frame: frame, screenFrame: screen.visibleFrame, displayNumber: screen.displayNumber
        ))
        refreshTopDock(on: screen)
    }

    private func resetTopDockLauncherPosition() {
        settings.saveTopDockLauncherPlacement(nil)
        refreshTopDock(on: topDock?.screen)
    }

    private func toggleTopDockPanel() {
        guard !isDelivering else { return }
        if panel?.isClosingFromDock == true {
            if settings.dockedBesideLauncher, animateDockPanel(opening: true) {
                schedulePreview()
            } else {
                showPanel()
            }
        } else if panel?.isVisible == true {
            dismissPanel(animateFromDock: true)
        } else {
            showPanel(animateFromDock: true)
            refreshLiveReply()
        }
    }

    @discardableResult
    private func animateDockPanel(opening: Bool) -> Bool {
        guard let panel, let topDock, let layout = panel.dockLayout else { return false }
        panel.beginDockMotion(opening: opening)
        topDock.animate(layout: layout, panelFrame: panel.frame, opening: opening,
                        besideLauncher: settings.dockedBesideLauncher) { [weak panel] opacity in
            panel?.alphaValue = max(0.01, opacity)
        } completion: { [weak self, weak panel] in
            if opening {
                panel?.finishDockMotion()
                self?.refreshTopDock()
            } else {
                self?.dismissPanel()
            }
        }
        return true
    }

    private func cancelDockMorph() {
        guard topDock?.activeLayout != nil else { return }
        topDock?.cancelMorph(keepLauncherVisible: settings.topDockEnabled && settings.dockedBesideLauncher)
        panel?.finishDockMotion()
    }

    func topDockPanelResignedKey() {
        guard shouldCollapseUnfocusedPanel else { return }
        Task { @MainActor [weak self] in
            guard let self, self.shouldCollapseUnfocusedPanel, self.panel?.isKeyWindow == false else { return }
            self.dismissPanel()
        }
    }

    private var shouldCollapseUnfocusedPanel: Bool {
        // A system download sheet can temporarily take key focus from the floating panel.
        settings.topDockEnabled && !settings.panelPinned && !isDelivering && request?.availability != .supported
    }

    func togglePanelPin() {
        settings.panelPinned.toggle()
        panel?.applyPin(settings.panelPinned)
        if settings.panelPinned {
            if panel?.isVisible != true { restorePinnedPanel() }
        } else if !NSApp.isActive {
            dismissPanel()
        }
    }

    func pinnedPanelBecameKey() {
        guard settings.panelPinned, !isDelivering else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let source = frontmost == NSRunningApplication.current ? previousApp : frontmost
        captureTerminalTarget(from: source)
    }

    func activeApplicationChanged(to app: NSRunningApplication) {
        guard settings.panelPinned, panel?.isVisible == true, app != NSRunningApplication.current else { return }
        previousApp = app
        refreshPermission()
        targetName = compatibleTerminal(app)?.localizedName
        target = nil
        performActionWhenReady = false
        cancelConfirmation()
        if TerminalChoice.matches(app.bundleIdentifier) { refreshLiveReply(in: app) }
    }

    private func showPanel(originalApp: NSRunningApplication? = nil, activating: Bool = true, animateFromDock: Bool = false) {
        if panel?.isClosingFromDock == true {
            cancelDockMorph()
            refreshTopDock()
        }
        guard panel?.isKeyWindow != true, !isDelivering else { return }
        let frontmost = originalApp ?? NSWorkspace.shared.frontmostApplication
        captureTerminalTarget(from: frontmost)
        cancelConfirmation()
        if panel == nil {
            panel = FloatingPanel(controller: self)
        }
        refreshTopDock()
        if animateFromDock, activating, panel?.isVisible == false { animateDockPanel(opening: true) }
        panel?.present(activating: activating)
        refreshTopDock()
        schedulePreview()
    }

    private func compatibleTerminal(_ app: NSRunningApplication?) -> NSRunningApplication? {
        let selection = settings.terminal
        guard let app, TerminalChoice.matches(app.bundleIdentifier),
              selection == .lastActive || selection.bundleIdentifier == app.bundleIdentifier else { return nil }
        return app
    }

    private func captureTerminalTarget(from app: NSRunningApplication?) {
        if let app, app != NSRunningApplication.current { previousApp = app }
        let terminal = compatibleTerminal(app)
        refreshPermission()
        targetName = terminal?.localizedName
        target = terminal.flatMap(TerminalManager.focusedTarget)
    }

    func dismissPanel(keepPinned: Bool = false, animateFromDock: Bool = false) {
        if case .pastePosted = state { return }
        let shouldReturnFocus = panel?.isKeyWindow == true
        cancel()
        cancelConfirmation()
        savePanelPlacement()
        let staysVisible = keepPinned && settings.panelPinned
        if !staysVisible, animateFromDock, panel?.isVisible == true,
           panel?.isClosingFromDock != true, animateDockPanel(opening: false) {
            return
        }
        if !staysVisible { hidePanel() }
        if shouldReturnFocus, let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            _ = previousApp.activate()
        }
        if !staysVisible { previousApp = nil }
    }

    private func hidePanel() {
        cancelReplyReads()
        topDock?.cancelMorph(keepLauncherVisible: settings.topDockEnabled)
        panel?.orderOut(nil)
        refreshTopDock()
    }

    func refreshPermission() {
        let granted = TerminalManager.hasAccessibilityAccess
        if granted != hasAccessibilityAccess { hasAccessibilityAccess = granted }
        if granted, case .error(let error, _) = state, error as? TerminalFailure == .permission {
            state = result.isEmpty ? .idle : .preview
        }
    }

    func cancel() {
        if request != nil || debounce != nil || preparation != nil {
            clearPendingTranslation()
            state = .notice(LocalizedMessage("翻译已取消。"))
        }
        if case .pasting = state {
            deliveryTask?.cancel()
        }
    }

    func requestPrimaryAction() {
        if isConfirming {
            confirmPaste()
            return
        }
        guard canPerformAction else { return }
        if !result.isEmpty {
            performPrimaryAction()
            return
        }
        performActionWhenReady = true
        if request == nil, preparation == nil { beginTranslation() }
    }

    private func performPrimaryAction() {
        switch mode {
        case .compose: pasteResult()
        case .readReply: copyResult()
        }
    }

    private func beginTranslation() {
        debounce?.cancel()
        debounce = nil
        let pair = languagePair
        let source = text
        let currentMode = mode
        if pair.source == pair.target || (currentMode == .compose && source.utf8.count <= 4_096
            && !ProtectedPrompt.hasTranslatableProse(source[...], in: pair)) {
            completeTranslation(with: source)
            return
        }
        state = .translating
        preparation = Task { [weak self] in
            let input = await Self.prepareInput(source, mode: currentMode, pair: pair)
            guard let self, !Task.isCancelled else { return }
            self.preparation = nil
            if let input {
                self.startTranslation(input, in: pair)
            } else {
                self.completeTranslation(with: source)
            }
        }
    }

    @concurrent private static func prepareInput(_ text: String, mode: TranslationMode,
                                                  pair: TranslationPair) async -> Request.Input? {
        guard !Task.isCancelled else { return nil }
        if mode == .readReply {
            let markdown = ReplyMarkdown(text)
            if markdown.hasFormatting {
                let ranges = markdown.translationRanges(in: pair)
                return ranges.isEmpty ? nil : .reply(markdown, ranges)
            }
        }
        let prompt = ProtectedPrompt(text)
        return prompt.requiresTranslation(in: pair) ? .prompt(prompt) : nil
    }

    private func startTranslation(_ input: Request.Input, in pair: TranslationPair) {
        let request = Request(input: input, pair: pair)
        self.request = request
        languageCheck = Task { [weak self] in
            let source = pair.source.localeLanguage
            let target = pair.target.localeLanguage
            let availability = await LanguageAvailability().status(from: source, to: target)
            guard let self, !Task.isCancelled, self.requestID == request.id else { return }
            self.languageCheck = nil
            guard availability != .unsupported else {
                self.clearPendingTranslation()
                self.showError(TranslationFailure.unsupported(pair))
                return
            }
            self.request?.availability = availability
            self.startTranslationSession()
        }
        scheduleTranslationTimeout(after: .seconds(180), requestID: request.id)
    }

    private func startTranslationSession() {
        guard let request, let availability = request.availability else { return }
        if #available(macOS 26, *) { activeSession?.cancel() }
        activeSession = nil
        sessionRequest = SessionRequest(
            requestID: request.id,
            configuration: TranslationSession.Configuration(
                source: request.pair.source.localeLanguage, target: request.pair.target.localeLanguage
            )
        )
        scheduleTranslationTimeout(
            after: availability == .installed ? translationResponseTimeout : .seconds(180),
            requestID: request.id
        )
    }

    private func scheduleTranslationTimeout(after duration: Duration, requestID: UUID) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
                guard let self, let request = self.request, request.id == requestID else { return }
                if request.availability == .installed, !request.hasRetried {
                    self.request?.hasRetried = true
                    self.logger.warning("Translation session stopped responding; restarting once")
                    self.startTranslationSession()
                    return
                }
                self.clearPendingTranslation()
                self.showError(request.availability == .installed ? TranslationFailure.service : TranslationFailure.timeout)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func useTranslationSession(_ session: TranslationSession, for sessionRequest: SessionRequest) async {
        guard let request, request.id == sessionRequest.requestID,
              self.sessionRequest?.id == sessionRequest.id,
              let availability = request.availability, !Task.isCancelled,
              session.sourceLanguage?.minimalIdentifier == request.pair.source.id,
              session.targetLanguage?.minimalIdentifier == request.pair.target.id else { return }
        activeSession = session

        do {
            let translated: String
            switch request.input {
            case .prompt(let prompt):
                translated = try await TranslationService.translate(prompt, in: request.pair, with: session)
            case .reply(let document, let ranges):
                translated = try await TranslationService.translateReply(document, at: ranges, with: session)
            }
            guard self.requestID == request.id, self.sessionRequest?.id == sessionRequest.id else { return }
            finishTranslation()
            completeTranslation(with: translated)
        } catch {
            guard self.requestID == request.id, self.sessionRequest?.id == sessionRequest.id else { return }
            finishTranslation()
            performActionWhenReady = false
            if let failure = error as? TranslationFailure {
                showError(failure)
            } else if Task.isCancelled || error is CancellationError {
                state = .notice(LocalizedMessage("翻译已取消。"))
            } else if availability == .supported {
                showError(TranslationFailure.languageDownload(request.pair))
            } else {
                showError(TranslationFailure.service)
            }
        }
    }

    private func pasteResult() {
        guard !busy, !result.isEmpty, !isConfirming else { return }
        refreshPermission()
        guard hasAccessibilityAccess else { return showError(TerminalFailure.permission) }
        guard let target else { return showError(TerminalFailure.unavailable) }

        let pasteText = result.replacingOccurrences(of: "\r\n", with: "\n")
        guard PasteService.allowsTerminalPaste(pasteText) else { return showError(TerminalFailure.controlCharacters) }
        let delivery = Delivery(
            target: target, text: pasteText, autoSubmit: willSubmitPrompt
        )
        if PasteService.requiresConfirmation(text: pasteText) {
            state = .confirmation(delivery)
        } else {
            deliver(delivery)
        }
    }

    func confirmPaste() {
        guard case .confirmation(let delivery) = state else { return }
        deliver(delivery)
    }

    func cancelConfirmation() {
        if isConfirming { state = .preview }
    }

    func copyResult() {
        guard !result.isEmpty, !busy else { return }
        pasteboard.clearContents()
        if pasteboard.setString(result, forType: .string) {
            state = .notice(LocalizedMessage("已复制译文。"))
        } else {
            showError(TerminalFailure.clipboard)
        }
    }

    private func completeTranslation(with translated: String) {
        let shouldPerformAction = performActionWhenReady
        performActionWhenReady = false
        result = translated
        state = .preview
        if shouldPerformAction { performPrimaryAction() }
    }

    private func clearPendingTranslation() {
        debounce?.cancel()
        debounce = nil
        preparation?.cancel()
        preparation = nil
        performActionWhenReady = false
        if request != nil {
            finishTranslation()
        }
    }

    private func finishTranslation() {
        request = nil
        sessionRequest = nil
        if #available(macOS 26, *) { activeSession?.cancel() }
        activeSession = nil
        languageCheck?.cancel()
        languageCheck = nil
        timeout?.cancel()
        timeout = nil
    }

    private func deliver(_ delivery: Delivery) {
        guard panel?.isKeyWindow == true else { return showError(TerminalFailure.focusChanged) }
        state = .pasting
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryTask = nil }
            do {
                let outcome = try await PasteService.paste(
                    delivery.text,
                    into: delivery.target,
                    autoSubmit: delivery.autoSubmit,
                    preserveClipboard: self.settings.preserveClipboard,
                    willPostPaste: { self.state = .pastePosted }
                )
                if outcome == .enterSkipped {
                    self.state = .notice(LocalizedMessage("已向终端发送粘贴按键。请检查内容后手动按 Enter。"))
                    return
                }
                self.logger.debug("Posted terminal input events")
                if self.settings.clearAfterPaste {
                    self.text = ""
                    self.result = ""
                }
                self.state = .idle
                if !self.settings.panelPinned {
                    self.hidePanel()
                    if self.settings.topDockEnabled {
                        self.topDock?.acknowledgePaste(submitted: outcome == .enterPosted)
                    }
                }
            } catch is CancellationError {
                self.state = .notice(LocalizedMessage("粘贴已取消。"))
            } catch {
                self.showError(error)
            }
        }
    }

    private func showError(_ error: Error, recovery: ReplyRecovery? = nil) {
        state = .error(error, recovery: recovery)
        logger.debug("Input operation stopped with an error")
    }
}
