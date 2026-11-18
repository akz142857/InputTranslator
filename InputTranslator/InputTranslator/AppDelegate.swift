import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let controller = InputController()
    private var updater: AppUpdater { controller.updater }
    private lazy var hotkeys = HotkeyManager { [weak self] in self?.controller.toggleComposer() }
    private lazy var replyHotkey = HotkeyManager(signature: 0x49545252) { [weak self] in
        self?.controller.openLatestTerminalReply()
    }
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var replyChanges: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onOpenConnections = { [weak self] in self?.openAssistantConnections() }
        replyChanges = try? TerminalReplyStore().observeChanges { [weak self] in
            self?.controller.refreshLiveReply()
        }
        controller.onInterfaceLanguageChange = { [weak self] in
            self?.refreshMainMenuLanguage()
            self?.settingsWindow?.title = L10n.text("InputTranslator 设置")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let statusIcon = NSImage(resource: .statusItemIcon)
        statusIcon.accessibilityDescription = "InputTranslator"
        item.button?.image = statusIcon
        item.button?.toolTip = "InputTranslator"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsResignedKey(_:)), name: NSWindow.didResignKeyNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        let hotkey = controller.settings.hotkey
        if !hotkeys.register(hotkey) {
            controller.hotkeyMessage = LocalizedMessage("无法注册 %@。请在设置中选择其他快捷键。") { [hotkey.title] }
        }
        controller.replyShortcutAvailable = replyHotkey.register(.readReply)
        controller.restorePinnedPanel()

        updater.start()
    }

    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "InputTranslator")
        appItem.submenu = app
        main.addItem(appItem)
        addMainMenuItem("关于 InputTranslator", action: #selector(openAbout), in: app, target: self)
        app.addItem(.separator())
        addMainMenuItem("设置…", action: #selector(openSettings), key: ",", in: app, target: self)
        app.addItem(.separator())
        addMainMenuItem("关闭窗口", action: #selector(closeWindow), key: "w", in: app, target: self)
        addMainMenuItem("退出 InputTranslator", action: #selector(quit), key: "q", in: app, target: self)

        let editItem = NSMenuItem()
        editItem.representedObject = "编辑"
        main.addItem(editItem)
        let edit = NSMenu(title: L10n.text("编辑"))
        editItem.submenu = edit
        addMainMenuItem("撤销", action: Selector(("undo:")), key: "z", in: edit)
        addMainMenuItem("重做", action: Selector(("redo:")), key: "Z", in: edit)
        edit.addItem(.separator())
        addMainMenuItem("剪切", action: #selector(NSText.cut(_:)), key: "x", in: edit)
        addMainMenuItem("复制", action: #selector(NSText.copy(_:)), key: "c", in: edit)
        addMainMenuItem("粘贴", action: #selector(NSText.paste(_:)), key: "v", in: edit)
        addMainMenuItem("全选", action: #selector(NSText.selectAll(_:)), key: "a", in: edit)
        NSApp.mainMenu = main
    }

    private func addMainMenuItem(_ titleKey: String, action: Selector, key: String = "",
                                 in menu: NSMenu, target: AnyObject? = nil) {
        let item = menu.addItem(withTitle: L10n.text(titleKey), action: action, keyEquivalent: key)
        item.target = target
        item.representedObject = titleKey
    }

    private func refreshMainMenuLanguage() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items {
            if let key = item.representedObject as? String {
                item.title = L10n.text(key)
                item.submenu?.title = item.title
            }
            for command in item.submenu?.items ?? [] {
                if let key = command.representedObject as? String {
                    command.title = L10n.text(key)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.savePanelPlacement()
        replyChanges?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        hotkeys.stop()
        replyHotkey.stop()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        controller.refreshTopDock()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermission()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.settings.refreshLoginStatus()
        menu.removeAllItems()
        let open = add(L10n.text("写提示词"), #selector(openInput), to: menu)
        if controller.hotkeyMessage == nil {
            open.title += "    " + controller.settings.hotkey.title
        }
        let reply = add(L10n.text("读当前助手回复"), #selector(readLatestTerminalReply), to: menu)
        if controller.replyShortcutAvailable {
            reply.title += "    " + Hotkey.readReply.title
        }
        add(L10n.text("翻译剪贴板"), #selector(translateClipboard), to: menu)
        let pin = add(L10n.text("置顶浮窗"), #selector(togglePanelPin), to: menu)
        pin.state = controller.settings.panelPinned ? .on : .off
        let topDock = add(L10n.text("顶部停靠"), #selector(toggleTopDock), to: menu)
        topDock.state = controller.settings.topDockEnabled ? .on : .off
        menu.addItem(.separator())

        let autoSubmit = add(L10n.text("粘贴后按 Enter"), #selector(toggleAutoSubmit), to: menu)
        autoSubmit.state = controller.automaticallySubmitsToTarget ? .on : .off
        autoSubmit.isEnabled = controller.submissionBundleIdentifier != nil
        if let name = controller.submissionApplicationName { autoSubmit.title += " · " + name }

        let terminals = NSMenu()
        for choice in PasteDestination.choices(including: controller.settings.pasteDestination) {
            let item = add(choice.title, #selector(selectTerminal(_:)), to: terminals)
            item.representedObject = choice.rawValue
            item.state = choice == controller.settings.pasteDestination ? .on : .off
            item.isEnabled = !controller.isDelivering
        }
        add(L10n.text("目标应用"), nil, to: menu).submenu = terminals

        menu.addItem(.separator())
        add(L10n.text("终端助手接入…"), #selector(openAssistantConnections), to: menu)
        add(L10n.text("设置…"), #selector(openSettings), to: menu)
        let login = add(L10n.text("开机启动"), #selector(toggleLogin), to: menu)
        login.state = controller.settings.loginStatus == .enabled ? .on : .off
        menu.addItem(.separator())
        let checkForUpdates = add(L10n.text("检查更新…"), #selector(AppUpdater.checkForUpdates(_:)), to: menu)
        checkForUpdates.target = updater
        add(L10n.text("关于 InputTranslator"), #selector(openAbout), to: menu)
        add(L10n.text("退出 InputTranslator"), #selector(quit), to: menu).keyEquivalent = "q"
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector?, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openInput() {
        controller.showComposer()
    }

    @objc private func translateClipboard() {
        controller.openReplyFromClipboard()
    }

    @objc private func readLatestTerminalReply() {
        controller.openLatestTerminalReply()
    }

    @objc private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    @objc private func togglePanelPin() {
        controller.togglePanelPin()
        if settingsWindow?.isKeyWindow == true {
            settingsWindow?.level = controller.settings.panelPinned ? .floating : .normal
        }
    }

    @objc private func toggleTopDock() {
        controller.setTopDockEnabled(!controller.settings.topDockEnabled)
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            controller.activeApplicationChanged(to: app)
        }
    }

    @objc private func toggleAutoSubmit() {
        controller.setAutomaticallySubmitsToTarget(!controller.automaticallySubmitsToTarget)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutoSubmit) {
            return controller.submissionBundleIdentifier != nil && !controller.isDelivering
        }
        if menuItem.action == #selector(selectTerminal(_:)) { return !controller.isDelivering }
        return true
    }

    @objc private func selectTerminal(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        controller.selectPasteDestination(PasteDestination(rawValue: value))
    }

    @objc private func toggleLogin() {
        let settings = controller.settings
        let enabled = settings.loginStatus == .enabled || settings.loginStatus == .requiresApproval
        do {
            try settings.setStartsAtLogin(!enabled)
            controller.loginMessage = nil
        } catch {
            controller.loginMessage = LocalizedMessage("无法更新开机启动。请检查系统设置中的登录项。")
            openSettings()
        }
    }

    @objc private func openAssistantConnections() {
        controller.settingsPane = .assistants
        controller.refreshHookConnections()
        openSettings()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.text("InputTranslator 设置")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(
                controller: controller,
                updateHotkey: { [weak self] hotkey in self?.updateHotkey(hotkey) },
                settings: controller.settings
            ))
            window.setContentSize(SettingsView.windowSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.level = controller.settings.panelPinned ? .floating : .normal
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.level = controller.settings.panelPinned ? .floating : .normal
        controller.settings.refreshLoginStatus()
        controller.refreshPermission()
        controller.refreshHookConnections()
    }

    @objc private func settingsResignedKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        window.level = .normal
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "InputTranslator"])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateHotkey(_ hotkey: Hotkey) {
        if hotkeys.register(hotkey) {
            controller.settings.saveHotkey(hotkey)
            controller.hotkeyMessage = nil
            if !controller.replyShortcutAvailable {
                controller.replyShortcutAvailable = replyHotkey.register(.readReply)
            }
        } else {
            controller.hotkeyMessage = LocalizedMessage("无法注册 %@，可能已被系统或其他应用占用。") { [hotkey.title] }
        }
    }
}
