import AppKit
import Carbon

@MainActor
enum PasteService {
    struct Environment {
        var board: NSPasteboard = .general
        var restoreFocus: (ApplicationTarget) async throws -> Void = ApplicationTargetManager.restoreFocus
        var matchesFocus: (ApplicationTarget) async -> Bool = ApplicationTargetManager.matchesFocusedTarget
        var post: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }
        var waitForPaste: () async -> Void = { try? await Task.sleep(for: .milliseconds(350)) }
    }

    enum Outcome: Equatable {
        case pastePosted, enterPosted, enterSkipped
    }

    static func paste(
        _ text: String,
        into target: ApplicationTarget,
        autoSubmit: Bool,
        preserveClipboard: Bool,
        willPostPaste: () -> Void,
        environment: Environment? = nil
    ) async throws -> Outcome {
        let environment = environment ?? Environment()
        guard allowsPaste(text) else { throw PasteFailure.controlCharacters }
        let shouldSubmit = autoSubmit && !requiresConfirmation(text: text)
        try await environment.restoreFocus(target)
        try Task.checkCancellation()

        guard let paste = keyEvents(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            throw PasteFailure.event
        }
        let enter = shouldSubmit ? keyEvents(key: CGKeyCode(kVK_Return), flags: []) : nil
        let board = environment.board
        let originalChangeCount = board.changeCount
        let saved = preserveClipboard ? try snapshot(board) : []
        guard await environment.matchesFocus(target) else { throw PasteFailure.focusChanged }
        guard board.changeCount == originalChangeCount else { throw PasteFailure.clipboard }

        let writtenChangeCount = board.declareTypes([.string], owner: nil)
        defer {
            if preserveClipboard, board.changeCount == writtenChangeCount {
                board.clearContents()
                if !saved.isEmpty { board.writeObjects(saved) }
            }
        }
        guard board.changeCount == writtenChangeCount, board.setString(text, forType: .string) else {
            throw PasteFailure.clipboard
        }
        guard await environment.matchesFocus(target) else { throw PasteFailure.focusChanged }
        guard board.changeCount == writtenChangeCount else { throw PasteFailure.clipboard }
        try Task.checkCancellation()

        willPostPaste()
        environment.post(paste.down, target.pid)
        environment.post(paste.up, target.pid)

        // Allow the destination's paste handler to read the pasteboard before restoring it.
        await environment.waitForPaste()
        guard shouldSubmit else { return autoSubmit ? .enterSkipped : .pastePosted }
        guard !Task.isCancelled, board.changeCount == writtenChangeCount,
              await environment.matchesFocus(target), let enter else { return .enterSkipped }
        guard !Task.isCancelled, board.changeCount == writtenChangeCount else { return .enterSkipped }
        environment.post(enter.down, target.pid)
        environment.post(enter.up, target.pid)
        return .enterPosted
    }

    static func allowsPaste(_ text: String) -> Bool {
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
        guard originals.count <= 1_024 else { throw PasteFailure.clipboard }
        var remainingBytes = byteLimit
        var remainingTypes = 4_096
        return try originals.map { original in
            let item = NSPasteboardItem()
            let types = original.types
            remainingTypes -= types.count
            guard remainingTypes >= 0, !types.isEmpty else { throw PasteFailure.clipboard }
            for type in types {
                guard let data = original.data(forType: type), data.count <= remainingBytes,
                      item.setData(data, forType: type) else {
                    throw PasteFailure.clipboard
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
