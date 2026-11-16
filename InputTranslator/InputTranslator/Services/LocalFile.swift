import Darwin
import Foundation

nonisolated enum LocalFile {
    struct Snapshot: Equatable {
        let data: Data
        let mode: mode_t
        let device: dev_t
        let inode: ino_t
    }

    static func read(at directory: Int32, name: String, limit: Int) throws -> Snapshot? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw error() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw error() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw POSIXError(.EPERM) }
        guard info.st_size <= limit else { throw POSIXError(.EFBIG) }
        let data = try read(FileHandle(fileDescriptor: fd, closeOnDealloc: false), limit: limit)
        return Snapshot(data: data, mode: info.st_mode & 0o777, device: info.st_dev, inode: info.st_ino)
    }

    static func read(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, limit + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { throw POSIXError(.EFBIG) }
        }
        return data
    }

    static func replace(at directory: Int32, name: String, with data: Data, mode: mode_t,
                        beforeRename: () throws -> Void = {}) throws {
        let temporary = ".inputtranslator-\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error() }
        defer {
            close(fd)
            unlinkat(directory, temporary, 0)
        }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        try beforeRename()
        guard fchmod(fd, mode) == 0 else { throw error() }
        guard renameat(directory, temporary, directory, name) == 0 else { throw error() }
    }

    static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
