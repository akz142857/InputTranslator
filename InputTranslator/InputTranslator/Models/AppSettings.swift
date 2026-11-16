import AppKit
import Carbon
import Combine
import ServiceManagement

enum TerminalChoice: String, CaseIterable, Identifiable {
    case lastActive, terminal, iTerm

    var id: Self { self }

    var title: String {
        switch self {
        case .lastActive: L10n.text("当前终端")
        case .terminal: "Terminal"
        case .iTerm: "iTerm2"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .lastActive: nil
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        }
    }

    static func matches(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier != nil && allCases.contains { $0.bundleIdentifier == bundleIdentifier }
    }
}

struct Hotkey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let standard = Self(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey), keyLabel: "Space")
    static let readReply = Self(
        keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey | shiftKey), keyLabel: "Space"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.characters(byApplyingModifiers: []),
              let character = characters.first else { return nil }

        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }

        let label: String
        switch Int(event.keyCode) {
        case kVK_Space: label = "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: label = "↵"
        case kVK_Tab: label = "⇥"
        case kVK_Escape: label = "Esc"
        case kVK_Delete: label = "⌫"
        case kVK_ForwardDelete: label = "⌦"
        case kVK_LeftArrow: label = "←"
        case kVK_RightArrow: label = "→"
        case kVK_UpArrow: label = "↑"
        case kVK_DownArrow: label = "↓"
        default:
            if let functionKey = character.unicodeScalars.first, (0xF704...0xF726).contains(functionKey.value) {
                label = "F\(functionKey.value - 0xF704 + 1)"
            } else {
                guard !character.isWhitespace, !character.isNewline else { return nil }
                label = String(character).uppercased()
            }
        }
        guard !(modifiers == cmdKey && [kVK_Return, kVK_ANSI_KeypadEnter, kVK_ANSI_A, kVK_ANSI_Q,
                                       kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z].contains(Int(event.keyCode)))
        else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), keyLabel: label)
    }

    var title: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (keyCode == UInt32(kVK_Space) ? L10n.text("Space") : keyLabel)
    }
}

@MainActor
final class AppSettings: ObservableObject {
    private static let dockSidePreferenceKey = "keepDockedPanelBesideLauncher"
    private let defaults: UserDefaults

    @Published var autoSubmit: Bool { didSet { defaults.set(autoSubmit, forKey: "autoSubmit") } }
    @Published var terminal: TerminalChoice { didSet { defaults.set(terminal.rawValue, forKey: "targetTerminal") } }
    @Published var clearAfterPaste: Bool { didSet { defaults.set(clearAfterPaste, forKey: "clearInputAfterSuccess") } }
    @Published var preserveClipboard: Bool { didSet { defaults.set(preserveClipboard, forKey: "preserveClipboard") } }
    @Published var panelPinned: Bool { didSet { defaults.set(panelPinned, forKey: "panelPinned") } }
    @Published var topDockEnabled: Bool { didSet { defaults.set(topDockEnabled, forKey: "topDockEnabled") } }
    @Published var panelDetached: Bool { didSet { defaults.set(panelDetached, forKey: "topDockPanelDetached") } }
    @Published var interfaceLanguage: InterfaceLanguage {
        didSet { defaults.set(interfaceLanguage.rawValue, forKey: L10n.preferenceKey) }
    }
    @Published var translationPair: TranslationPair {
        didSet { defaults.set([translationPair.source.id, translationPair.target.id], forKey: "translationLanguages") }
    }
    @Published private(set) var hotkey: Hotkey
    @Published private(set) var loginStatus: SMAppService.Status
    private(set) var pinnedPanelPlacement: PinnedPanelPlacement?
    private(set) var dockedPanelPlacement: PinnedPanelPlacement?
    private(set) var topDockLauncherPlacement: PinnedPanelPlacement?
    var dockedBesideLauncher: Bool { didSet { defaults.set(dockedBesideLauncher, forKey: Self.dockSidePreferenceKey) } }

    var prefersTopDock: Bool { topDockEnabled && !panelDetached }

    init(defaults: UserDefaults = .standard, preferredLanguage: String? = Locale.preferredLanguages.first) {
        self.defaults = defaults
        defaults.register(defaults: ["clearInputAfterSuccess": true, "preserveClipboard": true, "topDockEnabled": true])
        autoSubmit = defaults.bool(forKey: "autoSubmit")
        terminal = TerminalChoice(rawValue: defaults.string(forKey: "targetTerminal") ?? "") ?? .lastActive
        clearAfterPaste = defaults.bool(forKey: "clearInputAfterSuccess")
        preserveClipboard = defaults.bool(forKey: "preserveClipboard")
        let wasPinned = defaults.bool(forKey: "panelPinned")
        panelPinned = wasPinned
        topDockEnabled = defaults.bool(forKey: "topDockEnabled")
        if defaults.object(forKey: Self.dockSidePreferenceKey) != nil {
            dockedBesideLauncher = defaults.bool(forKey: Self.dockSidePreferenceKey)
        } else {
            // The old key was only set after re-docking. Reopening could then overwrite it with false.
            dockedBesideLauncher = defaults.object(forKey: "dockedBesideLauncher") != nil
        }
        interfaceLanguage = defaults.string(forKey: L10n.preferenceKey)
            .flatMap(InterfaceLanguage.init(rawValue:)) ?? .defaultChoice
        if let languages = defaults.stringArray(forKey: "translationLanguages"), languages.count == 2 {
            let pair = TranslationPair(source: TranslationLanguage(languages[0]), target: TranslationLanguage(languages[1]))
            translationPair = pair.isSelectable ? pair : .systemDefault(preferredLanguage: preferredLanguage)
        } else {
            translationPair = .systemDefault(preferredLanguage: preferredLanguage)
        }
        let floatingPlacement = Self.loadPlacement("pinnedPanelPlacement", from: defaults)
        let dockedPlacement = Self.loadPlacement("dockedPanelPlacement", from: defaults)
        pinnedPanelPlacement = floatingPlacement
        dockedPanelPlacement = dockedPlacement
        topDockLauncherPlacement = Self.loadPlacement("topDockLauncherPlacement", from: defaults)
        if defaults.object(forKey: "topDockPanelDetached") != nil {
            panelDetached = defaults.bool(forKey: "topDockPanelDetached")
        } else {
            // Existing pinned floating windows should reopen at their saved position.
            panelDetached = wasPinned && floatingPlacement != nil && dockedPlacement == nil
        }
        if let keyLabel = defaults.string(forKey: "hotkeyLabel") {
            hotkey = Hotkey(
                keyCode: UInt32(clamping: defaults.integer(forKey: "hotkeyKeyCode")),
                modifiers: UInt32(clamping: defaults.integer(forKey: "hotkeyModifiers")),
                keyLabel: keyLabel
            )
        } else {
            hotkey = .standard
        }
        loginStatus = SMAppService.mainApp.status
    }

    private static func loadPlacement(_ key: String, from defaults: UserDefaults) -> PinnedPanelPlacement? {
        guard let data = defaults.data(forKey: key),
              let placement = try? JSONDecoder().decode(PinnedPanelPlacement.self, from: data),
              !placement.frame.isEmpty, !placement.screenFrame.isEmpty else { return nil }
        return placement
    }

    func savePanelPlacement(_ placement: PinnedPanelPlacement, docked: Bool) {
        let previous = docked ? dockedPanelPlacement : pinnedPanelPlacement
        guard placement != previous, let data = try? JSONEncoder().encode(placement) else { return }
        if docked {
            dockedPanelPlacement = placement
            defaults.set(data, forKey: "dockedPanelPlacement")
        } else {
            pinnedPanelPlacement = placement
            defaults.set(data, forKey: "pinnedPanelPlacement")
        }
    }

    func saveTopDockLauncherPlacement(_ placement: PinnedPanelPlacement?) {
        topDockLauncherPlacement = placement
        defaults.set(placement.flatMap { try? JSONEncoder().encode($0) }, forKey: "topDockLauncherPlacement")
    }

    func saveHotkey(_ value: Hotkey) {
        hotkey = value
        defaults.set(value.keyCode, forKey: "hotkeyKeyCode")
        defaults.set(value.modifiers, forKey: "hotkeyModifiers")
        defaults.set(value.keyLabel, forKey: "hotkeyLabel")
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setStartsAtLogin(_ enabled: Bool) throws {
        defer { refreshLoginStatus() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
