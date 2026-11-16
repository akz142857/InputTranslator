import Darwin
import Foundation
import XCTest
@testable import InputTranslator

final class TerminalReplyTests: XCTestCase {
    @MainActor func testObservesConsecutiveRepliesWrittenByTheHook() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TerminalReplyStore(directory: directory)
        let job = TerminalJob(device: 1, group: 42, startedSeconds: 67, startedMicroseconds: 89)
        let first = expectation(description: "First completed reply")
        let second = expectation(description: "Second completed reply")
        var received = [String]()
        let changes = try store.observeChanges {
            guard let reply = try? store.latest(for: job), received.last != reply.text else { return }
            received.append(reply.text)
            if reply.text == "First reply" { first.fulfill() }
            if reply.text == "Second reply" { second.fulfill() }
        }
        defer {
            changes.cancel()
            try? FileManager.default.removeItem(at: directory)
        }

        try store.receive(TerminalHookInput(event: .finishedReply, session: "session", message: "First reply"),
                          assistant: .claude, from: job)
        await fulfillment(of: [first], timeout: 2)
        try store.receive(TerminalHookInput(event: .finishedReply, session: "session", message: "Second reply"),
                          assistant: .claude, from: job)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(received, ["First reply", "Second reply"])
    }

    @MainActor func testLatestReplyTracksSessionLifecycleAndAssistant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalReplyStore(directory: directory)
        let job = TerminalJob(device: 1, group: 42, startedSeconds: 67, startedMicroseconds: 89)
        let differentJob = TerminalJob(device: 1, group: 42, startedSeconds: 68, startedMicroseconds: 89)

        func send(_ assistant: TerminalAssistant, _ event: TerminalHookInput.Event, _ session: String,
                  _ message: String? = nil) throws {
            try store.receive(TerminalHookInput(event: event, session: session, message: message),
                              assistant: assistant, from: job)
        }

        try send(.claude, .finishedReply, "one", "First response")
        try send(.claude, .sessionStart, "one")
        XCTAssertEqual(try store.latest(for: job)?.text, "First response")
        try send(.claude, .finishedReply, "one", "Latest response")
        try send(.claude, .finishedReply, "one", " \n ")
        XCTAssertEqual(try store.latest(for: job)?.text, "Latest response")
        XCTAssertNil(try store.latest(for: differentJob))

        try send(.gemini, .sessionStart, "one")
        try send(.claude, .finishedReply, "one", "Stale response")
        XCTAssertNil(try store.latest(for: job))
        try send(.gemini, .finishedReply, "one", "Current session")
        try send(.claude, .sessionEnd, "one")
        XCTAssertEqual(try store.latest(for: job)?.text, "Current session")
        XCTAssertEqual(try store.latest(for: job)?.assistant, .gemini)
        try send(.gemini, .sessionEnd, "one")
        XCTAssertNil(try store.latest(for: job))
    }

    @MainActor func testReplyCacheRecoversFromCorruptionAndKeepsPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TerminalReplyStore(directory: directory)
        let job = TerminalJob(device: 1, group: 42, startedSeconds: 67, startedMicroseconds: 89)
        let reply = TerminalHookInput(event: .finishedReply, session: "session", message: "Reply")
        try store.receive(reply, assistant: .codex, from: job)
        let cache = directory.appendingPathComponent("replies.json")
        try Data("corrupt".utf8).write(to: cache)
        try store.receive(reply, assistant: .codex, from: job)
        XCTAssertEqual(try store.latest(for: job)?.text, "Reply")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)

        let lock = open(directory.appendingPathComponent("lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(try store.latest(for: job)?.text, "Reply")
    }

    @MainActor func testReplyCacheRejectsLinkedFilesAndSharedDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let store = TerminalReplyStore(directory: directory)
        let job = TerminalJob(device: 1, group: 42, startedSeconds: 67, startedMicroseconds: 89)
        let reply = TerminalHookInput(event: .finishedReply, session: "session", message: "Reply")
        let destination = directory.appendingPathComponent("unrelated")
        let original = Data("unrelated".utf8)
        try original.write(to: destination)
        let cache = directory.appendingPathComponent("replies.json")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: destination)
        XCTAssertThrowsError(try store.latest(for: job))
        XCTAssertThrowsError(try store.receive(reply, assistant: .codex, from: job))
        XCTAssertEqual(try Data(contentsOf: destination), original)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.receive(reply, assistant: .codex, from: job)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EPERM)
        }
    }

    @MainActor func testBoundedHookReadAcceptsExactLimitAndRejectsLargerInput() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = Data(repeating: 0x20, count: 128 * 1024)
        try expected.write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        XCTAssertEqual(try LocalFile.read(handle, limit: expected.count), expected)
        try handle.seek(toOffset: 0)
        XCTAssertThrowsError(try LocalFile.read(handle, limit: expected.count - 1)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EFBIG)
        }
    }

    @MainActor func testInstallerDetectsMissingMovedAndRemovedHooksWithoutChangingOtherSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for assistant in TerminalAssistant.allCases {
            let external = ["type": "command", "command": "'/opt/another tool' \(assistant.hookArgument)"]
            let original = try JSONSerialization.data(withJSONObject: ["model": "default", "hooks": [
                "SessionStart": [["matcher": "startup", "hooks": [["type": "command", "command": "other-tool"]]]],
                assistant.eventName: [["hooks": [external]]],
            ]])
            let config = directory.appendingPathComponent(assistant.rawValue + ".json")
            try original.write(to: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)
            let oldApp = URL(fileURLWithPath: "/old location/InputTranslator.app/Contents/MacOS/InputTranslator")
            let newApp = URL(fileURLWithPath: "/new location's/InputTranslator.app/Contents/MacOS/InputTranslator")
            let originalInstaller = TerminalHookInstaller(assistant, configuration: config, executable: oldApp)
            let relocatedInstaller = TerminalHookInstaller(assistant, configuration: config, executable: newApp)

            XCTAssertEqual(try originalInstaller.status(), .unconfigured)
            XCTAssertEqual(try Data(contentsOf: config), original)
            try originalInstaller.update(install: true)
            XCTAssertEqual(try originalInstaller.status(), .configured)
            XCTAssertEqual(try relocatedInstaller.status(), .needsRepair)
            let installed = try Data(contentsOf: config)
            try originalInstaller.update(install: true)
            XCTAssertEqual(try Data(contentsOf: config), installed)
            try relocatedInstaller.update(install: true)
            XCTAssertEqual(try relocatedInstaller.status(), .configured)
            XCTAssertFalse(String(decoding: try Data(contentsOf: config), as: UTF8.self).contains(oldApp.path))

            let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
            let hooks = try XCTUnwrap(updated["hooks"] as? [String: [[String: Any]]])
            let completion = try XCTUnwrap(hooks[assistant.eventName]?.last?["hooks"] as? [[String: Any]])
            XCTAssertEqual(completion.first?["timeout"] as? Int, assistant == .gemini ? 4000 : 4)
            try relocatedInstaller.update(install: false)
            XCTAssertEqual(try relocatedInstaller.status(), .unconfigured)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int, 0o640)
            let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
            let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary)
            XCTAssertEqual(expected, restored)
        }
    }

    @MainActor func testInstallerUsesPrivatePermissionsAndPreservesLinkedSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("settings.json")
        let installer = TerminalHookInstaller(.claude, configuration: config)
        try installer.update(install: true)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int, 0o600)
        let link = directory.appendingPathComponent("linked-settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        let linked = TerminalHookInstaller(.claude, configuration: link)
        XCTAssertEqual(try linked.status(), .configured)
        try linked.update(install: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), config.path)
        XCTAssertEqual(try installer.status(), .unconfigured)
    }

    @MainActor func testResponseFieldsAndOptOutSettings() throws {
        let codex = Data(#"{"hook_event_name":"Stop","session_id":"abc","last_assistant_message":"Codex response"}"#.utf8)
        let gemini = Data(#"{"hook_event_name":"AfterAgent","session_id":"xyz","prompt":"Ignore this prompt","prompt_response":"Gemini response"}"#.utf8)
        XCTAssertEqual(try TerminalHookInput.decode(codex, from: .codex)?.message, "Codex response")
        XCTAssertEqual(try TerminalHookInput.decode(gemini, from: .gemini)?.message, "Gemini response")
        XCTAssertNil(try TerminalHookInput.decode(gemini, from: .claude))

        let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: config) }
        try Data(#"{"disableAllHooks":true}"#.utf8).write(to: config)
        XCTAssertEqual(try TerminalHookInstaller(.claude, configuration: config).status(), .disabled)
        try Data(#"{"hooksConfig":{"enabled":false}}"#.utf8).write(to: config)
        XCTAssertEqual(try TerminalHookInstaller(.gemini, configuration: config).status(), .disabled)
    }
}
