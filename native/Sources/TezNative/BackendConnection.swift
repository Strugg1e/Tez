import Foundation
import Observation

enum NativeBackendState: Equatable {
    case disconnected, connecting, connected, renewing, failed, stopping, shutdownFailed
}

enum NativeBackendMode {
    case attach, managed, automatic
}

enum NativeBackendError: Error, CustomStringConvertible {
    case unavailable(String)
    case remote(BackendRemoteError)
    var description: String {
        switch self {
        case .unavailable(let message): return message
        case .remote: return "后台请求失败"
        }
    }
}

private final class BackendProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    let writes = DispatchQueue(label: "tez.native.backend.input")
    let mode: NativeBackendMode
    let recovery: NativeRecoveryChannel?
    var started = false
    private let stopLock = NSLock()
    private var stopRequested = false
    private var readOnly: Bool

    init(url: URL, arguments: [String], mode: NativeBackendMode) throws {
        self.mode = mode
        readOnly = mode == .attach
        recovery = mode != .attach ? try NativeRecoveryChannel() : nil
        process.executableURL = url
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        if let recovery {
            process.environment = ProcessInfo.processInfo.environment.merging(recovery.environment) { _, value in value }
        }
        if Bundle.main.bundleIdentifier == "app.tez.acceptance",
           let home = Bundle.main.object(forInfoDictionaryKey: "TezAcceptanceHome") as? String {
            var environment = process.environment ?? ProcessInfo.processInfo.environment
            environment["HOME"] = home
            process.environment = environment
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopRequested else { stopLock.unlock(); return }
        stopRequested = true
        let terminate = readOnly
        stopLock.unlock()
        if terminate, process.isRunning { process.terminate() }
        writes.async { [input] in try? input.fileHandleForWriting.close() }
    }

    func confirmReadOnly() {
        stopLock.lock(); defer { stopLock.unlock() }
        if mode == .automatic { readOnly = true }
    }

    deinit { stop() }
}

@MainActor @Observable
final class NativeBackendStore {
    private(set) var state: NativeBackendState = .disconnected
    private(set) var statusText = "未连接"
    private(set) var snapshot: NativeSnapshot?
    private(set) var errorMessage: String?
    private(set) var capabilities: Set<String> = []
    @ObservationIgnored private var child: BackendProcess?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var sequence: UInt64?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var pending: [String: CheckedContinuation<BackendJSON, Error>] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var helloTimer: Task<Void, Never>?
    @ObservationIgnored private let helperURL: URL
    @ObservationIgnored private let arguments: [String]
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let mode: NativeBackendMode
    @ObservationIgnored private let shutdownTimeout: Duration
    @ObservationIgnored private var shutdownTask: Task<Bool, Never>?
    @ObservationIgnored private let renewalRequestLimit: Int
    @ObservationIgnored private var requestCount = 0
    @ObservationIgnored private var renewalTask: Task<Void, Never>?
    @ObservationIgnored private var renewalRequested = false
    @ObservationIgnored private var hasSessionSnapshot = false
    @ObservationIgnored private var managedShutdownRequested = false
    @ObservationIgnored private var managedInputClosed = false
    @ObservationIgnored private var managedMainChannelBroken = false
    @ObservationIgnored private var receivedManagedHello = false
    @ObservationIgnored private var observerSession = false
    @ObservationIgnored private var automaticRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var automaticRecoveryAttempts = 0
    @ObservationIgnored private var authorizationResultUnconfirmed = false
    private(set) var serviceSetupInProgress = false
    private(set) var coreUpgradeInProgress = false
    private(set) var sessionProtectionInProgress = false
    private(set) var serviceCapabilitiesNeedRefresh = false

    private var authorizationInProgress: Bool { serviceSetupInProgress || coreUpgradeInProgress || sessionProtectionInProgress }
    private var authorizationLabel: String { sessionProtectionInProgress ? "会话保护切换" : coreUpgradeInProgress ? "内核升级" : "后台服务更新" }

    var requiresManagedShutdown: Bool {
        let managed = mode == .managed || (mode == .automatic && !observerSession)
        return managed && (child != nil || state == .shutdownFailed)
    }
    var blocksTermination: Bool { authorizationInProgress || requiresManagedShutdown }
    var isReadOnlyConnection: Bool {
        mode == .attach || (mode == .automatic && observerSession)
    }

    var canResumeCoreManagement: Bool {
        mode == .automatic && state == .connected && !workspaceBusy && !authorizationInProgress
            && (observerSession || serviceCapabilitiesNeedRefresh)
            && snapshot?.core.lifecycle?.canStart == true
    }

    func resumeCoreManagement() async throws {
        guard canResumeCoreManagement else {
            throw NativeBackendError.unavailable("启动条件尚未确认，请重新检测内核。")
        }
        if requiresManagedShutdown {
            guard await shutdownForTermination() else {
                throw NativeBackendError.unavailable("旧管理后台尚未安全退出，未启动新的管理后台。")
            }
        } else { disconnect() }
        connect()
        let deadline = ContinuousClock.now + .seconds(35)
        while state == .connecting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard state == .connected, !isReadOnlyConnection, supports("native_core_start") else {
            throw NativeBackendError.unavailable(errorMessage ?? "管理连接未恢复，未发送内核启动请求。请重新检测状态。")
        }
        _ = try await request("native_core_start", serialWorkspace: true)
        refresh()
    }

    init(mode: NativeBackendMode = .attach) {
        helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tez-native-host")
        arguments = ["--stdio", mode == .automatic ? "--automatic" : mode == .managed ? "--managed" : "--attach"]
        timeout = mode != .attach ? .seconds(30) : .seconds(8)
        self.mode = mode
        shutdownTimeout = .seconds(30)
        renewalRequestLimit = 3500
    }

    // Internal injection is reserved for standalone subprocess checks.
    init(helperURL: URL, arguments: [String], timeout: Duration = .seconds(8),
         mode: NativeBackendMode? = nil, shutdownTimeout: Duration = .seconds(30), renewalRequestLimit: Int = 3500) {
        self.helperURL = helperURL
        self.arguments = arguments
        self.timeout = timeout
        self.mode = mode ?? (arguments == ["--stdio", "--attach"] ? .attach : .managed)
        self.shutdownTimeout = shutdownTimeout
        self.renewalRequestLimit = max(2, min(3500, renewalRequestLimit))
    }

    func connect() {
        if authorizationInProgress {
            guard authorizationResultUnconfirmed, let transport = child, transport.started, !transport.process.isRunning else {
                errorMessage = "\(authorizationLabel)尚未结束，保留当前后台，不重复提交请求。"
                return
            }
            transport.process.terminationHandler = nil
            transport.recovery?.removeAfterConfirmedExit()
            child = nil
            releaseAuthorization()
            workspaceBusy = false
        }
        automaticRecoveryTask?.cancel()
        automaticRecoveryTask = nil
        automaticRecoveryAttempts = 0
        if (mode == .attach || mode == .automatic), state == .failed, child?.process.isRunning == false { child = nil }
        guard child == nil, state == .disconnected || state == .failed else { return }
        disconnect()
        startConnection()
    }

    private func startConnection() {
        receivedManagedHello = false
        observerSession = false
        state = .connecting
        statusText = "连接中"
        errorMessage = nil
        let token = generation
        let transport: BackendProcess
        do { transport = try BackendProcess(url: helperURL, arguments: arguments, mode: mode) }
        catch { fail("无法创建后台恢复通道", generation: token); return }
        child = transport
        transport.process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.fail("后台进程退出", generation: token) }
        }
        do { try transport.process.run(); transport.started = true }
        catch { fail("无法启动后台程序", generation: token); return }
        try? transport.input.fileHandleForReading.close()
        try? transport.output.fileHandleForWriting.close()
        try? transport.diagnostics.fileHandleForWriting.close()
        helloTimer = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail("后台握手超时", generation: token)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var decoder = BackendFrameDecoder()
            do {
                while true {
                    let data = transport.output.fileHandleForReading.availableData
                    if data.isEmpty { try decoder.finish(); break }
                    let messages = try decoder.append(data)
                    let delivered = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        for message in messages { self?.receive(message, generation: token) }
                        delivered.signal()
                    }
                    delivered.wait()
                }
                Task { @MainActor in self?.fail("后台输出关闭", generation: token, channelBroken: true) }
            } catch {
                Task { @MainActor in self?.fail("后台消息格式错误", generation: token, channelBroken: true) }
            }
        }
        DispatchQueue.global(qos: .utility).async {
            // Drain without retaining diagnostics: backend paths and secrets never enter UI logs.
            while !transport.diagnostics.fileHandleForReading.availableData.isEmpty {}
        }
    }

    func disconnect() {
        guard !authorizationInProgress else {
            errorMessage = "\(authorizationLabel)正在进行或结果未确认，保留当前后台。"
            return
        }
        automaticRecoveryTask?.cancel()
        automaticRecoveryTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        renewalRequested = false
        if requiresManagedShutdown {
            _ = beginManagedShutdown()
            return
        }
        resetSession()
        let cleanup = child?.recovery
        child?.process.terminationHandler = { _ in cleanup?.removeAfterConfirmedExit() }
        child?.stop()
        child = nil
        managedShutdownRequested = false
        managedInputClosed = false
        managedMainChannelBroken = false
        snapshot = nil
        errorMessage = nil
        state = .disconnected
        statusText = "未连接"
    }

    func reconnectAfterClaim() {
        guard mode == .automatic, observerSession, !workspaceBusy, state == .connected else { return }
        disconnect()
        connect()
    }

    func installService(params: [String: BackendJSON]) async throws -> BackendJSON {
        guard mode != .attach, state == .connected, supports("native_install_service"), !authorizationInProgress else {
            throw NativeBackendError.unavailable("当前连接未开放后台服务更新")
        }
        let result: BackendJSON
        do {
            result = try await request("native_install_service", params: params, serialWorkspace: true)
        } catch {
            if case NativeBackendError.remote(let remote) = error, remote.code == .string("SERVICE_INSTALL_FAILED") {
                serviceCapabilitiesNeedRefresh = true
            }
            throw error
        }
        if case .object(let fields) = result, fields["installed"] == .bool(true) {
            serviceCapabilitiesNeedRefresh = true
        }
        return result
    }

    func upgradeCore(params: [String: BackendJSON]) async throws -> BackendJSON {
        guard mode != .attach, state == .connected, supports("native_upgrade_core"), !authorizationInProgress else {
            throw NativeBackendError.unavailable("当前连接未开放内核升级")
        }
        return try await request("native_upgrade_core", params: params, serialWorkspace: true)
    }

    func shutdownForTermination() async -> Bool {
        guard !authorizationInProgress else {
            errorMessage = "\(authorizationLabel)正在进行或结果未确认，暂不退出后台。"
            return false
        }
        guard requiresManagedShutdown else { disconnect(); return true }
        return await beginManagedShutdown().value
    }

    private func resetSession() {
        serviceCapabilitiesNeedRefresh = false
        generation = UUID()
        helloTimer?.cancel()
        helloTimer = nil
        finishPending("后台连接断开")
        sessionID = nil
        capabilities.removeAll()
        sequence = nil
        refreshing = false
        refreshAgain = false
        requestCount = 0
        hasSessionSnapshot = false
    }

    private func scheduleAttachRenewal() {
        let readOnlyCapabilities: Set<String> = ["get_app_dir", "get_system_hostname", "native_get_snapshot",
                                                "native_subscribe", "native_unsubscribe", "native_get_activity"]
        guard mode == .attach, arguments == ["--stdio", "--attach"], state == .connected,
              requestCount >= renewalRequestLimit, !renewalRequested,
              capabilities.isSubset(of: readOnlyCapabilities), let transport = child else { return }
        renewalRequested = true
        state = .renewing
        statusText = "只读连接续期中"
        let drainToken = generation
        renewalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !pending.isEmpty {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, drainToken == generation else { return }
            }
            guard !Task.isCancelled, drainToken == generation else { return }
            // Retire the old event stream before terminating it, preserving its last snapshot.
            resetSession()
            let stopToken = generation
            transport.process.terminationHandler = nil
            transport.stop()
            let deadline = ContinuousClock.now + shutdownTimeout
            while transport.process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, stopToken == generation else { return }
            }
            guard !Task.isCancelled, stopToken == generation else { return }
            renewalTask = nil
            renewalRequested = false
            guard !transport.process.isRunning else {
                state = .failed
                statusText = "连接失败"
                errorMessage = "只读后台尚未退出。请稍后重新连接。"
                return
            }
            child = nil
            startConnection()
        }
    }

    private func beginManagedShutdown(failure: String? = nil) -> Task<Bool, Never> {
        guard !authorizationInProgress else {
            errorMessage = "\(authorizationLabel)尚未确认，不追加停止内核请求。"
            return Task { false }
        }
        if let shutdownTask { return shutdownTask }
        guard let transport = child else { return Task { state != .shutdownFailed } }
        managedShutdownRequested = true
        helloTimer?.cancel()
        helloTimer = nil
        refreshing = false
        refreshAgain = false
        transport.process.terminationHandler = nil
        state = .stopping
        statusText = "正在安全退出后台"
        errorMessage = failure
        if failure != nil { finishPending("后台连接异常，请求结果未确认") }
        let task = Task { @MainActor [self, shutdownTimeout] in
            if transport.process.isRunning && (managedMainChannelBroken || (managedInputClosed && transport.recovery?.isReady() == true)) {
                guard await recoverThroughPrivateChannel(transport) else { return false }
            } else if !managedInputClosed && transport.process.isRunning {
                if sessionID != nil && capabilities.contains("native_prepare_shutdown") {
                    let drainDeadline = ContinuousClock.now + shutdownTimeout
                    while !pending.isEmpty && transport.process.isRunning && ContinuousClock.now < drainDeadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    guard pending.isEmpty else {
                        markManagedShutdownFailed("后台请求尚未结束。保留控制通道，可以重试恢复。")
                        return false
                    }
                    if transport.process.isRunning {
                        do {
                            let prepared = try await sendRequest("native_prepare_shutdown", timeout: shutdownTimeout)
                            guard case .object(let result) = prepared, result["safeToExit"] == .bool(true) else {
                                throw NativeBackendError.unavailable("后台未确认清理成功")
                            }
                        } catch {
                            if managedMainChannelBroken {
                                guard await recoverThroughPrivateChannel(transport) else { return false }
                            } else {
                                markManagedShutdownFailed("后台清理未成功。保留控制通道，可以重试恢复。")
                                return false
                            }
                        }
                    }
                }
                resetSession()
                managedInputClosed = true
                transport.stop()
            }
            let deadline = ContinuousClock.now + shutdownTimeout
            while transport.process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let refusal = startupRefusal(transport)
            let confirmed = refusal != nil || !transport.started || (!transport.process.isRunning
                && transport.process.terminationReason == .exit && transport.process.terminationStatus == 0
            )
            if confirmed {
                resetSession()
                child = nil
                managedShutdownRequested = false
                managedInputClosed = false
                managedMainChannelBroken = false
                transport.recovery?.removeAfterConfirmedExit()
                snapshot = failure == nil ? nil : snapshot
                state = failure == nil ? .disconnected : .failed
                statusText = failure == nil ? "未连接" : "连接失败"
                if failure != nil, let refusal { errorMessage = refusal }
                shutdownTask = nil
            } else {
                // Keep the child and refuse reconnect: EOF is not proof that its owned Core stopped.
                markManagedShutdownFailed("未确认内核已停止。保留后台所有权，不强制退出或重新连接。")
            }
            return confirmed
        }
        shutdownTask = task
        return task
    }

    private func markManagedShutdownFailed(_ message: String) {
        state = .shutdownFailed
        statusText = "后台安全退出未确认"
        errorMessage = message
        shutdownTask = nil
    }

    private func recoverThroughPrivateChannel(_ transport: BackendProcess) async -> Bool {
        guard let recovery = transport.recovery, recovery.isReady() else {
            markManagedShutdownFailed("主控制通道已中断，独立恢复通道尚未确认。保留后台所有权。")
            return false
        }
        if !managedInputClosed {
            resetSession()
            managedInputClosed = true
            transport.stop()
        }
        do {
            let sequence = try recovery.requestShutdown()
            let deadline = ContinuousClock.now + shutdownTimeout
            while ContinuousClock.now < deadline {
                if let safe = try? recovery.response(for: sequence) {
                    guard safe else {
                        markManagedShutdownFailed("独立通道确认清理尚未成功，可以重试恢复。")
                        return false
                    }
                    return true
                }
                if !transport.process.isRunning { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {}
        markManagedShutdownFailed("独立恢复未确认成功。保留后台所有权，可以重试恢复。")
        return false
    }

    func supports(_ command: String) -> Bool {
        state == .connected && capabilities.contains(command)
    }

    func refresh() {
        guard state == .connected else { return }
        if workspaceBusy { refreshAgain = true; return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let token = generation
        Task { [weak self] in
            guard let self, token == generation else { return }
            do {
                let value = try await request("native_get_snapshot")
                guard token == generation else { return }
                try apply(value)
                refreshing = false
                if !renewalRequested && !managedShutdownRequested { statusText = "已连接" }
                if refreshAgain { refreshAgain = false; refresh() }
            } catch NativeBackendError.unavailable(let message) where message == "后台正在执行请求，请等待完成" {
                guard token == generation else { return }
                refreshing = false
                refreshAgain = true
                if !workspaceBusy { refreshAgain = false; refresh() }
            } catch { fail("刷新后台数据失败", generation: token) }
        }
    }

    private(set) var workspaceBusy = false

    func request(_ command: String, params: [String: BackendJSON] = [:], timeout requestTimeout: Duration? = nil,
                 serialWorkspace: Bool = false) async throws -> BackendJSON {
        guard !managedShutdownRequested else {
            throw NativeBackendError.unavailable("后台正在退出，只允许重试恢复")
        }
        guard !workspaceBusy else { throw NativeBackendError.unavailable("后台正在执行请求，请等待完成") }
        let humanPaced = command == "native_install_service" || command == "native_upgrade_core" || command == "native_set_session_protection" || command == "native_set_runtime_protection"
        if humanPaced {
            guard mode != .attach, state == .connected, capabilities.contains(command), !authorizationInProgress else {
                throw NativeBackendError.unavailable("当前连接未开放此授权操作")
            }
            serviceSetupInProgress = command == "native_install_service"
            coreUpgradeInProgress = command == "native_upgrade_core"
            sessionProtectionInProgress = command == "native_set_session_protection" || command == "native_set_runtime_protection"
            authorizationResultUnconfirmed = false
        }
        let serialized = serialWorkspace || humanPaced
        if serialized { workspaceBusy = true }
        defer {
            if humanPaced && !authorizationResultUnconfirmed { releaseAuthorization() }
            if serialized && !(humanPaced && authorizationResultUnconfirmed) {
                workspaceBusy = false
                if refreshAgain { refreshAgain = false; refresh() }
            }
        }
        do {
            let result = try await sendRequest(command, params: params, timeout: requestTimeout)
            if command == "native_upgrade_core" {
                guard case .object(let fields) = result, case .string(let outcome) = fields["outcome"],
                      ["upgraded", "rolled_back"].contains(outcome) else {
                    errorMessage = "后台未返回可确认的升级结果，请重新检查当前内核。"
                    throw NativeBackendError.unavailable("内核升级结果未确认")
                }
                authorizationResultUnconfirmed = false
            }
            return result
        } catch NativeBackendError.remote(let remote) {
            if command == "native_upgrade_core" && remote.code == .string("CORE_UPGRADE_UNRESOLVED") {
                errorMessage = "升级或回退结果未确认，请重新检查当前内核；不会自动重试升级。"
            }
            throw NativeBackendError.remote(remote)
        }
    }

    private func sendRequest(_ command: String, params: [String: BackendJSON] = [:], timeout requestTimeout: Duration? = nil) async throws -> BackendJSON {
        guard !renewalRequested, sessionID != nil, let child, pending.count < 32 else {
            throw NativeBackendError.unavailable("后台不可用或请求数量达到上限")
        }
        let id = capabilities.contains("native_continuous_session") ? "seq:\(requestCount + 1)" : UUID().uuidString
        let data = try BackendWire.encode(.request(id: id, command: command, params: params))
        let token = generation
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            requestCount += 1
            // Administrator authorization is human-paced; a request timeout must not detach its installer.
            if command != "native_install_service" && command != "native_upgrade_core" && command != "native_set_session_protection" && command != "native_set_runtime_protection" {
                timers[id] = Task { [weak self, timeout = requestTimeout ?? timeout] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, let self, token == generation else { return }
                    timers.removeValue(forKey: id)
                    pending.removeValue(forKey: id)?.resume(throwing: NativeBackendError.unavailable("请求超时"))
                }
            }
            child.writes.async { [weak self] in
                do { try child.input.fileHandleForWriting.write(contentsOf: data) }
                catch { Task { @MainActor in self?.fail("后台输入关闭", generation: token, channelBroken: true) } }
            }
            scheduleAttachRenewal()
        }
    }

    private func receive(_ message: BackendMessage, generation token: UUID) {
        guard token == generation else { return }
        switch message {
        case .hello(let id, let advertisedCapabilities):
            let advertised = Set(advertisedCapabilities)
            guard sessionID == nil, advertised.isSuperset(of: ["native_subscribe", "native_get_snapshot"]) else {
                fail("后台握手不兼容", generation: token); return
            }
            if mode == .automatic && !advertised.contains("native_prepare_shutdown") {
                let observerCommands: Set<String> = ["get_app_dir", "get_system_hostname", "native_get_snapshot",
                    "native_subscribe", "native_unsubscribe", "native_get_activity", "native_continuous_session", "native_inspect_core", "native_claim_core", "native_install_service"]
                guard advertised.isSubset(of: observerCommands), advertised.contains("native_inspect_core") else {
                    fail("自动发现后台未声明安全的只读能力", generation: token); return
                }
            }
            receivedManagedHello = true
            capabilities = advertised
            if mode == .automatic && !advertised.contains("native_prepare_shutdown") {
                observerSession = true
                child?.confirmReadOnly()
            }
            sessionID = id
            helloTimer?.cancel()
            helloTimer = nil
            Task { [weak self] in
                guard let self, token == generation else { return }
                do {
                    let value = try await request("native_subscribe")
                    guard token == generation else { return }
                    try apply(value)
                    if !managedShutdownRequested {
                        state = .connected
                        statusText = "已连接"
                    }
                } catch { fail("订阅后台数据失败", generation: token) }
            }
        case .response(let id, let outcome):
            guard sessionID != nil else { fail("后台在握手前返回响应", generation: token); return }
            guard let continuation = pending.removeValue(forKey: id) else { return }
            timers.removeValue(forKey: id)?.cancel()
            switch outcome {
            case .result(let value): continuation.resume(returning: value)
            case .error(let error): continuation.resume(throwing: NativeBackendError.remote(error))
            }
        case .event(let number, let name, let payload):
            if managedShutdownRequested { return }
            guard sessionID != nil, let next = UInt64(number) else {
                fail("后台事件格式错误", generation: token); return
            }
            let expected = sequence.map { $0 == UInt64.max ? nil : $0 + 1 } ?? 1
            guard expected == next else {
                // Reconnect is explicit: never present a potentially incomplete event stream as current.
                fail("后台事件中断，请重新连接", generation: token); return
            }
            sequence = next
            if name == "tez://snapshot-changed" {
                do { try apply(payload) }
                catch { fail("后台数据格式错误", generation: token) }
            }
        case .request: fail("后台返回了非预期请求", generation: token)
        }
    }

    private func apply(_ value: BackendJSON) throws {
        let next = try NativeSnapshot.decode(value)
        if hasSessionSnapshot, let current = snapshot, let old = UInt64(current.revision), let new = UInt64(next.revision), new < old { return }
        snapshot = next
        hasSessionSnapshot = true
    }

    private func finishPending(_ message: String) {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: NativeBackendError.unavailable(message)) }
    }

    private func releaseAuthorization() {
        serviceSetupInProgress = false
        coreUpgradeInProgress = false
        sessionProtectionInProgress = false
        authorizationResultUnconfirmed = false
    }

    private func markAuthorizationUnconfirmed(_ message: String) {
        authorizationResultUnconfirmed = true
        state = .failed
        statusText = "\(authorizationLabel)结果未确认"
        errorMessage = "\(message)。保留当前后台，不重复升级或请求停止内核。后台退出后可重新连接。"
    }

    private func fail(_ message: String, generation token: UUID, channelBroken: Bool = false) {
        guard generation == token else { return }
        if mode != .attach && channelBroken { managedMainChannelBroken = true }
        if authorizationInProgress {
            markAuthorizationUnconfirmed(message)
            finishPending("授权操作结果未确认，保留当前后台")
            return
        }
        if mode != .attach && managedShutdownRequested {
            finishPending("后台控制通道异常，请求结果未确认")
            return
        }
        if mode == .automatic, let child, child.started, !child.process.isRunning {
            child.recovery?.removeAfterConfirmedExit()
            self.child = nil
        }
        if requiresManagedShutdown, let child {
            let refusal = startupRefusal(child)
            if refusal != nil || !child.started || (!child.process.isRunning && child.process.terminationReason == .exit && child.process.terminationStatus == 0) {
                child.recovery?.removeAfterConfirmedExit()
                self.child = nil
                if let refusal {
                    disconnect()
                    state = .failed
                    statusText = "接管未启动"
                    errorMessage = refusal
                    return
                }
            } else {
                _ = beginManagedShutdown(failure: message)
                return
            }
        }
        let lastSnapshot = snapshot
        disconnect()
        snapshot = lastSnapshot
        state = .failed
        statusText = "连接失败"
        errorMessage = message
        scheduleAutomaticRecovery()
    }

    private func scheduleAutomaticRecovery() {
        guard mode == .automatic, child == nil, !managedShutdownRequested, automaticRecoveryAttempts < 3 else { return }
        automaticRecoveryAttempts += 1
        let delay = 1 << (automaticRecoveryAttempts - 1)
        let token = generation
        statusText = "后台连接中断，正在重新检测（\(automaticRecoveryAttempts)/3）"
        automaticRecoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, token == generation, child == nil, state == .failed else { return }
            automaticRecoveryTask = nil
            resetSession()
            startConnection()
        }
    }

    private func startupRefusal(_ transport: BackendProcess) -> String? {
        guard mode == .managed, !receivedManagedHello, transport.started,
              !transport.process.isRunning, transport.process.terminationReason == .exit else { return nil }
        switch transport.process.terminationStatus {
        case 73: return "实例锁不可用。请先退出旧版 Tez，再重试接管。当前代理未改变。"
        case 78: return "接管启动检查未通过。当前代理未改变，可以关闭新版或打开旧版。"
        default: return nil
        }
    }
}
