import AppKit

@main
enum InputTranslatorApp {
    @MainActor
    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case TerminalHookInstaller.legacyArgument:
            receiveHook(from: .claude)
            return
        case TerminalHookInstaller.argument:
            if let name = CommandLine.arguments.dropFirst(2).first, let assistant = TerminalAssistant(rawValue: name) {
                receiveHook(from: assistant)
            }
            return
        case "--install-claude-hook", "--uninstall-claude-hook":
            do {
                try TerminalHookInstaller(.claude).update(install: CommandLine.arguments[1] == "--install-claude-hook")
                print(L10n.text("InputTranslator 的 Claude Code hook 配置已同步。"))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        default:
            break
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }

    private static func receiveHook(from assistant: TerminalAssistant) {
        if let data = try? LocalFile.read(.standardInput, limit: TerminalHookInput.maximumInputBytes),
           let job = TerminalJob.forHook(), let input = try? TerminalHookInput.decode(data, from: assistant) {
            try? TerminalReplyStore().receive(input, assistant: assistant, from: job)
        }
        // A neutral JSON response satisfies Codex and Gemini's hook output contract.
        if assistant != .claude { print("{}") }
    }
}
