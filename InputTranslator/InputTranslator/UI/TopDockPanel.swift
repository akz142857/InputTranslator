import AppKit
import QuartzCore
import SwiftUI

struct TopDockLayout: Equatable {
    static let launcherSize = NSSize(width: 144, height: 30)
    private static let gap: CGFloat = 5
    let visibleFrame: NSRect
    let launcherFrame: NSRect

    init(visibleFrame: NSRect, screenFrame: NSRect, topLeft: NSRect?, topRight: NSRect?,
         launcherPlacement: PinnedPanelPlacement? = nil) {
        self.visibleFrame = visibleFrame
        let centerX = if let topLeft, let topRight {
            (topLeft.maxX + topRight.minX) / 2
        } else {
            screenFrame.midX
        }
        let defaultFrame = NSRect(
            x: centerX - Self.launcherSize.width / 2,
            y: visibleFrame.maxY - Self.gap - Self.launcherSize.height,
            width: Self.launcherSize.width, height: Self.launcherSize.height
        )
        let preferred = launcherPlacement?.restoredFrame(in: visibleFrame, size: Self.launcherSize) ?? defaultFrame
        launcherFrame = Self.clampLauncher(preferred, to: visibleFrame)
    }

    func panelFrame(size: NSSize, besideLauncher: Bool = false) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let x = max(visibleFrame.minX, min(launcherFrame.midX - width / 2, visibleFrame.maxX - width))
        if besideLauncher {
            let belowTop = launcherFrame.minY - Self.gap
            let aboveBottom = launcherFrame.maxY + Self.gap
            let below = max(0, belowTop - visibleFrame.minY)
            let above = max(0, visibleFrame.maxY - aboveBottom)
            if size.height <= below || (size.height > above && below >= above) {
                let height = min(size.height, below)
                return NSRect(x: x, y: belowTop - height, width: width, height: height)
            }
            return NSRect(x: x, y: aboveBottom, width: width, height: min(size.height, above))
        }
        let height = min(size.height, visibleFrame.height)
        let y = max(visibleFrame.minY, min(launcherFrame.maxY - height, visibleFrame.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func clampLauncher(_ frame: NSRect, to screen: NSRect) -> NSRect {
        let usable = screen.insetBy(dx: gap, dy: gap)
        let width = min(frame.width, usable.width)
        let height = min(frame.height, usable.height)
        return NSRect(x: max(usable.minX, min(frame.minX, usable.maxX - width)),
                      y: max(usable.minY, min(frame.minY, usable.maxY - height)),
                      width: width, height: height)
    }
}

extension NSScreen {
    var displayNumber: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var topDockLayout: TopDockLayout { topDockLayout(launcherPlacement: nil) }

    func topDockLayout(launcherPlacement: PinnedPanelPlacement?) -> TopDockLayout {
        TopDockLayout(visibleFrame: visibleFrame, screenFrame: frame,
                      topLeft: auxiliaryTopLeftArea, topRight: auxiliaryTopRightArea,
                      launcherPlacement: launcherPlacement)
    }

    static func containing(_ point: NSPoint) -> NSScreen? {
        screens.first { $0.frame.contains(point) }
    }

    static var underPointer: NSScreen? {
        containing(NSEvent.mouseLocation) ?? main ?? screens.first
    }
}

final class TopDockPanel: NSPanel {
    private final class LauncherPointerView: NSView {
        private var mouseStart: NSPoint?
        private var startFrame: NSRect = .zero
        private var didDrag = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            mouseStart = NSEvent.mouseLocation
            startFrame = window.frame
            didDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel = window as? TopDockPanel, let mouseStart else { return }
            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - mouseStart.x
            let dy = pointer.y - mouseStart.y
            guard didDrag || hypot(dx, dy) >= 6 else { return }
            didDrag = true
            guard let display = NSScreen.containing(pointer) ?? panel.screen else { return }
            let proposed = startFrame.offsetBy(dx: dx, dy: dy)
            panel.setFrame(TopDockLayout.clampLauncher(proposed, to: display.visibleFrame), display: true)
        }

        override func mouseUp(with event: NSEvent) {
            guard let panel = window as? TopDockPanel, mouseStart != nil else { return }
            mouseStart = nil
            if didDrag, let display = NSScreen.containing(NSEvent.mouseLocation) ?? panel.screen {
                didDrag = false
                panel.onMove(panel.frame, display)
            } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
                panel.onToggle()
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()
            let reset = menu.addItem(withTitle: L10n.text("恢复默认"), action: #selector(resetPosition), keyEquivalent: "")
            reset.target = self
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func resetPosition() {
            (window as? TopDockPanel)?.onResetPosition()
        }
    }

    struct Surface {
        let cornerRadius: CGFloat
        let opacity: Double
        let labelOpacity: Double
    }

    private let host: NSHostingView<TopDockControl>
    private let onToggle: () -> Void
    private var acknowledgement: Task<Void, Never>?
    private let onMove: (NSRect, NSScreen) -> Void
    private let onResetPosition: () -> Void
    private var morph: Task<Void, Never>?
    private var adjacentProgress: Double?
    private(set) var adjacentSurface: NSPanel?
    private(set) var activeLayout: TopDockLayout?
    var pasteFeedback: String? { host.rootView.feedback.map { L10n.text($0) } }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(action: @escaping () -> Void, onMove: @escaping (NSRect, NSScreen) -> Void = { _, _ in },
         onResetPosition: @escaping () -> Void = {}) {
        self.onToggle = action
        self.onMove = onMove
        self.onResetPosition = onResetPosition
        host = NSHostingView(rootView: TopDockControl(expanded: false, action: action))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = L10n.text("InputTranslator 顶部停靠")
        isFloatingPanel = true
        level = .floating
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        host.sizingOptions = []
        let container = NSView(frame: .zero)
        let pointer = LauncherPointerView(frame: container.bounds)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        pointer.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.addSubview(pointer)
        contentView = container
    }

    func refreshLanguage() {
        title = L10n.text("InputTranslator 顶部停靠")
        host.rootView.language = L10n.language
    }

    func show(at layout: TopDockLayout, expanded: Bool) {
        guard activeLayout == nil else { return }
        if host.rootView.expanded != expanded { host.rootView.expanded = expanded }
        if expanded { clearAcknowledgement() }
        let target = layout.launcherFrame
        if host.rootView.buttonSize != target.size { host.rootView.buttonSize = target.size }
        if frame != target { setFrame(target, display: true) }
        if !isVisible { orderFrontRegardless() }
    }

    func animate(layout: TopDockLayout, panelFrame: NSRect, opening: Bool, besideLauncher: Bool = false,
                 onChange: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        let previousProgress = besideLauncher && activeLayout == layout ? adjacentProgress : nil
        if previousProgress == nil {
            cancelMorph(keepLauncherVisible: besideLauncher)
        } else {
            morph?.cancel()
        }
        activeLayout = layout
        ignoresMouseEvents = !besideLauncher
        clearAcknowledgement()
        host.rootView.expanded = besideLauncher && opening

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = if reduceMotion { 0.12 } else if besideLauncher { opening ? 0.38 : 0.32 }
            else { opening ? 0.36 : 0.30 }
        let capsule = layout.launcherFrame
        host.rootView.buttonSize = capsule.size
        let initialProgress = previousProgress ?? (opening ? 0 : 1)
        let targetProgress: Double = opening ? 1 : 0
        let remainingDuration = duration * max(0.12, abs(targetProgress - initialProgress))
        let adjacentOrigin = Self.adjacentOrigin(capsule: capsule, panelFrame: panelFrame)
        let surface = besideLauncher && !reduceMotion ? prepareAdjacentSurface() : nil
        if surface == nil, adjacentSurface?.isVisible == true { adjacentSurface?.orderOut(nil) }

        func render(_ progress: Double) {
            if besideLauncher {
                let phase = initialProgress + (targetProgress - initialProgress) * progress
                adjacentProgress = phase
                if let surface {
                    let rect = Self.interpolate(from: adjacentOrigin, to: panelFrame,
                                                by: Self.smoothStep(phase / 0.88))
                    if surface.frame != rect { surface.setFrame(rect, display: true) }
                    surface.alphaValue = Self.smoothStep(phase / 0.18)
                    onChange(Self.smoothStep((phase - 0.72) / 0.28))
                } else {
                    onChange(Self.smoothStep(phase))
                }
                return
            }

            let expansion = opening ? Self.smoothStep(min(1, progress / 0.90))
                : 1 - Self.smoothStep(max(0, (progress - 0.13) / 0.87))
            let panelOpacity = if reduceMotion {
                opening ? progress : 1 - progress
            } else if opening {
                Self.smoothStep((progress - 0.69) / 0.31)
            } else {
                1 - Self.smoothStep(progress / 0.22)
            }

            let rect = reduceMotion ? capsule : Self.interpolate(from: capsule, to: panelFrame, by: expansion)
            if frame != rect { setFrame(rect, display: true) }
            if !reduceMotion {
                host.rootView.surface = Surface(
                    cornerRadius: capsule.height / 2 * (1 - expansion) + 13 * expansion,
                    opacity: Self.smoothStep(expansion / 0.12),
                    labelOpacity: 1 - Self.smoothStep(expansion / 0.30)
                )
            }
            alphaValue = 1 - panelOpacity
            onChange(panelOpacity)
        }

        render(0)
        if let surface, !surface.isVisible { surface.orderFrontRegardless() }
        if !besideLauncher || !isVisible { orderFrontRegardless() }
        let start = CACurrentMediaTime()
        morph = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let progress = min(1, (CACurrentMediaTime() - start) / remainingDuration)
                render(progress)
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled, let self else { return }
            self.cancelMorph(keepLauncherVisible: besideLauncher || !opening)
            completion()
        }
    }

    func cancelMorph(keepLauncherVisible: Bool = false) {
        guard let layout = activeLayout else { return }
        morph?.cancel()
        morph = nil
        adjacentProgress = nil
        adjacentSurface?.orderOut(nil)
        activeLayout = nil
        if !keepLauncherVisible { orderOut(nil) }
        ignoresMouseEvents = false
        host.rootView.surface = nil
        if frame != layout.launcherFrame {
            setFrame(layout.launcherFrame, display: keepLauncherVisible)
        }
        alphaValue = 1
    }

    private func prepareAdjacentSurface() -> NSPanel {
        // Animate a separate surface so the editor stays laid out at its final size.
        if let adjacentSurface { return adjacentSurface }
        let surface = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        surface.level = NSWindow.Level(rawValue: level.rawValue - 1)
        surface.collectionBehavior = collectionBehavior
        surface.isExcludedFromWindowsMenu = true
        surface.isReleasedWhenClosed = false
        surface.hidesOnDeactivate = false
        surface.isOpaque = false
        surface.backgroundColor = .clear
        surface.hasShadow = false
        surface.ignoresMouseEvents = true
        let view = NSHostingView(rootView: DockMorphSurface(cornerRadius: 13))
        view.sizingOptions = []
        surface.contentView = view
        adjacentSurface = surface
        return surface
    }

    private static func adjacentOrigin(capsule: NSRect, panelFrame: NSRect) -> NSRect {
        let width = min(capsule.width, panelFrame.width)
        let height = min(1, panelFrame.height)
        let x = max(panelFrame.minX, min(capsule.midX - width / 2, panelFrame.maxX - width))
        let y = panelFrame.minY >= capsule.maxY ? capsule.maxY : capsule.minY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func smoothStep(_ value: Double) -> Double {
        let step = max(0, min(1, value))
        return step * step * (3 - 2 * step)
    }

    private static func interpolate(from source: NSRect, to destination: NSRect, by fraction: CGFloat) -> NSRect {
        NSRect(x: source.minX + (destination.minX - source.minX) * fraction,
               y: source.minY + (destination.minY - source.minY) * fraction,
               width: source.width + (destination.width - source.width) * fraction,
               height: source.height + (destination.height - source.height) * fraction)
    }

    func acknowledgePaste(submitted: Bool) {
        guard isVisible, !host.rootView.expanded else { return }
        acknowledgement?.cancel()
        host.rootView.feedback = submitted ? "已提交" : "已粘贴"
        acknowledgement = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            self?.clearAcknowledgement()
        }
    }

    private func clearAcknowledgement() {
        acknowledgement?.cancel()
        acknowledgement = nil
        host.rootView.feedback = nil
    }
}

private struct DockMorphSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

private struct TopDockControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var expanded: Bool
    var language = L10n.language
    var feedback: String?
    var surface: TopDockPanel.Surface?
    var buttonSize = TopDockLayout.launcherSize
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if let surface {
                DockMorphSurface(cornerRadius: surface.cornerRadius)
                    .opacity(surface.opacity)
            }
            Group {
                if #available(macOS 26, *) {
                    control.glassEffect(.regular, in: .capsule)
                } else {
                    control.background(.regularMaterial, in: .capsule)
                }
            }
            .opacity(surface?.labelOpacity ?? 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, language == .arabic ? .rightToLeft : .leftToRight)
    }

    private var control: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: feedback == nil ? "character.bubble" : "checkmark")
                Text(L10n.text(feedback ?? "翻译"))
                    .contentTransition(.opacity)
                if feedback == nil {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
                }
            }
            .padding(.horizontal, 5)
            .frame(width: buttonSize.width, height: buttonSize.height)
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: feedback)
        }
        .buttonStyle(.plain)
        .allowsWindowActivationEvents()
        .accessibilityLabel(expanded ? L10n.text("收起翻译浮窗") : L10n.text("展开翻译浮窗"))
        .accessibilityValue(feedback.map { L10n.text($0) } ?? "")
        .accessibilityIdentifier("top-dock-toggle")
        .help(expanded ? L10n.text("收起翻译浮窗") : L10n.text("展开翻译浮窗"))
    }
}
