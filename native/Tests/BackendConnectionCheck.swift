import Foundation
import Darwin

@main
struct BackendConnectionCheck {
    static let snapshot: BackendJSON = .object([
        "revision": .string("1"),
        "profiles": .object(["state": .string("ready"), "current": .null, "items": .array([]), "message": .null]),
        "proxyView": .null,
        "core": .object(["state": .string("unavailable"), "message": .null])
    ])

    static func emit(_ message: BackendMessage) throws {
        try FileHandle.standardOutput.write(contentsOf: BackendWire.encode(message))
    }

    static func recoveryFile(_ value: [String: Any], name: String, mode: mode_t = 0o600) throws {
        guard let root = ProcessInfo.processInfo.environment["TEZ_NATIVE_RECOVERY_DIR"] else { fatalError("Missing recovery directory") }
        let temporary = URL(fileURLWithPath: root).appendingPathComponent(".fixture-\(UUID().uuidString)")
        let data = try JSONSerialization.data(withJSONObject: value)
        precondition(FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: NSNumber(value: mode)]))
        let destination = URL(fileURLWithPath: root).appendingPathComponent(name)
        precondition(rename(temporary.path, destination.path) == 0)
    }

    static func recoverAfterBrokenOutput(_ mode: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["TEZ_NATIVE_RECOVERY_DIR"], let token = environment["TEZ_NATIVE_RECOVERY_TOKEN"] else { fatalError() }
        var seen: UInt64 = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let file = URL(fileURLWithPath: root).appendingPathComponent("request.json")
            if let data = try? Data(contentsOf: file),
               let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sequence = request["sequence"] as? UInt64, sequence > seen,
               request["token"] as? String == token, request["command"] as? String == "retry-shutdown" {
                seen = sequence
                let first = sequence == 1
                let response: [String: Any] = ["version": 1,
                    "sequence": first && mode == "recovery-stale" ? sequence - 1 : sequence,
                    "token": first && mode == "recovery-token" ? String(repeating: "0", count: 64) : token,
                    "safeToExit": !first || mode != "recovery-file"]
                try recoveryFile(response, name: "response.json", mode: first && mode == "recovery-permissions" ? 0o644 : 0o600)
                if !first { return }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        exit(9)
    }

    static func fixture(_ mode: String) throws {
        if mode == "activation-busy" { exit(73) }
        if mode == "activation-refused" { exit(78) }
        if mode == "activation-unknown" { exit(3) }
        if mode.hasPrefix("managed-") || mode.hasPrefix("prepared-") || mode.hasPrefix("recovery-") || mode == "renewal-slow-exit" { signal(SIGTERM, SIG_IGN) }
        if mode.hasPrefix("recovery-") {
            guard let token = ProcessInfo.processInfo.environment["TEZ_NATIVE_RECOVERY_TOKEN"] else { fatalError() }
            try recoveryFile(["version": 1, "token": token], name: "ready.json")
        }
        if mode.hasPrefix("renewal") { Thread.sleep(forTimeInterval: 0.05) }
        if mode == "nohello" { Thread.sleep(forTimeInterval: 3); return }
        if mode == "badhello" {
            try emit(.hello(sessionID: "fixture", capabilities: []))
        } else if mode.hasPrefix("renewal") {
            var capabilities = ["native_subscribe", "native_get_snapshot", "native_get_activity"]
            if mode == "renewal-unsafe" { capabilities.append("native_save_profile") }
            try emit(.hello(sessionID: String(getpid()), capabilities: capabilities))
        } else if mode.hasPrefix("prepared-") || mode.hasPrefix("recovery-") {
            try emit(.hello(sessionID: "fixture", capabilities: ["native_subscribe", "native_get_snapshot", "native_prepare_shutdown"]))
        } else {
            try emit(.hello(sessionID: "fixture", capabilities: ["native_subscribe", "native_get_snapshot", "fixture-only"]))
        }
        var first: String?
        var second: String?
        var prepareAttempts = 0
        var prepared = false
        while let line = readLine() {
            guard case .request(let id, let command, _) = try BackendWire.decode(Data(line.utf8)) else { exit(2) }
            if command == "native_subscribe" {
                if mode == "no-subscribe" { continue }
                try emit(.response(id: id, outcome: .result(mode.hasPrefix("renewal") ? renewalSnapshot() : snapshot)))
                if mode == "gap" {
                    try emit(.event(sequence: "2", name: "tez://snapshot-changed", payload: snapshot))
                }
                if mode == "corrupt" { try FileHandle.standardOutput.write(contentsOf: Data("not-json\n".utf8)) }
                if mode == "eof" { return }
            } else if command == "break-main" {
                try FileHandle.standardOutput.close()
            } else if command == "recovery-directory" {
                try emit(.response(id: id, outcome: .result(.string(ProcessInfo.processInfo.environment["TEZ_NATIVE_RECOVERY_DIR"] ?? ""))))
            } else if command == "native_prepare_shutdown" {
                prepareAttempts += 1
                if mode == "prepared-gap" {
                    try emit(.event(sequence: "999", name: "tez://snapshot-changed", payload: snapshot))
                }
                if mode == "prepared-retry" && prepareAttempts == 1 {
                    try emit(.response(id: id, outcome: .error(.init(detail: "Injected cleanup failure", code: .string("NATIVE_SHUTDOWN_UNRESOLVED"), operation: nil))))
                } else if mode == "prepared-invalid" && prepareAttempts == 1 {
                    try emit(.response(id: id, outcome: .result(.object(["safeToExit": .bool(false)]))))
                } else {
                    if mode == "prepared-late" && prepareAttempts == 1 { Thread.sleep(forTimeInterval: 0.15) }
                    prepared = true
                    try emit(.response(id: id, outcome: .result(.object(["safeToExit": .bool(true)]))))
                }
            } else if command == "first" || command == "second" {
                if command == "first" { first = id } else { second = id }
                if let first, let second {
                    try emit(.response(id: second, outcome: .result(.string("second"))))
                    try emit(.response(id: first, outcome: .result(.string("first"))))
                }
            } else if command == "pid" {
                try emit(.response(id: id, outcome: .result(.integer(Int64(getpid())))))
            } else if command == "delay" {
                Thread.sleep(forTimeInterval: 0.15)
                try emit(.response(id: id, outcome: .result(.string("delayed"))))
            } else if command == "revision" {
                try emit(.event(sequence: "1", name: "tez://snapshot-changed", payload: renewalSnapshot("9")))
                try emit(.response(id: id, outcome: .result(.string("revised"))))
            } else if command == "remote-error" {
                try emit(.response(id: id, outcome: .error(.init(detail: "fixture detail", code: .string("fixture_code"), operation: .string("fixture_operation")))))
            } else if command == "exit" { return }
            else if command == "never" { continue }
            else if command == "event" {
                try emit(.event(sequence: "1", name: "tez://snapshot-changed", payload: snapshot))
                try emit(.response(id: id, outcome: .result(snapshot)))
            } else { try emit(.response(id: id, outcome: .result(snapshot))) }
        }
        if mode == "managed-delay" { Thread.sleep(forTimeInterval: 0.3) }
        if mode == "managed-timeout" { Thread.sleep(forTimeInterval: 0.6) }
        if mode == "managed-failed" { exit(3) }
        if mode == "managed-reserved-exit" { exit(78) }
        if mode.hasPrefix("recovery-") { try recoverAfterBrokenOutput(mode) }
        if mode.hasPrefix("prepared-") && !prepared { exit(7) }
        if mode.hasPrefix("prepared-") {
            let expected = ["prepared-retry", "prepared-invalid", "prepared-late"].contains(mode) ? 2 : 1
            if prepareAttempts != expected { exit(8) }
        }
        if mode == "prepared-eof-delay" { Thread.sleep(forTimeInterval: 0.3) }
        if mode == "prepared-failed" { exit(3) }
        if mode == "renewal-slow-exit" { Thread.sleep(forTimeInterval: 0.4) }
    }

    static func renewalSnapshot(_ revision: String = "1") -> BackendJSON {
        guard case .object(var value) = snapshot else { fatalError() }
        value["revision"] = .string(revision)
        value["profiles"] = .object(["state": .string("ready"), "current": .string("fixture"),
            "items": .array([.object(["uid": .string("fixture"), "name": .string(String(getpid())),
                                      "type": .string("local"), "updated": .null])]), "message": .null])
        return .object(value)
    }

    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeBackendError.unavailable("Test wait timed out")
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fixture" {
            try fixture(CommandLine.arguments[2]); return
        }
        if CommandLine.arguments.count == 3, Array(CommandLine.arguments.dropFirst()) == ["--stdio", "--attach"] {
            let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
            try fixture(name.contains("unsafe") ? "renewal-unsafe" : name.contains("slow") ? "renewal-slow-exit" : "renewal")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fixture-helper")
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
        func store(_ mode: String) -> NativeBackendStore {
            NativeBackendStore(helperURL: helper, arguments: ["--fixture", mode], timeout: .milliseconds(200), mode: .attach)
        }
        let backend = store("normal")
        precondition(backend.state == .disconnected && backend.snapshot == nil)
        precondition(backend.capabilities.isEmpty && !backend.supports("native_get_snapshot"))
        backend.connect()
        precondition(backend.capabilities.isEmpty && !backend.supports("native_get_snapshot"))
        try await wait { backend.state == .connected }
        precondition(backend.snapshot?.revision == "1")
        precondition(backend.capabilities == ["native_subscribe", "native_get_snapshot", "fixture-only"])
        precondition(backend.supports("native_get_snapshot") && backend.supports("fixture-only"))
        precondition(!backend.supports("not-advertised"))
        do {
            _ = try await backend.request("remote-error")
            preconditionFailure("Remote error unexpectedly succeeded")
        } catch NativeBackendError.remote(let error) {
            precondition(error.detail == "fixture detail")
            precondition(error.code == .string("fixture_code") && error.operation == .string("fixture_operation"))
        }
        async let first = backend.request("first")
        async let second = backend.request("second")
        let values = try await (first, second)
        precondition(values.0 == .string("first") && values.1 == .string("second"))
        _ = try await backend.request("event")
        do {
            _ = try await backend.request("never")
            preconditionFailure("Timeout request unexpectedly succeeded")
        } catch {}
        backend.refresh()
        try await Task.sleep(for: .milliseconds(50))
        precondition(backend.state == .connected)
        backend.disconnect()
        precondition(backend.capabilities.isEmpty && !backend.supports("fixture-only"))
        backend.connect()
        precondition(backend.capabilities.isEmpty && !backend.supports("fixture-only"))
        try await wait { backend.state == .connected }
        try await Task.sleep(for: .milliseconds(50))
        precondition(backend.state == .connected)
        backend.disconnect()
        for _ in 0..<3 {
            backend.connect()
            try await wait { backend.state == .connected }
            guard case .integer(let pid) = try await backend.request("pid") else {
                preconditionFailure("Missing child PID")
            }
            backend.disconnect()
            try await wait { kill(pid_t(pid), 0) == -1 && errno == ESRCH }
        }
        let exits = store("normal")
        exits.connect()
        try await wait { exits.state == .connected }
        do {
            _ = try await exits.request("exit")
            preconditionFailure("EOF request unexpectedly succeeded")
        } catch {}
        try await wait { exits.state == .failed }
        precondition(exits.snapshot?.revision == "1")
        precondition(exits.capabilities.isEmpty && !exits.supports("native_get_snapshot"))
        exits.connect()
        precondition(exits.snapshot == nil)
        exits.disconnect()
        let subscribing = store("no-subscribe")
        subscribing.connect()
        try await wait { !subscribing.capabilities.isEmpty }
        precondition(subscribing.state == .connecting && !subscribing.supports("native_get_snapshot"))
        try await wait { subscribing.state == .failed }
        precondition(subscribing.capabilities.isEmpty && !subscribing.supports("fixture-only"))
        subscribing.disconnect()
        for mode in ["badhello", "nohello", "gap", "corrupt", "eof"] {
            let failure = store(mode)
            failure.connect()
            try await wait { failure.state == .failed }
            precondition(failure.errorMessage != nil)
            precondition(failure.capabilities.isEmpty && !failure.supports("native_get_snapshot"))
            failure.disconnect()
        }
        let missing = NativeBackendStore(helperURL: directory.appendingPathComponent("missing"), arguments: [])
        missing.connect()
        try await wait { missing.state == .failed }
        let privateChannel = try NativeRecoveryChannel()
        guard let privateRoot = privateChannel.environment["TEZ_NATIVE_RECOVERY_DIR"],
              let privateToken = privateChannel.environment["TEZ_NATIVE_RECOVERY_TOKEN"] else { preconditionFailure() }
        let readyFile = URL(fileURLWithPath: privateRoot).appendingPathComponent("ready.json")
        let readyBytes = try JSONSerialization.data(withJSONObject: ["version": 1, "token": privateToken])
        try readyBytes.write(to: readyFile)
        precondition(chmod(readyFile.path, 0o600) == 0 && privateChannel.isReady())
        precondition(chmod(readyFile.path, 0o644) == 0 && !privateChannel.isReady())
        precondition(chmod(readyFile.path, 0o600) == 0)
        let linkedFile = URL(fileURLWithPath: privateRoot).appendingPathComponent("linked-ready")
        precondition(link(readyFile.path, linkedFile.path) == 0 && !privateChannel.isReady())
        try FileManager.default.removeItem(at: linkedFile)
        try FileManager.default.moveItem(at: readyFile, to: linkedFile)
        try FileManager.default.createSymbolicLink(at: readyFile, withDestinationURL: linkedFile)
        precondition(!privateChannel.isReady())
        try FileManager.default.removeItem(at: readyFile)
        try FileManager.default.moveItem(at: linkedFile, to: readyFile)
        try Data(repeating: 97, count: 4097).write(to: readyFile)
        precondition(!privateChannel.isReady())
        try readyBytes.write(to: readyFile)
        precondition(chmod(privateRoot, 0o755) == 0 && !privateChannel.isReady())
        precondition(chmod(privateRoot, 0o700) == 0 && privateChannel.isReady())
        privateChannel.removeAfterConfirmedExit()
        precondition(!FileManager.default.fileExists(atPath: privateRoot))
        func renewal(_ name: String = "renewal-helper", limit: Int = 4, mode: NativeBackendMode = .attach,
                     shutdownTimeout: Duration = .seconds(1)) throws -> NativeBackendStore {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
            }
            return NativeBackendStore(helperURL: url, arguments: ["--stdio", "--attach"], timeout: .seconds(1),
                mode: mode, shutdownTimeout: shutdownTimeout, renewalRequestLimit: limit)
        }
        let renewing = try renewal()
        renewing.connect()
        try await wait { renewing.state == .connected }
        guard case .integer(let oldPID) = try await renewing.request("pid") else { preconditionFailure("Missing PID") }
        _ = try await renewing.request("revision")
        precondition(renewing.snapshot?.revision == "9")
        let delayedRead = Task { try await renewing.request("delay") }
        try await wait { renewing.state == .renewing }
        precondition(renewing.snapshot?.revision == "9" && !renewing.supports("native_get_snapshot"))
        try await Task.sleep(for: .milliseconds(40))
        precondition(kill(pid_t(oldPID), 0) == 0 && renewing.state == .renewing)
        do { _ = try await renewing.request("pid"); preconditionFailure("Renewal accepted a new request") } catch {}
        let delayedResult = try await delayedRead.value
        precondition(delayedResult == .string("delayed"))
        try await wait { renewing.state == .connecting }
        precondition(renewing.snapshot?.revision == "9" && renewing.capabilities.isEmpty)
        try await wait { renewing.state == .connected }
        precondition(renewing.snapshot?.revision == "1")
        guard case .integer(let newPID) = try await renewing.request("pid") else { preconditionFailure("Missing PID") }
        precondition(oldPID != newPID)
        try await wait { kill(pid_t(oldPID), 0) == -1 && errno == ESRCH }
        renewing.disconnect()
        try await wait { kill(pid_t(newPID), 0) == -1 && errno == ESRCH }

        let cancelledRenewal = try renewal(limit: 3)
        cancelledRenewal.connect()
        try await wait { cancelledRenewal.state == .connected }
        guard case .integer(let cancelledPID) = try await cancelledRenewal.request("pid") else { preconditionFailure("Missing PID") }
        let cancelledRead = Task { try await cancelledRenewal.request("delay") }
        try await wait { cancelledRenewal.state == .renewing }
        cancelledRenewal.disconnect()
        do { _ = try await cancelledRead.value; preconditionFailure("Disconnected request succeeded") } catch {}
        try await Task.sleep(for: .milliseconds(300))
        precondition(cancelledRenewal.state == .disconnected && cancelledRenewal.capabilities.isEmpty)
        try await wait { kill(pid_t(cancelledPID), 0) == -1 && errno == ESRCH }

        let unsafeRenewal = try renewal("unsafe-renewal-helper", limit: 2)
        unsafeRenewal.connect()
        try await wait { unsafeRenewal.state == .connected }
        let unsafePID = try await unsafeRenewal.request("pid")
        precondition(unsafeRenewal.state == .connected && unsafeRenewal.supports("native_save_profile"))
        let sameUnsafePID = try await unsafeRenewal.request("pid")
        precondition(sameUnsafePID == unsafePID)
        unsafeRenewal.disconnect()

        let wrongArguments = NativeBackendStore(helperURL: helper, arguments: ["--fixture", "renewal"],
            timeout: .seconds(1), mode: .attach, renewalRequestLimit: 2)
        wrongArguments.connect()
        try await wait { wrongArguments.state == .connected }
        let wrongArgumentsPID = try await wrongArguments.request("pid")
        let sameWrongArgumentsPID = try await wrongArguments.request("pid")
        precondition(wrongArguments.state == .connected && sameWrongArgumentsPID == wrongArgumentsPID)
        wrongArguments.disconnect()

        let managedRenewal = try renewal(limit: 2, mode: .managed)
        managedRenewal.connect()
        try await wait { managedRenewal.state == .connected }
        let managedPID = try await managedRenewal.request("pid")
        precondition(managedRenewal.state == .connected)
        let sameManagedPID = try await managedRenewal.request("pid")
        precondition(sameManagedPID == managedPID)
        let managedRenewalStopped = await managedRenewal.shutdownForTermination()
        precondition(managedRenewalStopped)

        let slowRenewal = try renewal("slow-renewal-helper", limit: 2, shutdownTimeout: .milliseconds(50))
        slowRenewal.connect()
        try await wait { slowRenewal.state == .connected }
        guard case .integer(let slowPID) = try await slowRenewal.request("pid") else { preconditionFailure("Missing PID") }
        try await wait { slowRenewal.state == .failed }
        precondition(kill(pid_t(slowPID), 0) == 0 && slowRenewal.snapshot != nil)
        slowRenewal.connect()
        precondition(slowRenewal.state == .failed)
        try await wait { kill(pid_t(slowPID), 0) == -1 && errno == ESRCH }
        try await Task.sleep(for: .milliseconds(50))
        precondition(slowRenewal.state == .failed)
        slowRenewal.connect()
        try await wait { slowRenewal.state == .connected }
        slowRenewal.disconnect()
        func managed(_ mode: String, shutdownTimeout: Duration = .seconds(1)) -> NativeBackendStore {
            NativeBackendStore(helperURL: helper, arguments: ["--fixture", mode], timeout: .milliseconds(200),
                               mode: .managed, shutdownTimeout: shutdownTimeout)
        }
        for mode in ["activation-busy", "activation-refused"] {
            let refused = managed(mode)
            refused.connect()
            try await wait { refused.state == .failed || refused.state == .shutdownFailed }
            precondition(refused.state == .failed && !refused.requiresManagedShutdown, "Startup refusal must not become unresolved cleanup")
            refused.connect()
            try await wait { refused.state == .failed || refused.state == .shutdownFailed }
            precondition(refused.state == .failed && !refused.requiresManagedShutdown, "Startup refusal must allow a fresh attempt")
            let safeToClose = await refused.shutdownForTermination()
            precondition(safeToClose && refused.state == .disconnected)
        }
        let unknownStartup = managed("activation-unknown")
        unknownStartup.connect()
        try await wait { unknownStartup.state == .shutdownFailed }
        precondition(unknownStartup.requiresManagedShutdown)
        let reservedAfterHello = managed("managed-reserved-exit")
        reservedAfterHello.connect()
        try await wait { reservedAfterHello.state == .connected }
        let unsafeReservedExit = await reservedAfterHello.shutdownForTermination()
        precondition(!unsafeReservedExit && reservedAfterHello.state == .shutdownFailed)
        let graceful = managed("managed-delay")
        graceful.connect()
        try await wait { graceful.state == .connected }
        guard case .integer(let gracefulPID) = try await graceful.request("pid") else { preconditionFailure("Missing PID") }
        graceful.disconnect()
        graceful.disconnect()
        precondition(graceful.state == .stopping && !graceful.supports("native_get_snapshot"))
        graceful.connect()
        precondition(graceful.state == .stopping)
        precondition(kill(pid_t(gracefulPID), 0) == 0)
        let gracefullyStopped = await graceful.shutdownForTermination()
        precondition(gracefullyStopped && graceful.state == .disconnected && !graceful.requiresManagedShutdown)
        try await wait { kill(pid_t(gracefulPID), 0) == -1 && errno == ESRCH }

        let delayed = managed("managed-timeout", shutdownTimeout: .milliseconds(50))
        delayed.connect()
        try await wait { delayed.state == .connected }
        guard case .integer(let delayedPID) = try await delayed.request("pid") else { preconditionFailure("Missing PID") }
        let earlyExit = await delayed.shutdownForTermination()
        precondition(!earlyExit && delayed.state == .shutdownFailed && delayed.requiresManagedShutdown)
        precondition(delayed.capabilities.isEmpty && kill(pid_t(delayedPID), 0) == 0)
        delayed.connect()
        precondition(delayed.state == .shutdownFailed)
        try await wait { kill(pid_t(delayedPID), 0) == -1 && errno == ESRCH }
        let eventuallyStopped = await delayed.shutdownForTermination()
        precondition(eventuallyStopped && delayed.state == .disconnected)

        let unsuccessful = managed("managed-failed")
        unsuccessful.connect()
        try await wait { unsuccessful.state == .connected }
        let unconfirmedExit = await unsuccessful.shutdownForTermination()
        precondition(!unconfirmedExit && unsuccessful.state == .shutdownFailed && unsuccessful.requiresManagedShutdown)
        unsuccessful.connect()
        precondition(unsuccessful.state == .shutdownFailed)

        for mode in ["prepared-retry", "prepared-invalid"] {
            let recovery = managed(mode)
            recovery.connect()
            try await wait { recovery.state == .connected }
            guard case .integer(let pid) = try await recovery.request("pid") else { preconditionFailure("Missing recovery PID") }
            let failedCleanup = await recovery.shutdownForTermination()
            precondition(!failedCleanup && recovery.state == .shutdownFailed && recovery.requiresManagedShutdown)
            precondition(recovery.capabilities.contains("native_prepare_shutdown") && !recovery.supports("native_prepare_shutdown"))
            precondition(kill(pid_t(pid), 0) == 0)
            do { _ = try await recovery.request("pid"); preconditionFailure("Business request accepted during recovery") } catch {}
            recovery.connect()
            precondition(recovery.state == .shutdownFailed)
            recovery.disconnect()
            recovery.disconnect()
            let recovered = await recovery.shutdownForTermination()
            precondition(recovered && recovery.state == .disconnected && recovery.capabilities.isEmpty)
            try await wait { kill(pid_t(pid), 0) == -1 && errno == ESRCH }
        }

        let draining = managed("prepared-success")
        draining.connect()
        try await wait { draining.state == .connected }
        let activeBusinessRequest = Task { try await draining.request("delay") }
        try await Task.sleep(for: .milliseconds(20))
        let drainedCleanup = Task { await draining.shutdownForTermination() }
        try await wait { draining.state == .stopping }
        do { _ = try await draining.request("pid"); preconditionFailure("Request accepted while draining") } catch {}
        let drainedValue = try await activeBusinessRequest.value
        precondition(drainedValue == .string("delayed"))
        let drainingStopped = await drainedCleanup.value
        precondition(drainingStopped && draining.state == .disconnected)

        let interruptedEvents = managed("prepared-gap")
        interruptedEvents.connect()
        try await wait { interruptedEvents.state == .connected }
        let ignoredGap = await interruptedEvents.shutdownForTermination()
        precondition(ignoredGap && interruptedEvents.state == .disconnected)

        let blockedDrain = managed("prepared-success", shutdownTimeout: .milliseconds(50))
        blockedDrain.connect()
        try await wait { blockedDrain.state == .connected }
        let stalledBusinessRequest = Task { try await blockedDrain.request("never") }
        try await Task.sleep(for: .milliseconds(20))
        let unfinishedDrain = await blockedDrain.shutdownForTermination()
        precondition(!unfinishedDrain && blockedDrain.state == .shutdownFailed)
        precondition(blockedDrain.capabilities.contains("native_prepare_shutdown"))
        do { _ = try await stalledBusinessRequest.value; preconditionFailure("Stalled request succeeded") } catch {}
        let drainRetry = await blockedDrain.shutdownForTermination()
        precondition(drainRetry && blockedDrain.state == .disconnected)

        let lateCleanup = managed("prepared-late", shutdownTimeout: .milliseconds(50))
        lateCleanup.connect()
        try await wait { lateCleanup.state == .connected }
        let timedOutCleanup = await lateCleanup.shutdownForTermination()
        precondition(!timedOutCleanup && lateCleanup.state == .shutdownFailed)
        try await Task.sleep(for: .milliseconds(200))
        precondition(lateCleanup.state == .shutdownFailed && lateCleanup.requiresManagedShutdown)
        let retriedCleanup = await lateCleanup.shutdownForTermination()
        precondition(retriedCleanup && lateCleanup.state == .disconnected)

        let delayedPreparedExit = managed("prepared-eof-delay", shutdownTimeout: .milliseconds(50))
        delayedPreparedExit.connect()
        try await wait { delayedPreparedExit.state == .connected }
        let pendingPreparedExit = await delayedPreparedExit.shutdownForTermination()
        precondition(!pendingPreparedExit && delayedPreparedExit.state == .shutdownFailed)
        precondition(delayedPreparedExit.capabilities.isEmpty)
        try await Task.sleep(for: .milliseconds(350))
        let completedPreparedExit = await delayedPreparedExit.shutdownForTermination()
        precondition(completedPreparedExit && delayedPreparedExit.state == .disconnected)

        let abnormalPreparedExit = managed("prepared-failed")
        abnormalPreparedExit.connect()
        try await wait { abnormalPreparedExit.state == .connected }
        let abnormalPreparedStopped = await abnormalPreparedExit.shutdownForTermination()
        precondition(!abnormalPreparedStopped && abnormalPreparedExit.state == .shutdownFailed)

        for mode in ["recovery-file", "recovery-token", "recovery-stale", "recovery-permissions"] {
            let recovery = managed(mode, shutdownTimeout: .milliseconds(100))
            recovery.connect()
            try await wait { recovery.state == .connected }
            guard case .integer(let pid) = try await recovery.request("pid"),
                  case .string(let root) = try await recovery.request("recovery-directory") else { preconditionFailure("Missing recovery fixture identity") }
            let attributes = try FileManager.default.attributesOfItem(atPath: root)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            do { _ = try await recovery.request("break-main"); preconditionFailure("Broken output request succeeded") } catch {}
            try await wait { recovery.state == .shutdownFailed }
            precondition(kill(pid_t(pid), 0) == 0 && recovery.requiresManagedShutdown)
            precondition(FileManager.default.fileExists(atPath: root))
            do { _ = try await recovery.request("pid"); preconditionFailure("Recovery accepted a business request") } catch {}
            let recovered = await recovery.shutdownForTermination()
            precondition(recovered && recovery.state == .disconnected, "\(mode): \(recovery.errorMessage ?? "no message")")
            try await wait { kill(pid_t(pid), 0) == -1 && errno == ESRCH }
            precondition(!FileManager.default.fileExists(atPath: root))
        }
        let projection = Data(#"{"revision":"9","profiles":{"state":"ready","current":"local","items":[{"uid":"local","name":"Local","type":"local","updated":42}],"message":null},"proxyView":{"schemaVersion":1,"orderSource":"runtime","providerState":"ready","global":null,"direct":"c:0","groups":[{"name":"Select","type":"Selector","now":"Node","history":[],"udp":true,"xudp":false,"tfo":false,"mptcp":false,"smux":false,"members":[{"kind":"node","name":"Node","recordId":"p:0:0"},{"kind":"unresolved","name":"Missing","reason":"missing"}]}],"records":{"p:0:0":{"recordId":"p:0:0","name":"Node","type":"Shadowsocks","history":[{"time":"2026-10-27T00:00:00Z","delay":12}],"udp":true,"xudp":false,"tfo":false,"mptcp":false,"smux":false,"source":{"kind":"provider","proxyName":"Node","providerName":"Subscription"}}},"standalone":[],"providers":[{"name":"Subscription","proxyRecordIds":["p:0:0"]}]},"core":{"state":"ready","message":null}}"#.utf8)
        let decoded = try NativeSnapshot.decode(JSONDecoder().decode(BackendJSON.self, from: projection))
        precondition(decoded.profiles.items.first?.updated == 42)
        precondition(decoded.proxyView?.groups.first?.members.first?.recordId == "p:0:0")
        precondition(decoded.proxyView?.records["p:0:0"]?.source.providerName == "Subscription")
        precondition(decoded.proxyView?.records["p:0:0"]?.history.last?.delay == 12)
        guard case .object(var unsupported) = try JSONDecoder().decode(BackendJSON.self, from: projection),
              case .object(var proxyView) = unsupported["proxyView"] else {
            preconditionFailure("Invalid projection fixture")
        }
        proxyView["schemaVersion"] = .integer(2)
        unsupported["proxyView"] = .object(proxyView)
        do {
            _ = try NativeSnapshot.decode(.object(unsupported))
            preconditionFailure("Unsupported proxy view schema accepted")
        } catch {}
        for revision in ["01", "+1", "-1", "18446744073709551616", "", "1.0", " 1"] {
            guard case .object(var value) = snapshot else { preconditionFailure("Invalid fixture") }
            value["revision"] = .string(revision)
            do {
                _ = try NativeSnapshot.decode(.object(value))
                preconditionFailure("Forged revision accepted")
            } catch {}
        }
        print("Backend connection checks passed: handshake, capability gating and reset, FIFO events, correlation, timeout, EOF, corruption, sequence gap, generation, child cleanup, attach renewal/drain/cancellation/safety/timeout, startup refusal/retry/safe close and unknown-exit protection, managed prepare/retry/drain/late-response/EOF confirmation, private broken-pipe recovery/token/sequence/permissions, legacy graceful/timeout/failed shutdown, offline snapshot, structured errors, canonical revisions, DTO projection")
    }
}
