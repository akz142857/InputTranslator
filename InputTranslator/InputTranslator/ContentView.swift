import AppKit
import SwiftUI
import Translation

struct ContentView: View {
    @ObservedObject var controller: InputController
    @ObservedObject var settings: AppSettings
    let editor: PromptTextView

    private var readingReply: Bool { controller.mode == .readReply }
    private var showingReply: Bool { !controller.text.isEmpty || controller.showsSource }

    var body: some View {
        VStack(spacing: 10) {
            navigation
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .background {
                    PanelDragHandle(showsDragCursor: false)
                        .accessibilityHidden(true)
                }

            Divider()

            Group {
                if readingReply {
                    reader
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    composer
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 12)
        .environment(\.locale, L10n.locale)
        .environment(\.layoutDirection, settings.interfaceLanguage.resolved == .arabic ? .rightToLeft : .leftToRight)
        .background {
            if let request = controller.sessionRequest {
                Color.clear
                    .translationTask(request.configuration) { session in
                        await controller.useTranslationSession(session, for: request)
                    }
                    .id(request.id)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            TranslationTabs(
                selection: controller.mode,
                options: [(.compose, L10n.text("写提示词")), (.readReply, L10n.text("读回复"))],
                accessibilityID: "translation-mode-tabs",
                accessibilityTitle: L10n.text("翻译模式"),
                isEnabled: controller.canSwitchMode,
                onSelect: selectMode
            )
            .fixedSize()
            toolbarDragArea
            UpdateAvailableButton(updater: controller.updater)
            languageSwapButton
                .layoutPriority(1)
            windowControls
                .fixedSize()
        }
        .frame(minHeight: 30)
    }

    private var toolbarDragArea: some View {
        Spacer(minLength: 8)
            .overlay {
                PanelDragHandle()
                    .frame(height: 26)
                    .help(L10n.text("拖动浮窗；拖回屏幕顶部可重新停靠"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("拖动浮窗"))
                    .accessibilityIdentifier("top-dock-drag-handle")
            }
    }

    private var languageSwapButton: some View {
        let pair = controller.languagePair
        return Button(action: controller.swapLanguages) {
            ViewThatFits(in: .horizontal) {
                languagePairLabel(source: pair.source.name, target: pair.target.name)
                languagePairLabel(source: shortLanguageName(pair.source, other: pair.target),
                                  target: shortLanguageName(pair.target, other: pair.source))
                languagePairLabel(source: pair.source.id.uppercased(), target: pair.target.id.uppercased())
                Image(systemName: "arrow.left.arrow.right")
                    .fixedSize()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .modifier(WindowControlMaterial())
        .help(L10n.text("交换语言") + " · " + pair.label)
        .accessibilityLabel(L10n.text("交换语言"))
        .accessibilityValue(pair.label)
        .accessibilityIdentifier("language-swap")
        .disabled(!controller.canSwitchMode || pair.source == pair.target)
    }

    private func languagePairLabel(source: String, target: String) -> some View {
        HStack(spacing: 5) {
            Text(source)
                .foregroundStyle(.primary)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(target)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func shortLanguageName(_ language: TranslationLanguage, other: TranslationLanguage) -> String {
        guard let code = language.localeLanguage.languageCode?.identifier,
              code != other.localeLanguage.languageCode?.identifier else { return language.name }
        return L10n.locale.localizedString(forLanguageCode: code) ?? language.name
    }

    private func selectMode(_ mode: TranslationMode) {
        guard mode != controller.mode, controller.canSwitchMode else { return }
        switch mode {
        case .compose: controller.showComposer()
        case .readReply: controller.showReplyMode()
        }
    }

    private var windowControls: some View {
        HStack(spacing: 4) {
            if settings.prefersTopDock {
                windowButton("chevron.up", title: L10n.text("收起翻译浮窗")) {
                    controller.dismissPanel(animateFromDock: true)
                }
                .accessibilityIdentifier("top-dock-collapse")
            }
            if settings.topDockEnabled {
                let placementAction = settings.prefersTopDock ? L10n.text("移出为浮窗") : L10n.text("停靠到顶部")
                windowButton(settings.prefersTopDock ? "arrow.down.to.line" : "arrow.up.to.line",
                             title: placementAction, action: controller.toggleTopDockPlacement)
                    .accessibilityIdentifier("top-dock-placement")
                    .disabled(!controller.canSwitchMode)
            }
            windowButton(settings.panelPinned ? "pin.fill" : "pin",
                         title: settings.panelPinned ? L10n.text("取消置顶") : L10n.text("置顶浮窗"), action: controller.togglePanelPin)
                .accessibilityIdentifier("panel-pin")
                .accessibilityValue(settings.panelPinned ? L10n.text("已置顶") : L10n.text("未置顶"))
            windowButton("gearshape", title: L10n.text("设置…")) {
                controller.onOpenSettings?()
            }
            .accessibilityIdentifier("panel-settings")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .modifier(WindowControlMaterial())
    }

    private func windowButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
        .help(title)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            VSplitView {
                sourceEditor
                    .frame(minHeight: 56, maxHeight: .infinity)
                composerPreview
            }
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }

            if let message = controller.message, !controller.busy {
                statusMessage(message)
            }

            composerFooter
        }
    }

    private var composerPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("%@预览", controller.languagePair.target.name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if controller.result.isEmpty {
                if controller.busy && !controller.isDelivering, let message = controller.message {
                    progress(message)
                } else if !controller.showsError {
                    Text(controller.text.isEmpty ? L10n.text("停顿后自动翻译") : L10n.text("等待输入完成…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                translationText
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var reader: some View {
        if showingReply {
            VStack(alignment: .leading, spacing: 10) {
                replyHeader
                ZStack {
                    replyTranslation
                        .opacity(controller.showsSource ? 0 : 1)
                        .allowsHitTesting(!controller.showsSource)
                        .accessibilityHidden(controller.showsSource)
                    if controller.showsSource {
                        if controller.showsEditor {
                            sourceEditor
                        } else {
                            ReplyDocumentView(source: controller.text, accessibilityLabel: L10n.text("回复原文"),
                                              accessibilityID: "reply-original")
                                .environment(\.layoutDirection, layoutDirection(for: controller.languagePair.source))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if let message = controller.message, !controller.busy {
                    statusMessage(message)
                }
                Divider()
                replyFooter
            }
        } else {
            replyEmptyState
        }
    }

    private var replyHeader: some View {
        let origin = controller.replyOrigin
        return HStack(spacing: 6) {
            Label(origin?.title ?? L10n.text("手动输入"), systemImage: origin?.symbol ?? "text.alignleft")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
            Text((controller.showsSource ? controller.languagePair.source : controller.languagePair.target).name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if !controller.text.isEmpty {
                if controller.showsSource {
                    windowButton(controller.isEditingReplySource ? "checkmark" : "pencil",
                                 title: L10n.text("编辑"), action: controller.toggleReplySourceEditing)
                        .accessibilityIdentifier("edit-reply-source")
                        .accessibilityAddTraits(controller.isEditingReplySource ? .isSelected : [])
                        .disabled(!controller.canSwitchMode)
                }
                TranslationTabs(
                    selection: controller.showsSource,
                    options: [(false, L10n.text("译文")), (true, L10n.text("原文"))],
                    accessibilityID: "reply-content-tabs",
                    accessibilityTitle: L10n.text("回复内容"),
                    isEnabled: controller.canSwitchMode,
                    onSelect: controller.showReplySource
                )
                .fixedSize()
            }
        }
        .frame(minHeight: 24)
    }

    private var replyTranslation: some View {
        Group {
            if controller.result.isEmpty {
                Group {
                    if controller.busy, let message = controller.message {
                        progress(message)
                    } else if !controller.showsError {
                        Text(L10n.text("正在等待译文…"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 5)
            } else {
                ReplyDocumentView(source: controller.result, accessibilityLabel: L10n.text("译文"),
                                  accessibilityID: "reply-translation")
                    .environment(\.layoutDirection, layoutDirection(for: controller.languagePair.target))
            }
        }
    }

    private var replyEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.text("阅读终端回复"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("reply-empty-state")
            Text(controller.message ?? (!controller.supportsReplyReading
                ? L10n.text("从 Terminal 或 iTerm2 打开可读取当前会话，也可以翻译复制好的回复。")
                : L10n.text("等助手回复完成后自动翻译。")))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 310)
            HStack(spacing: 10) {
                if let recovery = controller.replyRecovery {
                    recoveryButton(recovery, prominent: true)
                    clipboardButton()
                } else if controller.supportsReplyReading {
                    TranslationActionButton(prominent: true, action: controller.openLatestTerminalReply) {
                        Text(L10n.text("读取当前会话"))
                    }
                    .help(L10n.text("读取当前终端助手会话的最新回复（⌘R）"))
                    clipboardButton()
                } else {
                    clipboardButton(prominent: true)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceEditor: some View {
        ZStack(alignment: .topLeading) {
            PromptEditor(
                editor: editor,
                text: $controller.text,
                accessibilityLabel: readingReply ? L10n.text("回复原文") : L10n.text("提示词"),
                fontSize: readingReply ? 16 : 14,
                lineSpacing: readingReply ? 5 : 3,
                isEditable: !controller.isDelivering && !controller.isConfirming,
                onCompositionChange: controller.updateComposition
            )
            if controller.text.isEmpty, !controller.isComposing {
                Text(readingReply ? L10n.text("在这里粘贴回复…") : L10n.text("输入提示词…"))
                    .font(.system(size: readingReply ? 16 : 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, readingReply ? 0 : 12)
        .padding(.vertical, readingReply ? 0 : 8)
        .environment(\.layoutDirection, layoutDirection(for: controller.languagePair.source))
    }

    private var translationText: some View {
        ScrollViewReader { scroll in
            ScrollView {
                Text(controller.result)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("translation-result")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("translation-start")
            }
            .defaultScrollAnchor(.top)
            .accessibilityIdentifier("translation-scroll")
            .onChange(of: controller.result) { _, result in
                if !result.isEmpty { scroll.scrollTo("translation-start", anchor: .top) }
            }
        }
        .environment(\.layoutDirection, layoutDirection(for: controller.languagePair.target))
        .accessibilityLabel(L10n.text("译文预览"))
    }

    private func layoutDirection(for language: TranslationLanguage) -> LayoutDirection {
        language.localeLanguage.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func statusMessage(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if controller.showsError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityHidden(true)
            }
            Text(message)
                .foregroundStyle(controller.showsError ? .primary : .secondary)
                .accessibilityLabel(controller.showsError ? L10n.text("错误。%@", message) : message)
                .accessibilityIdentifier("translation-status")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var composerFooter: some View {
        HStack(spacing: 8) {
            if controller.isDelivering, let message = controller.message {
                progress(message)
            } else if !controller.isConfirming {
                if let name = controller.targetName {
                    Label(name, systemImage: controller.targetSymbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(L10n.text("目标应用，%@", name))
                }
                if controller.offersAccessibilitySettings {
                    Button(L10n.text(controller.hasAccessibilityAccess ? "打开系统设置…" : "授权…"),
                           action: ApplicationTargetManager.openAccessibilitySettings)
                        .buttonStyle(.link)
                        .help(L10n.text("打开系统设置，允许粘贴到其他应用"))
                        .accessibilityIdentifier("terminal-accessibility-settings")
                }
            }
            Spacer()
            composerActions
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder private var composerActions: some View {
        if controller.isDelivering {
            if controller.canCancel {
                TranslationActionButton(action: controller.cancel) { Text(L10n.text("取消")) }
            }
        } else if controller.isConfirming {
            TranslationActionButton(action: controller.cancelConfirmation) { Text(L10n.text("取消")) }
            TranslationActionButton(prominent: true, action: controller.confirmPaste) {
                actionLabel(L10n.text("确认并粘贴"))
            }
        } else {
            if !controller.result.isEmpty {
                Button(action: controller.copyResult) {
                    Image(systemName: "document.on.document")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.text("复制译文"))
                .help(L10n.text("复制译文"))
            }
            primaryAction(controller.pasteActionTitle)
                .help(L10n.text(controller.willSubmitPrompt ? "粘贴并提交" : "粘贴译文到原输入位置（⌘↵）"))
                .accessibilityIdentifier("paste-to-terminal")
        }
    }

    private var replyFooter: some View {
        HStack(spacing: 8) {
            if let recovery = controller.replyRecovery {
                recoveryButton(recovery)
            } else if controller.supportsReplyReading {
                Button(action: controller.openLatestTerminalReply) {
                    Label(L10n.text("读最新回复"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("读取当前终端助手会话的最新回复（⌘R）"))
                .disabled(!controller.canSwitchMode)
            }

            clipboardButton()
            Spacer(minLength: 0)
            if !controller.result.isEmpty {
                primaryAction(L10n.text("复制译文"))
                    .help(L10n.text("复制译文（⌘↵）"))
            }
        }
        .frame(minHeight: 28)
    }

    private func clipboardButton(prominent: Bool = false) -> some View {
        TranslationActionButton(prominent: prominent, action: controller.translateClipboard) {
            if prominent {
                Label(L10n.text("从剪贴板读取"), systemImage: "clipboard")
            } else {
                Text(L10n.text("从剪贴板读取"))
            }
        }
        .accessibilityIdentifier("read-reply-from-clipboard")
        .help(L10n.text("翻译剪贴板中的文本（⌘⇧V）"))
        .disabled(!controller.canSwitchMode)
    }

    private func recoveryButton(_ recovery: InputController.ReplyRecovery, prominent: Bool = false) -> some View {
        TranslationActionButton(prominent: prominent, action: {
            switch recovery {
            case .connections: controller.onOpenConnections?()
            case .automation: TerminalReplyReader.openAutomationSettings()
            }
        }) {
            Text(recovery == .connections ? L10n.text("连接终端助手…") : L10n.text("打开自动化设置…"))
        }
    }

    private func primaryAction(_ title: String) -> some View {
        TranslationActionButton(prominent: true, action: controller.requestPrimaryAction) {
            actionLabel(title)
        }
        .disabled(!controller.canPerformAction)
    }

    private func actionLabel(_ title: String) -> some View {
        HStack(spacing: 7) {
            Text(title)
            Text("⌘↵")
                .font(.caption)
                .opacity(0.88)
                .accessibilityHidden(true)
        }
    }
}

private struct UpdateAvailableButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        if let version = updater.availableVersion {
            Button {
                updater.checkForUpdates(nil)
            } label: {
                ViewThatFits(in: .horizontal) {
                    Label(L10n.text("有新版本"), systemImage: "arrow.down.circle.fill")
                        .fixedSize()
                    Image(systemName: "arrow.down.circle.fill")
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .modifier(WindowControlMaterial())
            .help(L10n.text("更新至 v%@", version))
            .accessibilityLabel(L10n.text("更新至 v%@", version))
            .accessibilityIdentifier("panel-update-available")
        }
    }
}

private struct WindowControlMaterial: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: .capsule)
        }
    }
}

private struct TranslationActionButton<Label: View>: View {
    var prominent = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if prominent {
            if #available(macOS 26, *) {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        } else {
            button.buttonStyle(.borderless)
        }
    }

    private var button: some View {
        Button(action: action, label: label)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
    }
}
