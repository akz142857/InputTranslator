import AppKit

enum TerminalReplyReader {
    private static let queue = DispatchQueue(label: "com.claycosmos.InputTranslator.terminal-replies",
                                             qos: .userInitiated)
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    static func latest(in terminal: NSRunningApplication?) async throws -> TerminalReply {
        guard let terminal, !terminal.isTerminated else { throw Failure.terminalRequired }
        let command: String
        switch terminal.bundleIdentifier {
        case TerminalChoice.terminal.bundleIdentifier:
            command = #"tell application id "com.apple.Terminal" to get tty of selected tab of front window"#
        case TerminalChoice.iTerm.bundleIdentifier:
            command = #"tell application id "com.googlecode.iterm2" to get tty of current session of current window"#
        default:
            throw Failure.terminalRequired
        }

        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            // AppleScript permits background use when all scripting work is serialized.
            queue.async {
                continuation.resume(with: Result { try read(command) })
            }
        }
    }

    nonisolated private static func read(_ command: String) throws -> TerminalReply {
        let script = NSAppleScript(source: "with timeout of 3 seconds\n" + command + "\nend timeout")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == -1743 || code == -1744 {
            throw Failure.automation
        }
        guard let tty = result?.stringValue, let job = TerminalJob.foreground(in: tty) else {
            throw Failure.sessionUnavailable
        }
        guard let message = try TerminalReplyStore().latest(for: job) else { throw Failure.replyUnavailable }
        return message
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case terminalRequired, automation, sessionUnavailable, replyUnavailable

        var errorDescription: String? {
            switch self {
            case .terminalRequired: L10n.text("请回到 Terminal 或 iTerm2 的助手会话，再读取当前回复。")
            case .automation: L10n.text("请在系统设置的「隐私与安全性 → 自动化」允许 InputTranslator 读取当前终端会话。")
            case .sessionUnavailable: L10n.text("无法定位当前终端会话。请切回本机助手所在的标签页或分屏。")
            case .replyUnavailable: L10n.text("当前会话暂无可读回复。请等助手完成一轮回复后再试。")
            }
        }
    }
}
