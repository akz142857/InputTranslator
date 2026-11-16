import AppKit
import ApplicationServices

struct TerminalTarget: Equatable {
    let pid: pid_t
    let launchDate: Date?
    let window: AXUIElement
    let input: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.launchDate == rhs.launchDate
            && CFEqual(lhs.window, rhs.window) && CFEqual(lhs.input, rhs.input)
    }
}

@MainActor
enum TerminalManager {
    private static let focusTimeout: Float = 0.15
    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func focusedTarget(for app: NSRunningApplication) -> TerminalTarget? {
        guard hasAccessibilityAccess, TerminalChoice.matches(app.bundleIdentifier), !app.isTerminated else {
            return nil
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, focusTimeout)
        guard let window = element(application, kAXFocusedWindowAttribute),
              let input = element(application, kAXFocusedUIElementAttribute) else { return nil }
        _ = AXUIElementSetMessagingTimeout(input, focusTimeout)
        guard attribute(input, kAXRoleAttribute) as? String == kAXTextAreaRole,
              let inputWindow = element(input, kAXWindowAttribute),
              CFEqual(window, inputWindow) else { return nil }
        return TerminalTarget(pid: app.processIdentifier, launchDate: app.launchDate, window: window, input: input)
    }

    static func matchesFocusedTarget(_ target: TerminalTarget) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == target.pid else { return false }
        return focusedTarget(for: frontmost) == target
    }

    static func restoreFocus(to target: TerminalTarget) async throws {
        guard hasAccessibilityAccess else { throw TerminalFailure.permission }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate == target.launchDate else {
            throw TerminalFailure.closed
        }
        guard NSApp.isActive || app.isActive else { throw TerminalFailure.focusChanged }
        if !app.isActive {
            NSApp.yieldActivation(to: app)
            _ = app.activate()
        }

        for _ in 0..<12 {
            try Task.checkCancellation()
            if app.isTerminated { throw TerminalFailure.closed }
            if app.isActive {
                guard matchesFocusedTarget(target) else { throw TerminalFailure.focusChanged }
                return
            }
            guard NSApp.isActive else { throw TerminalFailure.focusChanged }
            try await Task.sleep(for: .milliseconds(35))
        }
        throw TerminalFailure.focusChanged
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

enum TerminalFailure: LocalizedError {
    case permission, unavailable, closed, focusChanged, clipboard, event, controlCharacters

    var errorDescription: String? {
        switch self {
        case .permission: L10n.text("请在系统设置中授权辅助功能，再从终端唤起输入框。")
        case .unavailable: L10n.text("无法确认终端输入区域。请点击 Claude Code 的输入区，再从该终端打开输入框。")
        case .closed: L10n.text("原终端已关闭。")
        case .focusChanged: L10n.text("终端的焦点或输入区域已变化。请回到 Claude Code 后重新打开输入框。")
        case .clipboard: L10n.text("剪贴板已发生变化或无法写入，请复制译文后手动粘贴。")
        case .event: L10n.text("系统无法生成粘贴按键，请复制译文后手动粘贴。")
        case .controlCharacters: L10n.text("译文包含终端控制字符，已停止粘贴。")
        }
    }
}
