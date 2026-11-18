import Foundation

nonisolated struct HerdrFocus: Equatable, Sendable {
    let space: String
    let tab: String
    let pane: String
    let terminal: String
}

/// Herdr's canvas exposes a window rather than a text field through Accessibility.
/// Its read-only CLI supplies the pane identity needed to reject a changed target.
nonisolated enum HerdrAdapter {
    enum Failure: Error { case unavailable }

    static func focus(in executable: URL) async throws -> HerdrFocus {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let status = try query(executable, argument: "status")
            try Task.checkCancellation()
            let layout = try query(executable, argument: "ls")
            return try decodeFocus(status: status, layout: layout)
        }
        let focus = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        return focus
    }

    static func decodeFocus(status: Data, layout: Data) throws -> HerdrFocus {
        struct Status: Decodable {
            let space: String
            let tab: String
            let focused_pane: String
            let overlays: [String]
        }
        struct Layout: Decodable {
            struct Space: Decodable {
                struct Tab: Decodable {
                    struct Terminal: Decodable { let terminal: String; let pane: String }
                    let id: String
                    let active: Bool
                    let terminals: [Terminal]
                }
                let id: String
                let active: Bool
                let tabs: [Tab]
            }
            let spaces: [Space]
        }
        let decoder = JSONDecoder()
        let status = try decoder.decode(Status.self, from: status)
        let layout = try decoder.decode(Layout.self, from: layout)
        guard status.overlays.isEmpty,
              let space = layout.spaces.first(where: { $0.id == status.space && $0.active }),
              let tab = space.tabs.first(where: { $0.id == status.tab && $0.active }),
              let terminal = tab.terminals.first(where: { $0.pane == status.focused_pane }),
              !terminal.terminal.isEmpty, !terminal.pane.isEmpty else { throw Failure.unavailable }
        return HerdrFocus(space: space.id, tab: tab.id, pane: terminal.pane, terminal: terminal.terminal)
    }

    private static func query(_ executable: URL, argument: String) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = [argument]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Neither a stalled app socket nor a large layout may hold up the input workflow.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.7, execute: deadline)
        defer {
            deadline.cancel()
            try? pipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }
        var data = Data()
        while let part = try pipe.fileHandleForReading.read(upToCount: 8_192), !part.isEmpty {
            guard data.count + part.count <= 256 * 1_024 else { throw Failure.unavailable }
            data.append(part)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.unavailable }
        return data
    }
}
