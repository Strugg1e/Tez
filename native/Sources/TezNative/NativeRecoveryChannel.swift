import Foundation
import Darwin

final class NativeRecoveryChannel: @unchecked Sendable {
    private final class Descriptor {
        let value: Int32
        init(_ value: Int32) { self.value = value }
        deinit { close(value) }
    }
    private struct Ready: Decodable { let version: UInt8; let token: String }
    private struct Request: Encodable {
        let version: UInt8 = 1
        let sequence: UInt64
        let token: String
        let command = "retry-shutdown"
    }
    private struct Response: Decodable {
        let version: UInt8
        let sequence: UInt64
        let safeToExit: Bool
        let token: String
    }

    private let directory: String
    private let token: String
    private let heldDescriptor: Descriptor
    private var descriptor: Int32 { heldDescriptor.value }
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    var environment: [String: String] {
        ["TEZ_NATIVE_RECOVERY_DIR": directory, "TEZ_NATIVE_RECOVERY_TOKEN": token]
    }

    init() throws {
        directory = "/private/tmp/tez-native-recovery-\(UUID().uuidString)"
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        guard mkdir(directory, 0o700) == 0 else { throw Self.invalid() }
        let file = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { rmdir(directory); throw Self.invalid() }
        heldDescriptor = Descriptor(file)
        do { try validateDirectory() }
        catch { rmdir(directory); throw error }
    }

    func isReady() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? read("ready.json"), let ready = try? JSONDecoder().decode(Ready.self, from: data) else { return false }
        return ready.version == 1 && ready.token == token
    }

    func requestShutdown() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        try validateDirectory()
        _ = try read("request.json")
        guard sequence < UInt64.max else { throw Self.invalid() }
        let next = sequence + 1
        let data = try JSONEncoder().encode(Request(sequence: next, token: token))
        let temporary = ".request-\(UUID().uuidString)"
        let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Self.invalid() }
        defer { close(file); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.invalid() }
                written += count
            }
        }
        guard fchmod(file, 0o600) == 0, fsync(file) == 0,
              renameat(descriptor, temporary, descriptor, "request.json") == 0 else { throw Self.invalid() }
        sequence = next
        return next
    }

    func response(for sequence: UInt64) throws -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try read("response.json") else { return nil }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.sequence == sequence else { return nil }
        guard response.version == 1 && response.token == token else { throw Self.invalid() }
        return response.safeToExit
    }

    func removeAfterConfirmedExit() {
        lock.lock(); defer { lock.unlock() }
        guard (try? validateDirectory()) != nil else { return }
        for name in ["ready.json", "request.json", "response.json"] {
            if (try? read(name)) != nil { unlinkat(descriptor, name, 0) }
        }
        rmdir(directory)
    }

    private func validateDirectory() throws {
        var held = stat()
        var current = stat()
        guard fstat(descriptor, &held) == 0, lstat(directory, &current) == 0,
              (held.st_mode & S_IFMT) == S_IFDIR, held.st_uid == geteuid(),
              (held.st_mode & 0o7777) == 0o700,
              held.st_dev == current.st_dev, held.st_ino == current.st_ino,
              (current.st_mode & S_IFMT) == S_IFDIR else { throw Self.invalid() }
    }

    private func read(_ name: String) throws -> Data? {
        try validateDirectory()
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw Self.invalid() }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              (metadata.st_mode & 0o7777) == 0o600, metadata.st_size <= 4096 else { throw Self.invalid() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4097)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Self.invalid() }
            if count == 0 { return result }
            guard result.count + count <= 4096 else { throw Self.invalid() }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func invalid() -> NativeBackendError {
        .unavailable("独立恢复通道校验失败")
    }
}
