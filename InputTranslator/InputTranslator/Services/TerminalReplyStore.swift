import Darwin
import Foundation

nonisolated struct TerminalJob: Codable, Equatable {
    let device: UInt32
    let group: pid_t
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func forHook() -> Self? {
        var pid = getppid()
        for _ in 0..<16 {
            guard pid > 1, let process = processInfo(pid) else { return nil }
            if process.e_tdev != UInt32.max, process.pbi_pgid > 1,
               let group = groupIdentity(process.pbi_pgid, on: process.e_tdev) {
                return group
            }
            pid = pid_t(exactly: process.pbi_ppid) ?? 0
        }
        return nil
    }

    static func foreground(in tty: String) -> Self? {
        guard tty.range(of: #"^/dev/ttys[0-9A-Za-z]+$"#, options: .regularExpression) != nil else { return nil }
        var info = stat()
        guard stat(tty, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { return nil }
        let device = UInt32(bitPattern: info.st_rdev)
        let capacity = 256
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_TTY_ONLY), device, buffer.baseAddress, Int32(buffer.count))
        }
        let count = max(0, Int(bytes) / MemoryLayout<pid_t>.size)
        for pid in pids.prefix(count) {
            if pid > 1, let process = processInfo(pid), process.e_tdev == device,
               process.e_tpgid > 1, let group = groupIdentity(process.e_tpgid, on: device) {
                return group
            }
        }
        return nil
    }

    var isAlive: Bool {
        guard let process = processInfo(group) else { return false }
        return process.e_tdev == device && process.pbi_start_tvsec == startedSeconds
            && process.pbi_start_tvusec == startedMicroseconds
    }

    private static func groupIdentity(_ id: UInt32, on device: UInt32) -> Self? {
        guard let pid = pid_t(exactly: id), let process = processInfo(pid),
              process.pbi_pgid == id, process.e_tdev == device else { return nil }
        return Self(device: device, group: pid, startedSeconds: process.pbi_start_tvsec,
                    startedMicroseconds: process.pbi_start_tvusec)
    }
}

nonisolated private func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
    return info
}

nonisolated struct TerminalHookInput {
    static let maximumInputBytes = 4 * 1024 * 1024
    enum Event {
        case sessionStart, finishedReply, sessionEnd
    }

    let event: Event
    let session: String
    let message: String?

    static func decode(_ data: Data, from assistant: TerminalAssistant) throws -> Self? {
        struct Payload: Decodable {
            let hook_event_name: String
            let session_id: String
            let last_assistant_message: String?
            let prompt_response: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let event: Event
        switch payload.hook_event_name {
        case "SessionStart": event = .sessionStart
        case "SessionEnd": event = .sessionEnd
        case assistant.eventName: event = .finishedReply
        default: return nil
        }
        return Self(event: event, session: payload.session_id,
                    message: assistant == .gemini ? payload.prompt_response : payload.last_assistant_message)
    }
}

nonisolated struct TerminalReply: Sendable {
    let assistant: TerminalAssistant
    let text: String
}

nonisolated struct TerminalReplyStore {
    private static let cacheName = "replies.json"
    private static let cacheLimit = 16 * 1024 * 1024
    private static let sessionLimit = 64
    private struct Entry: Codable {
        let job: TerminalJob
        let session: String
        let assistant: TerminalAssistant?
        let reply: String?
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.userTemporaryDirectory().appendingPathComponent(
            "com.claycosmos.InputTranslator.claude-replies", isDirectory: true
        )
    }

    private static func userTemporaryDirectory() -> URL {
        // Use a common directory even if the terminal's login shell overrides TMPDIR.
        let key = Int32(_CS_DARWIN_USER_TEMP_DIR)
        let size = confstr(key, nil, 0)
        if size > 0 {
            var path = [CChar](repeating: 0, count: size)
            if confstr(key, &path, size) == size {
                return URL(fileURLWithPath: String(cString: path), isDirectory: true)
            }
        }
        return URL.cachesDirectory
    }

    func receive(_ input: TerminalHookInput, assistant: TerminalAssistant, from job: TerminalJob) throws {
        guard !input.session.isEmpty, input.session.utf8.count <= 1024 else { return }
        if input.event == .finishedReply {
            guard let message = input.message, message.utf8.count <= TerminalHookInput.maximumInputBytes,
                  !message.allSatisfy(\.isWhitespace) else { return }
        }
        let directoryFD = try openDirectory(create: true)
        defer { close(directoryFD) }
        try withLock(in: directoryFD) {
            let previous: [Entry]
            do {
                previous = try load(in: directoryFD)
            } catch is DecodingError {
                previous = []
            } catch let error as POSIXError where error.code == .EFBIG {
                previous = []
            }
            var entries = previous.filter { $0.job == job || $0.job.isAlive }
            let index = entries.firstIndex { $0.job == job }
            let matchesCurrent = index.map {
                entries[$0].session == input.session && (entries[$0].assistant ?? .claude) == assistant
            } ?? false
            switch input.event {
            case .sessionStart:
                if matchesCurrent { return }
                if let index { entries.remove(at: index) }
                entries.append(Entry(job: job, session: input.session, assistant: assistant, reply: nil))
            case .finishedReply:
                guard let message = input.message else { return }
                if let index {
                    guard matchesCurrent else { return }
                    if entries[index].reply == message { return }
                    entries.remove(at: index)
                }
                entries.append(Entry(job: job, session: input.session, assistant: assistant, reply: message))
            case .sessionEnd:
                guard let index, matchesCurrent else { return }
                entries.remove(at: index)
            }
            let encoder = JSONEncoder()
            var retained = entries.suffix(Self.sessionLimit)
            var data = try encoder.encode(Array(retained))
            while data.count > Self.cacheLimit, retained.count > 1 {
                retained = retained.dropFirst(retained.count / 2)
                data = try encoder.encode(Array(retained))
            }
            guard data.count <= Self.cacheLimit else { throw POSIXError(.EFBIG) }
            try LocalFile.replace(at: directoryFD, name: Self.cacheName, with: data, mode: 0o600)
        }
    }

    func latest(for job: TerminalJob) throws -> TerminalReply? {
        let fd: Int32
        do { fd = try openDirectory(create: false) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        defer { close(fd) }
        // A reader sees either the previous file or the complete atomic replacement.
        guard let entry = try load(in: fd).first(where: { $0.job == job }), let reply = entry.reply else { return nil }
        return TerminalReply(assistant: entry.assistant ?? .claude, text: reply)
    }

    @MainActor
    func observeChanges(_ didChange: @escaping @MainActor () -> Void) throws -> DispatchSourceFileSystemObject {
        let fd = try openDirectory(create: true)
        // The hook atomically replaces the cache file, so observe its directory.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { didChange() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func load(in directory: Int32) throws -> [Entry] {
        guard let file = try LocalFile.read(at: directory, name: Self.cacheName, limit: Self.cacheLimit) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: file.data)
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw LocalFile.error() }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalFile.error() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            throw POSIXError(.EPERM)
        }
        return fd
    }

    private func withLock(in directory: Int32, _ action: () throws -> Void) throws {
        let fd = openat(directory, "lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalFile.error() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid() else { throw POSIXError(.EPERM) }
        let deadline = ContinuousClock.now + .seconds(1)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = LocalFile.error()
            guard (error.code == .EWOULDBLOCK || error.code == .EINTR), ContinuousClock.now < deadline else { throw error }
            usleep(10_000)
        }
        try action()
    }
}
