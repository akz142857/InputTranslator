import AppKit
import Carbon

@MainActor
enum PasteService {
    enum Outcome: Equatable {
        case pastePosted, enterPosted, enterSkipped
    }

    static func paste(
        _ text: String,
        into target: TerminalTarget,
        autoSubmit: Bool,
        preserveClipboard: Bool,
        willPostPaste: () -> Void
    ) async throws -> Outcome {
        guard allowsTerminalPaste(text) else { throw TerminalFailure.controlCharacters }
        let shouldSubmit = autoSubmit && !requiresConfirmation(text: text)
        try await TerminalManager.restoreFocus(to: target)
        try Task.checkCancellation()

        guard let paste = keyEvents(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            throw TerminalFailure.event
        }
        let enter = shouldSubmit ? keyEvents(key: CGKeyCode(kVK_Return), flags: []) : nil
        let board = NSPasteboard.general
        let originalChangeCount = board.changeCount
        let saved = preserveClipboard ? try snapshot(board) : []
        guard TerminalManager.matchesFocusedTarget(target) else { throw TerminalFailure.focusChanged }
        guard board.changeCount == originalChangeCount else { throw TerminalFailure.clipboard }

        let writtenChangeCount = board.declareTypes([.string], owner: nil)
        defer {
            if preserveClipboard, board.changeCount == writtenChangeCount {
                board.clearContents()
                if !saved.isEmpty { board.writeObjects(saved) }
            }
        }
        guard board.changeCount == writtenChangeCount, board.setString(text, forType: .string) else {
            throw TerminalFailure.clipboard
        }
        guard TerminalManager.matchesFocusedTarget(target) else { throw TerminalFailure.focusChanged }
        guard board.changeCount == writtenChangeCount else { throw TerminalFailure.clipboard }
        try Task.checkCancellation()

        willPostPaste()
        paste.down.postToPid(target.pid)
        paste.up.postToPid(target.pid)

        // Allow the terminal's paste handler to read the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(350))
        guard shouldSubmit else { return autoSubmit ? .enterSkipped : .pastePosted }
        guard !Task.isCancelled, board.changeCount == writtenChangeCount,
              TerminalManager.matchesFocusedTarget(target), let enter else { return .enterSkipped }
        enter.down.postToPid(target.pid)
        enter.up.postToPid(target.pid)
        return .enterPosted
    }

    static func allowsTerminalPaste(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar == "\n" || scalar == "\t"
                || (scalar.properties.generalCategory != .control && !CharacterSet.newlines.contains(scalar))
        }
    }

    static func requiresConfirmation(text: String) -> Bool {
        text.contains(where: \.isNewline)
    }

    static func snapshot(_ board: NSPasteboard, byteLimit: Int = 64 * 1024 * 1024) throws -> [NSPasteboardItem] {
        let originals = board.pasteboardItems ?? []
        guard originals.count <= 1_024 else { throw TerminalFailure.clipboard }
        var remainingBytes = byteLimit
        var remainingTypes = 4_096
        return try originals.map { original in
            let item = NSPasteboardItem()
            let types = original.types
            remainingTypes -= types.count
            guard remainingTypes >= 0, !types.isEmpty else { throw TerminalFailure.clipboard }
            for type in types {
                guard let data = original.data(forType: type), data.count <= remainingBytes,
                      item.setData(data, forType: type) else {
                    throw TerminalFailure.clipboard
                }
                remainingBytes -= data.count
            }
            return item
        }
    }

    private static func keyEvents(key: CGKeyCode, flags: CGEventFlags) -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
        down.flags = flags
        up.flags = flags
        return (down, up)
    }
}
