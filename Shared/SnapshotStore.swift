import Foundation
import Darwin

enum StoreError: Error { case unavailable, invalidSnapshot }

struct SnapshotStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("usage-snapshot.json") }

    // Exact path is paired with the widget's read-only file entitlement.
    // Do not use NSHomeDirectory: in an extension it resolves to its sandbox container.
    static func local() throws -> Self {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var bytes = [CChar](repeating: 0, count: 16384)
        let home: String? = bytes.withUnsafeMutableBufferPointer { buffer in
            guard getpwuid_r(getuid(), &record, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, let directory = record.pw_dir else { return nil }
            return String(cString: directory)
        }
        guard let home, home.hasPrefix("/") else { throw StoreError.unavailable }
        return Self(directory: URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/CodexUsageMonitor", isDirectory: true))
    }

    func read() throws -> UsageSnapshot {
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw StoreError.invalidSnapshot }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= 16384 else { throw StoreError.invalidSnapshot }
        let data = try handle.read(upToCount: 16385) ?? Data()
        guard data.count <= 16384 else { throw StoreError.invalidSnapshot }
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        guard snapshot.version == UsageSnapshot.schemaVersion else { throw StoreError.invalidSnapshot }
        guard snapshot.fiveHour == nil || snapshot.fiveHour?.durationMinutes == 300,
              snapshot.weekly == nil || snapshot.weekly?.durationMinutes == 10080,
              snapshot.bucketID == nil || RateLimitParser.validIdentifier(snapshot.bucketID ?? "") else {
            throw StoreError.invalidSnapshot
        }
        for date in [snapshot.updatedAt, snapshot.attemptedAt, snapshot.fiveHour?.resetsAt, snapshot.weekly?.resetsAt].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite, (0..<253402300800).contains(date.timeIntervalSince1970) else {
                throw StoreError.invalidSnapshot
            }
        }
        for window in [snapshot.fiveHour, snapshot.weekly].compactMap({ $0 }) {
            if let value = window.remainingPercent, !value.isFinite || !(0...100).contains(value) {
                throw StoreError.invalidSnapshot
            }
        }
        return snapshot
    }

    func write(_ snapshot: UsageSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 16384 else { throw StoreError.invalidSnapshot }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw StoreError.unavailable }
        defer { close(folder) }
        var metadata = stat()
        guard fstat(folder, &metadata) == 0, metadata.st_uid == getuid(),
              fchmod(folder, 0o700) == 0 else { throw StoreError.unavailable }
        // Pin the directory inode and create the replacement privately before writing.
        // renameat replaces a malicious destination symlink instead of following it.
        let temporaryName = ".snapshot-" + UUID().uuidString
        let descriptor = openat(folder, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StoreError.unavailable }
        defer { close(descriptor); unlinkat(folder, temporaryName, 0) }
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { throw StoreError.invalidSnapshot }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.unavailable }
                offset += count
            }
        }
        guard renameat(folder, temporaryName, folder, "usage-snapshot.json") == 0 else {
            throw StoreError.unavailable
        }
    }
}
