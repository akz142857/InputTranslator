import AppKit
import ApplicationServices

struct ApplicationTarget: Equatable {
    let pid: pid_t
    let launchDate: Date?
    let window: AXUIElement
    let input: AXUIElement
    var herdrFocus: HerdrFocus?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.launchDate == rhs.launchDate
            && CFEqual(lhs.window, rhs.window) && CFEqual(lhs.input, rhs.input)
            && lhs.herdrFocus == rhs.herdrFocus
    }
}

@MainActor
enum ApplicationTargetManager {
    private static let focusTimeout: Float = 0.15
    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func focusedTarget(for app: NSRunningApplication) async -> ApplicationTarget? {
        guard hasAccessibilityAccess, app != .current, !app.isTerminated else {
            return nil
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, focusTimeout)
        guard let window = element(application, kAXFocusedWindowAttribute),
              let input = element(application, kAXFocusedUIElementAttribute) else { return nil }
        _ = AXUIElementSetMessagingTimeout(input, focusTimeout)
        if app.bundleIdentifier == PasteDestination.herdr.bundleIdentifier,
           CFEqual(input, window), let executable = app.executableURL,
           let focus = try? await HerdrAdapter.focus(in: executable) {
            return ApplicationTarget(pid: app.processIdentifier, launchDate: app.launchDate,
                                     window: window, input: input, herdrFocus: focus)
        }
        let role = attribute(input, kAXRoleAttribute) as? String
        let subrole = attribute(input, kAXSubroleAttribute) as? String
        let enabled = attribute(input, kAXEnabledAttribute) as? Bool
        let editable = attribute(input, "AXEditable") as? Bool
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(input, kAXValueAttribute as CFString, &settable) == .success
            ? settable.boolValue : nil
        // A terminal's text area is a read-only screen that still accepts keyboard input.
        let terminalScreen = TerminalReplyReader.supports(app.bundleIdentifier) && role == kAXTextAreaRole
        guard acceptsTextInput(role: role, subrole: subrole, enabled: enabled,
                               editable: terminalScreen ? nil : editable,
                               valueSettable: terminalScreen ? nil : valueSettable),
              let inputWindow = element(input, kAXWindowAttribute), CFEqual(window, inputWindow) else { return nil }
        return ApplicationTarget(pid: app.processIdentifier, launchDate: app.launchDate, window: window, input: input)
    }

    static func acceptsTextInput(role: String?, subrole: String?, enabled: Bool?, editable: Bool?,
                                 valueSettable: Bool? = nil) -> Bool {
        guard subrole != kAXSecureTextFieldSubrole, enabled != false, editable != false else { return false }
        if editable == nil, valueSettable == false { return false }
        return role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole
    }

    static func matchesFocusedTarget(_ target: ApplicationTarget) async -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == target.pid else { return false }
        let focused = await focusedTarget(for: frontmost)
        return focused == target && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
    }

    static func restoreFocus(to target: ApplicationTarget) async throws {
        guard hasAccessibilityAccess else { throw PasteFailure.permission }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
              app.launchDate == target.launchDate else {
            throw PasteFailure.closed
        }
        guard NSApp.isActive || app.isActive else { throw PasteFailure.focusChanged }
        if !app.isActive {
            NSApp.yieldActivation(to: app)
            _ = app.activate()
        }

        let attempts = target.herdrFocus == nil ? 18 : 3
        for _ in 0..<attempts {
            try Task.checkCancellation()
            guard hasAccessibilityAccess else { throw PasteFailure.permission }
            if app.isTerminated { throw PasteFailure.closed }
            if app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
               let focused = await focusedTarget(for: app) {
                guard focused == target else { throw PasteFailure.focusChanged }
                return
            }
            guard NSApp.isActive || app.isActive else { throw PasteFailure.focusChanged }
            try await Task.sleep(for: .milliseconds(35))
        }
        throw PasteFailure.focusChanged
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

enum PasteFailure: LocalizedError {
    case permission, unavailable, closed, focusChanged, clipboard, event, controlCharacters

    var errorDescription: String? {
        switch self {
        case .permission: L10n.text("请在系统设置中授权辅助功能，再从目标应用唤起输入框。")
        case .unavailable: L10n.text("无法定位输入位置。请点击目标应用的输入框后重试，也可以复制译文手动粘贴。")
        case .closed: L10n.text("原应用已关闭。")
        case .focusChanged: L10n.text("输入位置已变化。请回到原窗口、标签页或分屏后重试。")
        case .clipboard: L10n.text("剪贴板已发生变化或无法写入，请复制译文后手动粘贴。")
        case .event: L10n.text("系统无法生成粘贴按键，请复制译文后手动粘贴。")
        case .controlCharacters: L10n.text("译文包含控制字符，已停止粘贴。")
        }
    }
}
