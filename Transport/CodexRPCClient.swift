import Foundation
import Darwin
import CoreFoundation

/// Only local stdio. The official CLI exclusively owns authentication.
actor CodexRPCClient {
    static let allowedMethods: Set<String> = ["initialize", "account/rateLimits/read", "account/usage/read"]
    static let privacyArguments = [
        "app-server", "--stdio", "-c", "analytics.enabled=false",
        "-c", "otel.exporter=\"none\"", "-c", "otel.trace_exporter=\"none\"",
        "-c", "otel.metrics_exporter=\"none\""
    ]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var framer = JSONLineFramer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var initialized = false
    private var connecting = false
    private var cleanup: Task<Void, Never>?
    private var receivedBytes = 0
    private let timeoutSeconds: Double

    static func childEnvironment(from parent: [String: String], home: String) -> [String: String] {
        // Never inherit PATH, dynamic-loader settings, tokens, or arbitrary CLI overrides.
        let permitted = Set(["LANG", "LC_ALL", "LC_CTYPE"])
        var environment = parent.filter { permitted.contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["HOME"] = home
        environment["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
        return environment
    }

    init(timeoutSeconds: Double = 15) { self.timeoutSeconds = timeoutSeconds }

    @discardableResult
    func connect(executable: URL, arguments: [String]? = nil) async throws -> Bool {
        if initialized, process?.isRunning == true { return false }
        guard !connecting else { throw RPCError.disconnected }
        connecting = true
        defer { connecting = false }
        await stop()
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments ?? Self.privacyArguments
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        child.environment = Self.childEnvironment(from: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser.path)
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        // Do not receive, inspect, or retain CLI stderr at all.
        child.standardError = FileHandle.nullDevice
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(8)) { continuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                do {
                    var bytes = [UInt8](repeating: 0, count: 65_536)
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { return }
                    guard count >= 0 else { throw RPCError.disconnected }
                    let data = Data(bytes.prefix(count))
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        continuation.finish()
                    } else if case .dropped = continuation.yield(data) {
                        // Never silently corrupt framing or grow an unbounded backlog.
                        handle.readabilityHandler = nil
                        continuation.finish(throwing: RPCError.messageTooLarge)
                    }
                } catch {
                    handle.readabilityHandler = nil
                    continuation.finish(throwing: RPCError.disconnected)
                }
            }
        }
        process = child
        do {
            try child.run()
            // A child that stops reading stdin must not block the actor and its timeout.
            let fd = stdinPipe.fileHandleForWriting.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1,
                  fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
                throw RPCError.disconnected
            }
        } catch { await stop(); throw RPCError.disconnected }
        reader = Task { [weak self] in
            do {
                for try await chunk in stream { await self?.consume(chunk, token: token) }
            } catch { /* Report only a generic local transport failure. */ }
            await self?.disconnected(token: token)
        }
        do {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "codex_usage_monitor", "title": "Codex Usage Monitor", "version": "0.1.4"],
                "capabilities": ["experimentalApi": true]
            ])
            try send(["method": "initialized", "params": [:]])
            initialized = true
            return true
        } catch { await stop(); throw error }
    }

    func readRateLimits() async throws -> Data { try await request("account/rateLimits/read") }
    func readUsage() async throws -> Data { try await request("account/usage/read") }

    func request(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        guard Self.allowedMethods.contains(method) else { throw RPCError.unsupportedMethod }
        guard pending.isEmpty, process?.isRunning == true,
              method == "initialize" || initialized else { throw RPCError.disconnected }
        let id = nextID
        nextID = nextID == Int.max ? 1 : nextID + 1
        receivedBytes = 0
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                let timeout = timeoutSeconds
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.abort(id, error: .timeout)
                }
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                do { try send(message) } catch {
                    Task { await self.abort(id, error: .disconnected) }
                }
            }
        } onCancel: {
            Task { await self.abort(id, error: .cancelled) }
        }
    }

    private func send(_ value: [String: Any]) throws {
        guard let input else { throw RPCError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        guard data.count <= 4096 else { throw RPCError.invalidMessage }
        // A short write or EAGAIN invalidates this connection; do not block retrying.
        let count = data.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw RPCError.disconnected }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue) else { return nil }
        return integer
    }

    private func consume(_ data: Data, token: UUID) async {
        guard generation == token else { return }
        do {
            receivedBytes += data.count
            guard receivedBytes <= 4 * JSONLineFramer.maximumBytes else { throw RPCError.messageTooLarge }
            for line in try framer.append(data) {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw RPCError.invalidMessage
                }
                if let method = message["method"] {
                    guard let name = method as? String, name.utf8.count <= 128 else { throw RPCError.invalidMessage }
                    // Do not inspect params, especially external-token refresh params.
                    if let rawID = message["id"] {
                        let id: Any
                        if let number = Self.integer(rawID) { id = number }
                        else if let string = rawID as? String, string.utf8.count <= 128 { id = string }
                        else { throw RPCError.invalidMessage }
                        try send(["id": id, "error": ["code": -32601, "message": "Unsupported by usage monitor"]])
                    }
                    continue
                }
                guard let id = Self.integer(message["id"]), pending[id] != nil else {
                    throw RPCError.invalidMessage
                }
                guard (message["result"] != nil) != (message["error"] != nil) else { throw RPCError.invalidMessage }
                if let error = message["error"] as? [String: Any] {
                    guard let code = Self.integer(error["code"]) else { throw RPCError.invalidMessage }
                    let description = (error["message"] as? String ?? "").prefix(512).lowercased()
                    let category: ServerErrorCategory
                    if code == -32601 || description.contains("experimentalapi") || description.contains("unsupported") {
                        category = .unsupported
                    } else if description.contains("auth") || description.contains("login") || description.contains("sign in") {
                        category = .authentication
                    } else { category = .other }
                    finish(id, result: .failure(RPCError.server(code: code, category: category)))
                } else if let result = message["result"] as? [String: Any] {
                    finish(id, result: .success(try JSONSerialization.data(withJSONObject: result)))
                } else { throw RPCError.invalidMessage }
            }
        } catch { await stop() }
    }

    private func finish(_ id: Int, result: Result<Data, Error>) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func abort(_ id: Int, error: RPCError) async {
        guard pending[id] != nil else { return }
        finish(id, result: .failure(error))
        await stop()
    }

    private func disconnected(token: UUID) async {
        if generation == token { await stop() }
    }

    func stop() async {
        generation = UUID()
        initialized = false
        reader?.cancel(); reader = nil
        output?.readabilityHandler = nil
        let child = process
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil
        framer = JSONLineFramer()
        for id in Array(pending.keys) { finish(id, result: .failure(RPCError.disconnected)) }
        guard let child else { await cleanup?.value; return }
        // Await cleanup, including when the caller is already cancelled or the app quits.
        let task = Task.detached {
            if child.isRunning {
                child.terminate()
                for _ in 0..<20 {
                    if !child.isRunning { break }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
            // Foundation reaps the child; avoid waitUntilExit on a process that failed to launch.
            for _ in 0..<40 {
                if !child.isRunning { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        cleanup = task
        await task.value
    }
}
