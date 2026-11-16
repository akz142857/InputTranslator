import AppKit
import Carbon
import ServiceManagement
import SwiftUI

enum SettingsPane: Hashable {
    case general, languages, terminal, assistants, shortcuts
}

struct SettingsView: View {
    @ObservedObject var controller: InputController
    let updateHotkey: (Hotkey) -> Void
    @ObservedObject var settings: AppSettings

    static let windowSize = NSSize(width: 630, height: 530)

    var body: some View {
        TabView(selection: Binding(get: { controller.settingsPane }, set: { pane in
            Task { @MainActor in controller.settingsPane = pane }
        })) {
            Tab(L10n.text("通用"), systemImage: "gearshape", value: .general) { general }
            Tab(L10n.text("语言"), systemImage: "globe", value: .languages) { languages }
            Tab(L10n.text("终端"), systemImage: "terminal", value: .terminal) { terminal }
            Tab(L10n.text("助手接入"), systemImage: "link", value: .assistants) { assistants }
            Tab(L10n.text("快捷键"), systemImage: "keyboard", value: .shortcuts) { shortcuts }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .environment(\.locale, L10n.locale)
        .environment(\.layoutDirection, settings.interfaceLanguage.resolved == .arabic ? .rightToLeft : .leftToRight)
    }

    private var languages: some View {
        let pair = settings.translationPair
        return Form {
            Section {
                Picker(L10n.text("界面语言"), selection: Binding(
                    get: { settings.interfaceLanguage }, set: controller.selectInterfaceLanguage
                )) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .accessibilityIdentifier("interface-language")
            }

            Section {
                languagePicker(L10n.text("原文语言"), identifier: "source-language", selection: Binding(
                    get: { settings.translationPair.source }, set: controller.selectSourceLanguage
                ), excluding: pair.target)
                languagePicker(L10n.text("译文语言"), identifier: "target-language", selection: Binding(
                    get: { settings.translationPair.target }, set: controller.selectTargetLanguage
                ), excluding: pair.source)
                Button(L10n.text("交换语言"), systemImage: "arrow.left.arrow.right", action: controller.swapLanguages)
                    .disabled(!controller.canSwitchMode || pair.source == pair.target)
            } header: {
                Text(L10n.text("写提示词"))
            } footer: {
                Text(L10n.text("首次使用某个语言对时，macOS 可能要求下载语言资源。"))
            }
            Section(L10n.text("读回复")) {
                LabeledContent(L10n.text("翻译方向"), value: pair.reverse.label)
            }
        }
        .formStyle(.grouped)
        .task { await controller.loadSupportedLanguages() }
    }

    private func languagePicker(_ title: String, identifier: String, selection: Binding<TranslationLanguage>,
                                excluding other: TranslationLanguage) -> some View {
        let current = selection.wrappedValue
        let available = controller.supportedLanguages
        let options = Set(available + [current]).filter {
            TranslationPair(source: $0, target: other).isSelectable
        }.sorted {
            $0.name.compare($1.name, locale: L10n.locale) == .orderedAscending
        }
        return Picker(title, selection: selection) {
            ForEach(options) { language in
                Text(language.name).tag(language)
            }
        }
        .accessibilityIdentifier(identifier)
        .disabled(!controller.canSwitchMode)
    }

    private var assistants: some View {
        Form {
            Section {
                ForEach(TerminalAssistant.allCases) { assistant in
                    assistantConnection(assistant)
                }
            } header: {
                Text(L10n.text("读取最新回复"))
            } footer: {
                Text(L10n.text("连接会在对应助手的用户配置中添加回复回调。回到终端，等待一轮新回复完成后按 ⌘⌥⇧Space。"))
            }

            Section {
                Button(L10n.text("打开 macOS 自动化设置…")) { TerminalReplyReader.openAutomationSettings() }
            } header: {
                Text(L10n.text("终端权限"))
            } footer: {
                Text(L10n.text("首次读取时，macOS 会分别请求 Terminal 和 iTerm2 的自动化权限。"))
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: controller.refreshHookConnections)
    }

    private func assistantConnection(_ assistant: TerminalAssistant) -> some View {
        let status = controller.hookStatuses[assistant] ?? .unconfigured
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                switch status {
                case .configured:
                    Button(L10n.text("断开")) { controller.updateHooks(for: assistant, install: false) }
                        .accessibilityLabel(L10n.text("断开 %@", assistant.name))
                case .unconfigured, .needsRepair:
                    let action = status == .needsRepair ? L10n.text("修复") : L10n.text("连接")
                    Button(action) { controller.updateHooks(for: assistant, install: true) }
                        .accessibilityLabel(L10n.text(status == .needsRepair ? "修复 %@" : "连接 %@", assistant.name))
                case .disabled, .unavailable:
                    Button(L10n.text("重新检查"), action: controller.refreshHookConnections)
                        .accessibilityLabel(L10n.text("重新检查 %@", assistant.name))
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(assistant.name)
                    Text(status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = controller.hookMessages[assistant] {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status == .configured, assistant == .codex {
                Text(L10n.text("新增或修复后，请在 Codex 的 /hooks 中确认信任。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status == .disabled {
                Text(L10n.text("请在该助手的设置中启用 hooks。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var general: some View {
        Form {
            Section {
                Toggle(L10n.text("顶部停靠"), isOn: Binding(
                    get: { settings.topDockEnabled }, set: controller.setTopDockEnabled
                ))
                .accessibilityIdentifier("top-dock-setting")
            } header: {
                Text(L10n.text("翻译浮窗"))
            } footer: {
                Text(L10n.text("从屏幕顶部展开翻译。拖动浮窗顶部可移出，点图钉可将浮窗置顶。"))
            }

            Section(L10n.text("启动")) {
                Toggle(L10n.text("登录时打开 InputTranslator"), isOn: Binding(
                    get: { settings.loginStatus == .enabled || settings.loginStatus == .requiresApproval },
                    set: { enabled in
                        do {
                            try settings.setStartsAtLogin(enabled)
                            controller.loginMessage = nil
                        } catch {
                            controller.loginMessage = LocalizedMessage("无法更新开机启动。请检查系统设置中的登录项。")
                        }
                    }
                ))
                if settings.loginStatus == .requiresApproval {
                    Text(L10n.text("请在系统设置的登录项中启用 InputTranslator。")).foregroundStyle(.secondary)
                }
                if let message = controller.loginMessage {
                    Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(L10n.text("粘贴到终端")) {
                    Label(controller.hasAccessibilityAccess ? L10n.text("已授权") : L10n.text("未授权"),
                          systemImage: controller.hasAccessibilityAccess ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
                Button(L10n.text("打开系统设置…"), action: TerminalManager.openAccessibilitySettings)
            } header: {
                Text(L10n.text("辅助功能"))
            } footer: {
                Text(L10n.text("粘贴到终端需要辅助功能权限。"))
            }
        }
        .formStyle(.grouped)
    }

    private var terminal: some View {
        Form {
            Section(L10n.text("粘贴")) {
                Picker(L10n.text("目标终端"), selection: $settings.terminal) {
                    ForEach(TerminalChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Toggle(L10n.text("粘贴后清空输入"), isOn: $settings.clearAfterPaste)
                Toggle(L10n.text("粘贴后恢复剪贴板"), isOn: $settings.preserveClipboard)
            }

            Section {
                Toggle(L10n.text("粘贴后自动按 Enter"), isOn: $settings.autoSubmit)
            } header: {
                Text(L10n.text("提交"))
            } footer: {
                Text(L10n.text("开启后，单行译文会在粘贴后立即提交。多行内容请手动提交。"))
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section(L10n.text("全局快捷键")) {
                LabeledContent(L10n.text("写提示词")) {
                    HStack(spacing: 10) {
                        HotkeyRecorder(
                            shortcutTitle: settings.hotkey.title,
                            accessibilityLabel: L10n.text("录制打开翻译窗口的快捷键"),
                            accessibilityHelp: L10n.text("按下新组合键，或按 Escape 取消。"),
                            onChange: updateHotkey
                        )
                        .frame(minWidth: 155)
                        Button(L10n.text("恢复默认")) { updateHotkey(.standard) }
                    }
                }
                if let message = controller.hotkeyMessage {
                    Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("阅读回复")) {
                LabeledContent(L10n.text("读当前助手回复"), value: Hotkey.readReply.title)
                LabeledContent(L10n.text("在读回复窗口读取最新一条"), value: "⌘R")
                if !controller.replyShortcutAvailable {
                    Text(L10n.text("全局快捷键被占用，可以从菜单栏打开。")).foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("翻译窗口")) {
                LabeledContent(L10n.text("读剪贴板里的回复"), value: "⌘⇧V")
                LabeledContent(L10n.text("粘贴或复制译文"), value: "⌘↵")
                LabeledContent(L10n.text("关闭窗口"), value: "⌘W")
            }
        }
        .formStyle(.grouped)
    }

}

struct HotkeyRecorder: NSViewRepresentable {
    let shortcutTitle: String
    let accessibilityLabel: String
    let accessibilityHelp: String
    let onChange: (Hotkey) -> Void

    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onChange = onChange
        button.shortcutTitle = shortcutTitle
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHelp)
    }

    final class RecorderButton: NSButton {
        var onChange: ((Hotkey) -> Void)?
        var shortcutTitle = "" {
            didSet {
                if !recording { title = shortcutTitle }
            }
        }
        private var recording = false

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(beginRecording)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        @objc private func beginRecording() {
            recording = true
            title = L10n.text("按下快捷键…")
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            finishRecording()
            return super.resignFirstResponder()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { finishRecording() }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording, window?.isKeyWindow == true, window?.firstResponder === self {
                record(event)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if recording {
                record(event)
            } else {
                super.keyDown(with: event)
            }
        }

        private func record(_ event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                finishRecording()
            } else if let hotkey = Hotkey(event: event) {
                finishRecording()
                onChange?(hotkey)
            } else {
                title = L10n.text("请使用修饰键和字符键")
            }
        }

        private func finishRecording() {
            recording = false
            title = shortcutTitle
        }
    }
}
