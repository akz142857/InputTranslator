import AppKit
import Carbon
import SwiftUI

struct PinnedPanelPlacement: Codable, Equatable {
    let frame: NSRect
    let screenFrame: NSRect
    let displayNumber: UInt32?

    func restoredFrame(in visibleFrame: NSRect, size: NSSize? = nil) -> NSRect {
        let width = min(size?.width ?? frame.width, visibleFrame.width)
        let height = min(size?.height ?? frame.height, visibleFrame.height)
        let left = frame.minX - screenFrame.minX
        let right = screenFrame.maxX - frame.maxX
        let bottom = frame.minY - screenFrame.minY
        let top = screenFrame.maxY - frame.maxY
        let x = left <= right ? visibleFrame.minX + left : visibleFrame.maxX - right - width
        let y = bottom <= top ? visibleFrame.minY + bottom : visibleFrame.maxY - top - height
        return NSRect(
            x: max(visibleFrame.minX, min(x, visibleFrame.maxX - width)),
            y: max(visibleFrame.minY, min(y, visibleFrame.maxY - height)),
            width: width,
            height: height
        )
    }
}

final class FloatingPanel: NSPanel, NSWindowDelegate {
    private static let minimumContentSize = NSSize(width: 510, height: 300)
    private weak var controller: InputController?
    private let editor = PromptTextView(frame: .zero)
    private var hasPresented = false
    private var isPresenting = false
    private(set) var dockLayout: TopDockLayout?
    private var besideLauncher = false
    private var preferredDockSize: NSSize?
    private var draggingGrip = false
    private(set) var isClosingFromDock = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(controller: InputController) {
        self.controller = controller
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "InputTranslator"
        isExcludedFromWindowsMenu = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        delegate = self
        applyPin(controller.settings.panelPinned)
        contentMinSize = Self.minimumContentSize
        let host = NSHostingView(rootView: ContentView(
            controller: controller, settings: controller.settings, editor: editor
        ))
        host.sizingOptions = []
        if #available(macOS 26, *) {
            styleMask.insert(.fullSizeContentView)
            titlebarAppearsTransparent = true
            backgroundColor = .windowBackgroundColor
            let background = NSView()
            contentView = background

            host.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(host)
            let layout = contentLayoutGuide as! NSLayoutGuide
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: layout.topAnchor),
                host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: background.trailingAnchor)
            ])
        } else {
            contentView = host
        }
        setContentSize(NSSize(width: 580, height: 350))
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            center.addObserver(self, selector: #selector(panelFrameChanged(_:)), name: name, object: self)
        }
    }

    func applyPin(_ pinned: Bool) {
        hidesOnDeactivate = !pinned
        collectionBehavior = pinned ? [.canJoinAllSpaces, .canJoinAllApplications] : [.fullScreenAuxiliary, .moveToActiveSpace]
        if pinned {
            level = .floating
            savePlacement()
        }
    }

    func applyTopDock(_ layout: TopDockLayout?, besideLauncher: Bool = false, restoreFloating: Bool = true) {
        guard layout != dockLayout || besideLauncher != self.besideLauncher else { return }
        let wasDocked = dockLayout != nil
        dockLayout = layout
        self.besideLauncher = besideLauncher
        isMovable = layout == nil
        if let layout {
            let savedSize = controller?.settings.dockedPanelPlacement?.frame.size
            let size = wasDocked ? preferredDockSize ?? frame.size : savedSize ?? frame.size
            positionDockedPanel(in: layout, size: size)
        } else {
            preferredDockSize = nil
            contentMinSize = Self.minimumContentSize
            if wasDocked && restoreFloating && !restoreFloatingPlacement(), let screen {
                setFrameOrigin(NSPoint(x: frame.minX, y: max(screen.visibleFrame.minY, frame.minY - 48)))
            }
        }
        savePlacement()
    }

    private func positionDockedPanel(in layout: TopDockLayout, size: NSSize) {
        let target = layout.panelFrame(size: size, besideLauncher: besideLauncher)
        // Keep the user's window size when available space temporarily limits it.
        preferredDockSize = target.size == size ? nil : size
        let contentSize = contentRect(forFrameRect: target).size
        contentMinSize = NSSize(width: min(Self.minimumContentSize.width, contentSize.width),
                                height: min(Self.minimumContentSize.height, contentSize.height))
        if frame != target { setFrame(target, display: isVisible) }
    }

    func present(activating: Bool = true) {
        let midpoint = NSPoint(x: frame.midX, y: frame.midY)
        if dockLayout == nil && (!hasPresented || !NSScreen.screens.contains(where: { $0.visibleFrame.contains(midpoint) })) {
            if !restoreFloatingPlacement(), let screen = NSScreen.underPointer {
                let visible = screen.visibleFrame
                setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
            }
        }
        hasPresented = true
        defer { savePlacement() }
        guard activating else {
            orderFrontRegardless()
            return
        }
        isPresenting = true
        defer { isPresenting = false }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        focusEditor()
    }

    func beginDockMotion(opening: Bool) {
        isClosingFromDock = !opening
        ignoresMouseEvents = true
        if opening && !isVisible { alphaValue = 0.01 }
    }

    func finishDockMotion() {
        isClosingFromDock = false
        ignoresMouseEvents = false
        alphaValue = 1
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        finishDockMotion()
    }

    private func restoreFloatingPlacement() -> Bool {
        guard let settings = controller?.settings, settings.panelPinned || settings.topDockEnabled,
              let placement = settings.pinnedPanelPlacement else { return false }
        let screens = NSScreen.screens
        let matching = placement.displayNumber.flatMap { number in screens.first { $0.displayNumber == number } }
        guard let display = matching ?? screens.first(where: { $0.visibleFrame == placement.screenFrame }) ?? NSScreen.underPointer
        else { return false }
        setFrame(placement.restoredFrame(in: display.visibleFrame), display: isVisible)
        return true
    }

    @objc private func panelFrameChanged(_ notification: Notification) {
        savePlacement()
    }

    func savePlacement() {
        guard hasPresented, isVisible, !draggingGrip, let settings = controller?.settings,
              settings.panelPinned || settings.topDockEnabled, let screen else { return }
        let savedFrame = NSRect(origin: frame.origin, size: preferredDockSize ?? frame.size)
        settings.savePanelPlacement(PinnedPanelPlacement(
            frame: savedFrame, screenFrame: screen.visibleFrame, displayNumber: screen.displayNumber
        ), docked: dockLayout != nil)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let dockLayout {
            positionDockedPanel(in: dockLayout, size: frame.size)
        }
        savePlacement()
    }

    func windowDidResignKey(_ notification: Notification) {
        controller?.topDockPanelResignedKey()
    }

    func beginGripDrag() -> Bool {
        guard let controller, controller.settings.topDockEnabled, controller.canSwitchMode else { return false }
        savePlacement()
        draggingGrip = true
        controller.detachTopDockForDrag()
        return true
    }

    func endGripDrag(at pointer: NSPoint) {
        if let destination = NSScreen.containing(pointer),
           let target = controller?.topDockLayout(on: destination).launcherFrame,
           target.insetBy(dx: -26, dy: -12).contains(pointer) {
            controller?.dockPanel(on: destination)
        }
        draggingGrip = false
        savePlacement()
    }

    override func becomeKey() {
        super.becomeKey()
        if !isPresenting { controller?.pinnedPanelBecameKey() }
    }

    func focusEditor() {
        guard controller?.showsEditor == true else { return }
        contentView?.layoutSubtreeIfNeeded()
        if editor.window === self {
            makeFirstResponder(editor)
        }
    }

    override func performClose(_ sender: Any?) {
        controller?.dismissPanel(animateFromDock: true)
    }

    override func sendEvent(_ event: NSEvent) {
        if isClosingFromDock && event.type == .keyDown { return }
        if event.type == .keyDown, let controller,
           (firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape where modifiers.isEmpty:
                if controller.isConfirming {
                    controller.cancelConfirmation()
                } else {
                    controller.dismissPanel(keepPinned: true, animateFromDock: true)
                }
                return
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if modifiers == .command {
                    if !event.isARepeat { controller.requestPrimaryAction() }
                    return
                }
            case kVK_ANSI_V where modifiers == [.command, .shift]:
                if !event.isARepeat { controller.translateClipboard() }
                return
            case kVK_ANSI_R where modifiers == .command && controller.mode == .readReply:
                if !event.isARepeat { controller.openLatestTerminalReply() }
                return
            case kVK_ANSI_Comma where modifiers == .command:
                if !event.isARepeat { controller.onOpenSettings?() }
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}

struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        private var mouseStart: NSPoint?
        private var frameOrigin: NSPoint = .zero
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            mouseStart = NSEvent.mouseLocation
            frameOrigin = window?.frame.origin ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel = window as? FloatingPanel, let mouseStart else { return }
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - mouseStart.x
            let dy = pointer.y - mouseStart.y
            if !dragging {
                guard hypot(dx, dy) >= 8, panel.beginGripDrag() else { return }
                dragging = true
            }
            panel.setFrameOrigin(NSPoint(x: frameOrigin.x + dx, y: frameOrigin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            if dragging { (window as? FloatingPanel)?.endGripDrag(at: NSEvent.mouseLocation) }
            mouseStart = nil
            dragging = false
        }
    }
}

final class PromptTextView: NSTextView {
    var didUpdateInput: (() -> Void)?
    private(set) var isUpdatingMarkedText = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isUpdatingMarkedText = true
        didUpdateInput?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        isUpdatingMarkedText = false
        didUpdateInput?()
    }

    override func unmarkText() {
        super.unmarkText()
        didUpdateInput?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        didUpdateInput?()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let panel = window as? FloatingPanel else { return }
        panel.initialFirstResponder = self
        if panel.isKeyWindow { panel.makeFirstResponder(self) }
    }
}

struct PromptEditor: NSViewRepresentable {
    let editor: PromptTextView
    @Binding var text: String
    var accessibilityLabel: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var isEditable: Bool
    let onCompositionChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        editor.delegate = context.coordinator
        let coordinator = context.coordinator
        editor.didUpdateInput = { [weak editor, weak coordinator] in
            guard let editor else { return }
            coordinator?.update(from: editor)
        }
        editor.font = .systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        editor.defaultParagraphStyle = paragraph
        editor.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                                         range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 0, height: 5)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if editor.string != text, !editor.isUpdatingMarkedText, !editor.hasMarkedText() {
            editor.string = text
            editor.undoManager?.removeAllActions()
        }
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCompositionChange: onCompositionChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let onCompositionChange: (Bool) -> Void

        init(text: Binding<String>, onCompositionChange: @escaping (Bool) -> Void) {
            self.text = text
            self.onCompositionChange = onCompositionChange
        }

        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? PromptTextView { update(from: editor) }
        }

        func update(from editor: PromptTextView) {
            let composing = editor.isUpdatingMarkedText || editor.hasMarkedText()
            if !composing, text.wrappedValue != editor.string {
                text.wrappedValue = editor.string
            }
            onCompositionChange(composing)
        }
    }
}
