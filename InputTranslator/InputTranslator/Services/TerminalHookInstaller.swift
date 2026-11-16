import Darwin
import Foundation

nonisolated enum TerminalAssistant: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, gemini

    var id: Self { self }

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .gemini: "Gemini CLI"
        }
    }

    var eventName: String { self == .gemini ? "AfterAgent" : "Stop" }
    var events: [String] { ["SessionStart", eventName, "SessionEnd"] }

    var configurationURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        func location(_ key: String, fallback: URL) -> URL {
            guard let path = environment[key], !path.isEmpty else { return fallback }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        switch self {
        case .claude:
            return location("CLAUDE_CONFIG_DIR", fallback: home.appendingPathComponent(".claude"))
                .appendingPathComponent("settings.json")
        case .codex:
            return location("CODEX_HOME", fallback: home.appendingPathComponent(".codex"))
                .appendingPathComponent("hooks.json")
        case .gemini:
            return location("GEMINI_CLI_HOME", fallback: home)
                .appendingPathComponent(".gemini/settings.json")
        }
    }

    var hookArgument: String {
        self == .claude ? TerminalHookInstaller.legacyArgument
            : "\(TerminalHookInstaller.argument) \(rawValue)"
    }

    fileprivate func handler(command: String, event: String) -> [String: Any] {
        var handler: [String: Any] = ["type": "command", "command": command, "timeout": 4]
        if self == .gemini {
            handler["timeout"] = 4000
            handler["name"] = "inputtranslator-\(event)"
        } else if self == .codex, event == "SessionEnd" {
            handler["timeout"] = 3
        }
        return handler
    }

    fileprivate func hooksDisabled(in settings: [String: Any], command: String) -> Bool {
        switch self {
        case .claude: return settings["disableAllHooks"] as? Bool == true
        case .codex: return false
        case .gemini:
            let options = settings["hooksConfig"] as? [String: Any]
            let disabled = options?["disabled"] as? [String] ?? []
            return options?["enabled"] as? Bool == false || disabled.contains(command)
                || events.contains { disabled.contains("inputtranslator-\($0)") }
        }
    }
}

nonisolated struct TerminalHookInstaller: Sendable {
    static let legacyArgument = "--inputtranslator-claude-hook"
    static let argument = "--inputtranslator-terminal-hook"
    private static let configurationLimit = 8 * 1024 * 1024

    enum Status: Equatable {
        case unconfigured, configured, needsRepair, disabled, unavailable

        var title: String {
            switch self {
            case .unconfigured: L10n.text("未连接")
            case .configured: L10n.text("已配置")
            case .needsRepair: L10n.text("需要修复")
            case .disabled: L10n.text("Hooks 已停用")
            case .unavailable: L10n.text("无法读取配置")
            }
        }
    }

    enum Failure: LocalizedError {
        case unexpectedSettingsFormat, missingExecutable, replacedSettings

        var errorDescription: String? {
            switch self {
            case .unexpectedSettingsFormat: L10n.text("配置文件的 JSON 或 hook 格式无效。")
            case .missingExecutable: L10n.text("无法找到 InputTranslator 可执行文件。")
            case .replacedSettings: L10n.text("配置刚被其他程序修改，请重试。")
            }
        }
    }

    let assistant: TerminalAssistant
    private let configuration: URL
    private let executable: URL?

    init(_ assistant: TerminalAssistant, configuration: URL? = nil, executable: URL? = Bundle.main.executableURL) {
        self.assistant = assistant
        self.configuration = configuration ?? assistant.configurationURL
        self.executable = executable
    }

    private var command: String? {
        executable.map { "\(quoted($0.path)) \(assistant.hookArgument)" }
    }

    func status() throws -> Status {
        guard let command else { throw Failure.missingExecutable }
        let url = configuration.resolvingSymlinksInPath()
        let contents = try withConfigurationDirectory(at: url) { try read(url, in: $0)?.data } ?? nil
        let settings = try parse(contents ?? Data("{}".utf8))
        if assistant.hooksDisabled(in: settings, command: command) { return .disabled }
        let hooks = try hookMap(in: settings)
        var total = 0
        var readyEvents = 0
        for event in assistant.events {
            var usable = 0
            for group in try groups(for: event, in: hooks) {
                for handler in try commands(in: group) where owns(handler) {
                    total += 1
                    if handler["command"] as? String == command,
                       (group["matcher"] as? String ?? "").isEmpty {
                        usable += 1
                    }
                }
            }
            if usable == 1 { readyEvents += 1 }
        }
        if total == 0 { return .unconfigured }
        if total == assistant.events.count, readyEvents == total {
            return .configured
        }
        return .needsRepair
    }

    func update(install: Bool) throws {
        let resolved = configuration.resolvingSymlinksInPath()
        guard let command else { throw Failure.missingExecutable }
        if install {
            try FileManager.default.createDirectory(
                at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        _ = try withConfigurationDirectory(at: resolved) { directory in
            let original = try read(resolved, in: directory)
            if !install, original == nil { return }
            guard let updated = try mergedSettings(original?.data ?? Data("{}".utf8), command: install ? command : nil)
            else { return }
            guard updated.count <= Self.configurationLimit else { throw POSIXError(.EFBIG) }
            try LocalFile.replace(at: directory, name: resolved.lastPathComponent, with: updated,
                                  mode: original?.mode ?? 0o600) {
                guard configuration.resolvingSymlinksInPath() == resolved,
                      try read(resolved, in: directory) == original else { throw Failure.replacedSettings }
            }
        }
    }

    func mergedSettings(_ original: Data, command: String?) throws -> Data? {
        let previous = try parse(original)
        var settings = previous
        var hooks = try hookMap(in: settings)
        for event in assistant.events {
            var updated: [[String: Any]] = []
            for var group in try groups(for: event, in: hooks) {
                let existing = try commands(in: group)
                let remaining = existing.filter { !owns($0) }
                if remaining.count == existing.count || !remaining.isEmpty {
                    group["hooks"] = remaining
                    updated.append(group)
                }
            }
            if let command {
                updated.append(["hooks": [assistant.handler(command: command, event: event)]])
            }
            if updated.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = updated }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        if (previous as NSDictionary).isEqual(to: settings) { return nil }
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            + Data([0x0A])
    }

    private func owns(_ handler: [String: Any]) -> Bool {
        guard handler["type"] as? String == "command", let value = handler["command"] as? String else { return false }
        if value == command { return true }
        let suffix = " " + assistant.hookArgument
        guard value.hasSuffix(suffix) else { return false }
        let executable = value.dropLast(suffix.count)
        guard executable.count >= 2, executable.first == "'", executable.last == "'" else { return false }
        let path = executable.dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
        guard path.hasPrefix("/"), executable == quoted(path) else { return false }
        let components = URL(fileURLWithPath: path).pathComponents
        return components.suffix(3) == ["Contents", "MacOS", "InputTranslator"]
            && components.dropLast(3).last?.hasSuffix(".app") == true
    }

    private func quoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func withConfigurationDirectory<T>(at url: URL, _ action: (Int32) throws -> T) throws -> T? {
        let fd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw LocalFile.error() }
        defer { close(fd) }
        return try action(fd)
    }

    private func read(_ url: URL, in directory: Int32) throws -> LocalFile.Snapshot? {
        try LocalFile.read(at: directory, name: url.lastPathComponent, limit: Self.configurationLimit)
    }

    private func parse(_ original: Data) throws -> [String: Any] {
        guard let document = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
            throw Failure.unexpectedSettingsFormat
        }
        return document
    }

    private func hookMap(in settings: [String: Any]) throws -> [String: Any] {
        guard let hooks = settings["hooks", default: [String: Any]()] as? [String: Any] else {
            throw Failure.unexpectedSettingsFormat
        }
        return hooks
    }

    private func groups(for event: String, in hooks: [String: Any]) throws -> [[String: Any]] {
        guard let groups = hooks[event, default: [[String: Any]]()] as? [[String: Any]] else {
            throw Failure.unexpectedSettingsFormat
        }
        return groups
    }

    private func commands(in group: [String: Any]) throws -> [[String: Any]] {
        guard let commands = group["hooks"] as? [[String: Any]] else { throw Failure.unexpectedSettingsFormat }
        return commands
    }
}
