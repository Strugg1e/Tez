import AppKit
import SwiftUI

@MainActor @Observable
private final class LayoutSelection {
    var section: WorkspaceSection? = .routes
}

@MainActor @Observable
private final class LayoutMeasurement {
    var height: CGFloat = 0
}

@main
struct NativeLayoutCheck {
    @MainActor private static var uiTarget: LayoutMenuTarget?
    private static var routeControlsEnabled: Bool {
        CommandLine.arguments.contains("--route-controls") || Bundle.main.object(forInfoDictionaryKey: "TezLayoutFixtureUI") as? Bool == true
    }
    private static var managedServiceIdle: Bool { CommandLine.arguments.contains("--managed-service-idle") }
    private static var protectionCheck: Bool {
        CommandLine.arguments.contains("--protection-check") || Bundle.main.object(forInfoDictionaryKey: "TezProtectionFixtureUI") as? Bool == true
    }
    private static var oldProtectionService: Bool {
        CommandLine.arguments.contains("--protection-old-service") || Bundle.main.object(forInfoDictionaryKey: "TezProtectionOldServiceFixtureUI") as? Bool == true
    }
    private static var protectionRollback: Bool {
        CommandLine.arguments.contains("--protection-rollback") || Bundle.main.object(forInfoDictionaryKey: "TezProtectionRollbackFixtureUI") as? Bool == true
    }
    private static var coreLifecycleCheck: Bool {
        CommandLine.arguments.contains("--core-lifecycle-check") || Bundle.main.object(forInfoDictionaryKey: "TezCoreLifecycleFixtureUI") as? Bool == true
    }
    static let idleInspection = NativeCoreInspection(state: "stopped", source: "service", canStart: true,
        reason: "idle-service", corePid: nil, serviceGeneration: nil, processes: [],
        serviceProtocol: "2.6", serviceControlAvailable: true)
    static let inspection = NativeCoreInspection(state: "runningReadOnly", source: "service", canStart: false,
        reason: "service-upgrade-required", corePid: 123, serviceGeneration: 42,
        serviceStartedAt: 1793180000,
        processes: [NativeCoreProcess(pid: 123, uid: 0,
            executable: "/Library/Application Support/fixture-service/cores/mihomo", startedAt: "Wed Oct 28 17:33:02 2026")],
        serviceProtocol: "2.5", serviceControlAvailable: false)
    static let protectedInspection = NativeCoreInspection(state: "runningReadOnly", source: "service", canStart: false,
        reason: "service-session-unavailable", corePid: 123, serviceGeneration: 42,
        serviceStartedAt: 1793180000,
        processes: [NativeCoreProcess(pid: 123, uid: 0, executable: "/fixture/TezCore", startedAt: "Wed Oct 28 17:33:02 2026")],
        serviceProtocol: "2.6", serviceControlAvailable: true)
    static let profiles = [
        NativeProfileItem(uid: "profile-1", name: "Daily Configuration", type: "remote", updated: 1793000000),
        NativeProfileItem(uid: "profile-2", name: "Research Workspace / Extended Remote Configuration", type: "remote", updated: 1793080000),
        NativeProfileItem(uid: "profile-3", name: "Local Testing", type: "local", updated: 1793100000),
        NativeProfileItem(uid: "enhancement-1", name: "Network Overrides", type: "merge", updated: 1793100000),
        NativeProfileItem(uid: "enhancement-2", name: "Routing Rules", type: "rules", updated: nil),
        NativeProfileItem(uid: "enhancement-3", name: "Startup Script", type: "script", updated: nil)
    ]
    static func json<T: Encodable>(_ value: T) throws -> BackendJSON {
        try JSONDecoder().decode(BackendJSON.self, from: JSONEncoder().encode(value))
    }

    static func snapshot(current: String? = nil, groupCurrent: String? = nil, revision: String = "1", mode: String = "global", systemProxy: Bool = true, tun: Bool = true, coreOverride: NativeCoreSnapshot? = nil) throws -> BackendJSON {
        let names = (1...24).map { $0 == 2 ? "Tokyo Residential - Long Route Name 02" : "Tokyo \(String(format: "%02d", $0))" }
        let records = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            let id = "node-\(index)"
            let history = index % 6 == 0 ? [] : [NativeDelayHistory(time: "2026-10-29T10:00:00Z", delay: index == 4 ? 0 : UInt64(42 + index * 7))]
            return (id, NativeProxyNode(recordId: id, name: name, type: "Shadowsocks", history: history,
                id: nil, hidden: false, icon: nil, testUrl: nil, udp: true, xudp: false, tfo: false,
                mptcp: false, smux: false, source: NativeProxySource(kind: "core", proxyName: name, providerName: nil)))
        })
        let members = names.enumerated().map {
            NativeProxyMember(kind: "node", name: $0.element, recordId: "node-\($0.offset)", reason: nil)
        }
        let group = NativeProxyGroup(name: "GLOBAL", type: "Selector", now: current ?? names[0], fixed: nil,
            hidden: false, icon: nil, testUrl: nil, history: [], udp: true, xudp: false, tfo: false,
            mptcp: false, smux: false, members: members)
        let policy = NativeProxyGroup(name: "Daily Policy", type: "Selector", now: groupCurrent ?? names[2], fixed: nil,
            hidden: false, icon: nil, testUrl: nil, history: [], udp: true, xudp: false, tfo: false,
            mptcp: false, smux: false, members: members)
        return try json(NativeSnapshot(revision: revision, profiles: NativeProfilesSnapshot(state: "ready",
            current: "profile-1", items: profiles, message: nil),
            proxyView: NativeProxyView(schemaVersion: 1, orderSource: "core", providerState: "ready",
                global: group, direct: nil, groups: [policy], records: records, standalone: [], providers: []),
            core: coreOverride ?? NativeCoreSnapshot(state: managedServiceIdle ? "unavailable" : "ready", message: nil, source: "service", lifecycle: managedServiceIdle || protectionCheck ? nil : inspection),
            network: NativeNetworkSnapshot(systemProxy: NativeObservedSwitch(state: "ready", enabled: systemProxy),
                pac: NativeObservedSwitch(state: "ready", enabled: false), tun: NativeObservedSwitch(state: "ready", enabled: tun),
                mode: NativeObservedMode(state: "ready", value: mode))))
    }

    static func fixture() throws {
        func emit(_ message: BackendMessage) throws {
            try FileHandle.standardOutput.write(contentsOf: BackendWire.encode(message))
        }
        let routeControls = routeControlsEnabled
        var selections: [String: String] = [:]
        var revision = 1
        var mode = routeControls ? "rule" : "global"
        var systemProxy = true
        var tun = true
        var activityReads = 0
        var closedConnections: Set<String> = []
        var protection = false
        var transportProtection = false
        let transportReport: BackendJSON = .object([
            "nodes": .array([
                .object(["name": .string("Tokyo TLS"), "protocol": .string("vless"), "status": .string("eligible")]),
                .object(["name": .string("Frankfurt · Subscription preset"), "protocol": .string("trojan"), "status": .string("existing")]),
                .object(["name": .string("Hong Kong Shadowsocks"), "protocol": .string("ss"), "status": .string("unsupported")])]),
            "dynamicProviders": .integer(1), "dns": .object(["enabled": .bool(true), "encryptedResolvers": .integer(2),
                "otherResolvers": .integer(1), "followsRules": .bool(false), "nodeResolverConfigured": .bool(false)])])
        var corePID: Int64 = 123
        var serviceAvailable = false
        var coreRunning = false
        var installAttempts = 0
        func coreInspection() -> NativeCoreInspection {
            if !serviceAvailable {
                return NativeCoreInspection(state: "unknown", source: "unknown", canStart: false, reason: "service-unavailable",
                    corePid: nil, serviceGeneration: nil, processes: [])
            }
            if !coreRunning { return idleInspection }
            return NativeCoreInspection(state: "running", source: "service", canStart: false, reason: "owned-service",
                corePid: UInt32(corePID), serviceGeneration: 42, serviceStartedAt: 1793180000, processes: [],
                serviceProtocol: "2.6", serviceControlAvailable: true)
        }
        let capabilities = ["native_continuous_session", "native_subscribe",
            "native_get_snapshot", "native_get_activity", "native_close_connection", "native_get_settings", "native_get_logs", "native_inspect_core", "native_subscription_details",
            "native_claim_core", "native_get_core_control", "native_prepare_core_upgrade", "native_upgrade_core", "native_install_service"]
            + (routeControls ? ["native_select_route", "native_test_latency", "native_patch_settings", "native_set_mode"] : [])
            + (managedServiceIdle ? ["native_prepare_shutdown"] : [])
            + (protectionCheck ? ["native_prepare_shutdown"] + (oldProtectionService ? [] : ["native_set_session_protection", "native_set_runtime_protection"]) : [])
            + (coreLifecycleCheck ? ["native_prepare_shutdown", "native_core_start", "native_core_stop", "native_core_restart"] : [])
        try emit(.hello(sessionID: "layout-fixture", capabilities: capabilities))
        while let line = readLine() {
            guard case .request(let id, let command, let params) = try BackendWire.decode(Data(line.utf8)) else { fatalError() }
            let result: BackendJSON
            switch command {
            case "native_close_connection":
                guard case .string(let id) = params["id"], id.hasPrefix("connection-") else { fatalError() }
                closedConnections.insert(id)
                result = .object(["closed": .bool(true), "id": .string(id)])
            case "native_subscribe", "native_get_snapshot":
                result = try snapshot(current: selections["GLOBAL"], groupCurrent: selections["Daily Policy"], revision: String(revision), mode: mode, systemProxy: systemProxy, tun: tun,
                    coreOverride: coreLifecycleCheck ? NativeCoreSnapshot(state: coreRunning ? "ready" : "unavailable", message: nil, source: "service", lifecycle: coreInspection()) : nil)
            case "native_inspect_core" where coreLifecycleCheck: result = try json(coreInspection())
            case "native_install_service" where coreLifecycleCheck:
                installAttempts += 1
                if installAttempts == 1 {
                    serviceAvailable = true; revision += 1
                    try emit(.response(id: id, outcome: .error(.init(detail: "Installation failed; the background service was restored: Timed out waiting for the service to release its owner lock", code: .string("SERVICE_INSTALL_FAILED"), operation: nil))))
                    continue
                }
                serviceAvailable = true; revision += 1
                result = .object(["installed": .bool(true), "reconnectRequired": .bool(false)])
            case _ where coreLifecycleCheck && ["native_core_start", "native_core_stop", "native_core_restart"].contains(command):
                Thread.sleep(forTimeInterval: 0.25)
                coreRunning = command != "native_core_stop"
                if coreRunning { corePID += 1 }
                revision += 1
                result = .object(["mode": .string(coreRunning ? "Service" : "NotRunning")])
            case "native_prepare_shutdown" where coreLifecycleCheck: result = .object(["safeToExit": .bool(true)])
            case "native_set_mode" where routeControls:
                guard case .string(let value) = params["mode"] else { fatalError() }
                mode = value; revision += 1
                result = .object(["applied": .bool(true)])
            case "native_patch_settings" where routeControls:
                guard case .object(let values) = params["values"] else { fatalError() }
                if case .bool(let value) = values["enable_system_proxy"] { systemProxy = value }
                if case .bool(let value) = values["enable_tun_mode"] { tun = value }
                revision += 1
                result = .object(["saved": .bool(true)])
            case "native_select_route" where routeControls:
                guard case .string(let name) = params["name"], case .string(let group) = params["group"],
                      ["GLOBAL", "Daily Policy"].contains(group) else { fatalError() }
                Thread.sleep(forTimeInterval: 6)
                if name == "Tokyo 24" {
                    result = .object(["applied": .bool(false), "persisted": .bool(false)])
                    break
                }
                selections[group] = name
                revision += 1
                let incomplete = name.contains("Long Route")
                result = .object(["applied": .bool(true), "persisted": .bool(true),
                    "connectionCleanup": .object(["requested": .bool(true), "completed": .bool(!incomplete), "closed": .integer(0),
                        "failure": incomplete ? .object(["code": .string("CONNECTION_CLOSE_FAILED"), "detail": .string("Isolated fixture cleanup refusal")]) : .null])])
            case "native_test_latency" where routeControls:
                guard case .array(let names) = params["names"] else { fatalError() }
                Thread.sleep(forTimeInterval: 0.45)
                result = .object(["results": .array(names.enumerated().map { index, name in
                    .object(["name": name, "delay": .integer(Int64(38 + index * 17)), "error": .null])
                })])
            case "native_inspect_core": result = try json(managedServiceIdle ? idleInspection : protectionCheck ? protectedInspection : inspection)
            case "native_install_service":
                guard params["confirmed"] == .bool(true), !managedServiceIdle || params["expected"] == .null else { fatalError() }
                result = .object(["installed": .bool(true), "reconnectRequired": .bool(!managedServiceIdle)])
            case "native_prepare_shutdown" where managedServiceIdle || protectionCheck: result = .object(["safeToExit": .bool(true)])
            case "native_get_core_control": result = .object(["generation": .integer(42), "pid": .integer(corePID), "started_at": .integer(1793180000),
                "protectionSupported": .bool(!oldProtectionService), "enabled": oldProtectionService ? .null : .bool(protection),
                "transportSupported": .bool(!oldProtectionService), "transportEnabled": .bool(transportProtection), "transportReport": transportReport])
            case "native_set_runtime_protection" where protectionCheck && !oldProtectionService:
                guard params["confirmed"] == .bool(true), case .bool(let process) = params["processEnabled"],
                      case .bool(let transport) = params["transportEnabled"], case .object(let expected) = params["expected"],
                      expected["pid"] == .integer(corePID) || expected["pid"] == .unsigned(UInt64(corePID)) else { fatalError() }
                Thread.sleep(forTimeInterval: 1)
                corePID += 1
                if !protectionRollback { protection = process; transportProtection = transport }
                result = .object(["generation": .integer(42), "pid": .integer(corePID), "started_at": .integer(1793180000),
                    "protectionSupported": .bool(true), "enabled": .bool(protection), "transportSupported": .bool(true),
                    "transportEnabled": .bool(transportProtection), "transportReport": transportReport,
                    "outcome": .string(protectionRollback ? "rolled_back" : "changed")])
            case "native_set_session_protection" where protectionCheck && !oldProtectionService:
                guard params["confirmed"] == .bool(true), case .bool(let enabled) = params["enabled"],
                      case .object(let expected) = params["expected"], expected["pid"] == .integer(corePID) || expected["pid"] == .unsigned(UInt64(corePID)) else { fatalError() }
                Thread.sleep(forTimeInterval: 1)
                corePID += 1
                if !protectionRollback { protection = enabled }
                result = .object(["generation": .integer(42), "pid": .integer(corePID), "started_at": .integer(1793180000),
                    "enabled": .bool(protection), "outcome": .string(protectionRollback ? "rolled_back" : "changed")])
            case "native_claim_core": result = .object(["claimed": .bool(true), "reconnectRequired": .bool(true)])
            case "native_prepare_core_upgrade": result = .object(["path": .string("/fixture/tez-" + String(repeating: "a", count: 64)), "sha256": .string(String(repeating: "a", count: 64)), "version": .string("fixture-1")])
            case "native_upgrade_core": result = .object(["outcome": .string("rolled_back"), "pid": .integer(124), "versionSelectionSaved": .bool(true)])
            case "native_get_settings": result = .object(["values": .object(["enable_system_proxy": .bool(systemProxy), "enable_tun_mode": .bool(tun)]), "mode": .string(mode)])
            case "native_subscription_details":
                guard case .string(let uid) = params["uid"] else { fatalError() }
                result = .object(["uid": .string(uid), "name": .string(profiles.first { $0.uid == uid }?.name ?? ""),
                    "url": .string("https://subscription.example.test/config"), "interval": .integer(1440), "autoUpdate": .bool(true), "withProxy": .bool(false),
                    "usage": .object(["upload": .integer(2_147_483_648), "download": .integer(9_663_676_416), "total": .integer(53_687_091_200), "expire": .integer(1800000000)]),
                    "nextUpdate": .integer(1793400000)])
            case "native_get_logs":
                let query = params["query"].flatMap { if case .string(let value) = $0 { value } else { nil } } ?? ""
                let level = params["level"].flatMap { if case .string(let value) = $0 { value } else { nil } } ?? "all"
                let lines = (1...36).map { index in
                    "[\(index % 9 == 0 ? "warn" : "info")] [TCP] Fixture connection \(index) to service-\(index).example.test:443 via Tokyo 01"
                }.filter { (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) && (level == "all" || $0.hasPrefix("[\(level)]")) }
                result = .object(["lines": .array(lines.map(BackendJSON.string)), "streaming": .bool(false), "gap": .bool(false), "truncated": .bool(false)])
            case "native_get_activity":
                activityReads += 1
                let rows: [BackendJSON] = (1...24).map { (index: Int) -> BackendJSON in
                    let fields: [String: BackendJSON] = [
                    "id": .string("connection-\(index)"), "closeable": .bool(true), "host": .string("service-\(index).example.test"),
                    "destination": .string("192.0.2.1:443"), "network": .string("tcp"), "type": .string("HTTPS"),
                    "process": .string(index % 2 == 0 ? "Terminal" : "Browser Helper"),
                    "application": index % 5 == 0 ? .null : .string(index % 2 == 0 ? "Terminal" : "Browser"),
                    "rule": .string(index % 3 == 0 ? "Match" : "DomainSuffix"),
                    "rulePayload": .string(index % 3 == 0 ? "" : "example.test"),
                    "outbound": index % 5 == 0 ? .null : .string(index % 3 == 0 ? "DIRECT" : "Tokyo Residential - Long Route Name 02"),
                    "chainOrder": .string("exit-first"),
                    "chains": index % 5 == 0 ? .array([]) : .array([.string(index % 3 == 0 ? "DIRECT" : "Tokyo Residential - Long Route Name 02"), .string("Daily Policy")]),
                    "upload": .integer(Int64(index * 1024 + (index % 2 == 0 ? activityReads * 1024 : 0))), "download": .integer(Int64(index * 24576 + (index % 2 == 0 ? activityReads * 4096 : 0))), "start": .string("2026-10-29T10:00:00Z")
                    ]
                    return .object(fields)
                }.filter { item in
                    guard case .object(let fields) = item, case .string(let id) = fields["id"] else { return false }
                    return !closedConnections.contains(id)
                }
                let rules: [BackendJSON] = (1...12).map { (index: Int) -> BackendJSON in
                    let fields: [String: BackendJSON] = [
                    "index": .integer(Int64(index)), "type": .string(index % 2 == 0 ? "DOMAIN-SUFFIX" : "DOMAIN"),
                    "payload": .string("service-\(index).example.test"), "proxy": .string(index % 2 == 0 ? "DIRECT" : "Daily Policy"), "size": .integer(1)
                    ]
                    return .object(fields)
                }
                let providers: [BackendJSON] = (1...3).map { (index: Int) -> BackendJSON in
                    let fields: [String: BackendJSON] = [
                    "name": .string("Rule Source \(index)"), "behavior": .string("classical"), "format": .string("yaml"),
                    "type": .string("Rule"), "ruleCount": .integer(Int64(index * 128)), "updatedAt": .string("2026-10-29T10:00:00Z"), "vehicleType": .string("HTTP")
                    ]
                    return .object(fields)
                }
                let query = params["query"].flatMap { if case .string(let value) = $0 { value } else { nil } } ?? ""
                func matching(_ items: [BackendJSON]) -> [BackendJSON] {
                    items.filter { item in
                        guard case .object(let fields) = item else { return false }
                        return query.isEmpty || fields.values.contains { value in
                            if case .string(let text) = value { return text.localizedCaseInsensitiveContains(query) }
                            return false
                        }
                    }
                }
                func section(_ items: [BackendJSON]) -> BackendJSON {
                    let matches = matching(items)
                    return .object(["state": .string("ready"), "items": .array(matches), "total": .integer(Int64(items.count)),
                        "matched": .integer(Int64(matches.count)), "offset": .integer(0), "nextOffset": .null, "truncated": .bool(false)])
                }
                let matches = matching(rows)
                result = .object(["schemaVersion": .integer(1), "source": .string("sidecar"),
                    "connections": .object(["state": .string("ready"), "items": .array(matches), "total": .integer(Int64(rows.count)),
                        "matched": .integer(Int64(matches.count)), "offset": .integer(0), "nextOffset": .null, "truncated": .bool(false),
                        "uploadTotal": .integer(Int64(307200 + activityReads * 1024)),
                        "downloadTotal": .integer(Int64(7372800 + activityReads * 2048)), "memory": .integer(67108864)]),
                    "rules": section(rules), "providers": section(providers)])
            default: fatalError("Layout fixture rejected an unexpected command: \(command)")
            }
            try emit(.response(id: id, outcome: .result(result)))
        }
    }

    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--fixture") { try fixture(); return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await check(app: app)
                if uiTarget == nil { exit(0) }
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func check(app: NSApplication) async throws {
        try checkLatencySort()
        try checkTaskModels()
        let offline = TezConnectionPresentation(state: .failed, hasSnapshot: true, coreState: "ready", writable: true)
        precondition(offline.coreTitle == "内核状态未确认" && offline.context.contains("离线快照"))
        let connected = TezConnectionPresentation(state: .connected, hasSnapshot: true, coreState: "ready", writable: false)
        precondition(connected.coreTitle == "内核运行中" && connected.context == "只读访问")
        precondition(TezMotion(reduced: true).feedback == nil && TezMotion(reduced: true).layout == nil
                     && TezMotion(reduced: true).mechanism == nil)
        let suite = "tez.layout-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = TezPreviewPreferences(defaults: defaults)
        let selection = LayoutSelection()
        if managedServiceIdle || protectionCheck || coreLifecycleCheck { selection.section = .connection }
        if Bundle.main.object(forInfoDictionaryKey: "TezProfilesFixtureUI") as? Bool == true { selection.section = .profiles }
        if CommandLine.arguments.contains("--profile-search-check") { selection.section = .profiles }
        let store = NativeBackendStore(helperURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            arguments: ["--fixture"] + (routeControlsEnabled ? ["--route-controls"] : []) + (managedServiceIdle ? ["--managed-service-idle"] : [])
                + (protectionCheck ? ["--protection-check"] : []) + (oldProtectionService ? ["--protection-old-service"] : [])
                + (protectionRollback ? ["--protection-rollback"] : []) + (coreLifecycleCheck ? ["--core-lifecycle-check"] : []),
            mode: protectionCheck || coreLifecycleCheck ? .managed : managedServiceIdle ? .automatic : .attach)
        store.connect()
        for _ in 0..<200 {
            if store.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard store.state == .connected else { fatalError("Layout fixture did not connect") }
        let root = LiveWorkspaceView(store: store, selection: Binding(get: { selection.section }, set: { selection.section = $0 }))
            .environment(preferences).preferredColorScheme(preferences.appearance.colorScheme)
        let host = NSHostingView(rootView: root)
        let compact = Bundle.main.object(forInfoDictionaryKey: "TezCompactFixtureUI") as? Bool == true
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: compact ? 800 : 1040, height: compact ? 560 : 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Tez Layout Check"
        window.toolbarStyle = .unified
        window.contentView = host
        if CommandLine.arguments.contains("--profile-search-check") {
            defer { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
            try await profileSearchCheck(host)
            return
        }
        if CommandLine.arguments.contains("--ui") || Bundle.main.object(forInfoDictionaryKey: "TezLayoutFixtureUI") as? Bool == true {
            showUI(app: app, window: window, preferences: preferences, store: store, selection: selection, suite: suite)
            return
        }
        defer { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
        if coreLifecycleCheck {
            precondition(store.snapshot?.core.lifecycle?.reason == "service-unavailable")
            do {
                _ = try await store.installService(params: ["confirmed": .bool(true), "expected": .null])
                fatalError("Injected installation failure must surface")
            } catch NativeBackendError.remote(let error) {
                precondition(error.detail.contains("owner lock"))
            }
            precondition(!store.workspaceBusy && store.state == .connected)
            precondition(store.serviceCapabilitiesNeedRefresh, "a partial installation can change the restored service capabilities")
            _ = try await store.installService(params: ["confirmed": .bool(true), "expected": .null])
            store.refresh()
            for _ in 0..<200 {
                if store.snapshot?.core.lifecycle?.state == "stopped" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(store.snapshot?.core.lifecycle?.state == "stopped", "installation must not start the core")
            for command in ["native_core_start", "native_core_stop", "native_core_start", "native_core_restart", "native_core_stop"] {
                _ = try await store.request(command, serialWorkspace: true)
                store.refresh()
                let state = command == "native_core_stop" ? "stopped" : "running"
                for _ in 0..<200 {
                    if store.snapshot?.core.lifecycle?.state == state { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                precondition(store.snapshot?.core.lifecycle?.state == state)
            }
            let closed = await store.shutdownForTermination()
            precondition(closed)
            print("PASS: unavailable service, visible installation failure, explicit retry without auto-start, start-stop-start-restart-stop and safe shutdown")
            return
        }
        if protectionCheck {
            let initial = try await store.request("native_get_core_control").decoded(NativeProtectionControl.self)
            precondition(initial.protectionSupported == !oldProtectionService)
            if !oldProtectionService {
                precondition(initial.enabled == false && initial.identity != nil)
                for enabled in [true, false] {
                    let current = try await store.request("native_get_core_control").decoded(NativeProtectionControl.self)
                    let task = Task { try await store.request("native_set_session_protection", params: [
                        "confirmed": .bool(true), "enabled": .bool(enabled), "expected": current.identity!
                    ], timeout: .milliseconds(10)) }
                    try await Task.sleep(for: .milliseconds(100))
                    precondition(store.workspaceBusy && store.sessionProtectionInProgress)
                    let safe = await store.shutdownForTermination()
                    precondition(!safe)
                    let value = try await task.value.decoded(NativeProtectionControl.self)
                    precondition(value.enabled == (protectionRollback ? false : enabled) && value.pid != current.pid)
                    precondition(!store.workspaceBusy && !store.sessionProtectionInProgress)
                }
                for enabled in [true, false] {
                    let current = try await store.request("native_get_core_control").decoded(NativeProtectionControl.self)
                    let task = Task { try await store.request("native_set_runtime_protection", params: [
                        "confirmed": .bool(true), "processEnabled": .bool(enabled), "transportEnabled": .bool(enabled), "expected": current.identity!
                    ], timeout: .milliseconds(10)) }
                    try await Task.sleep(for: .milliseconds(100))
                    precondition(store.workspaceBusy && store.sessionProtectionInProgress)
                    let safe = await store.shutdownForTermination()
                    precondition(!safe)
                    let value = try await task.value.decoded(NativeProtectionControl.self)
                    precondition(value.enabled == (protectionRollback ? false : enabled)
                        && value.transportEnabled == (protectionRollback ? false : enabled) && value.pid != current.pid)
                    precondition(value.transportReport?.eligible == 1 && value.transportReport?.unsupported == 1)
                    precondition(!store.workspaceBusy && !store.sessionProtectionInProgress)
                }
            }
            let safe = await store.shutdownForTermination()
            precondition(safe)
            print("PASS: isolated session protection state, confirmed switches, restart feedback gate, no short request timeout, quit exclusion, rollback/old-service capability variants")
            return
        }
        if managedServiceIdle {
            await settle(host)
            precondition(store.snapshot?.core.lifecycle == nil && store.snapshot?.core.state == "unavailable")
            precondition(store.supports("native_install_service") && store.requiresManagedShutdown && !store.isReadOnlyConnection)
            let observed = try await store.request("native_inspect_core").decoded(NativeCoreInspection.self)
            precondition(observed.canStart && observed.corePid == nil && observed.processes.isEmpty)
            let result = try await store.installService(params: ["confirmed": .bool(true), "expected": .null])
            guard case .object(let fields) = result else { fatalError() }
            precondition(fields["installed"] == .bool(true) && fields["reconnectRequired"] == .bool(false))
            let closed = await store.shutdownForTermination()
            precondition(closed)
            print("PASS: idle managed service reinstallation without a lifecycle snapshot uses explicit nil identity, retains its managed session and closes safely")
            return
        }
        for width in [1040.0, 800.0] {
            window.setContentSize(NSSize(width: width, height: width == 1040 ? 700 : 560))
            for scheme in [TezAppearance.light, .dark] {
                preferences.appearance = scheme
                host.rootView = LiveWorkspaceView(store: store, selection: Binding(get: { selection.section }, set: { selection.section = $0 }))
                    .environment(preferences).preferredColorScheme(scheme.colorScheme)
                for protocolVisible in [true, false] {
                    preferences.showProtocol = protocolVisible
                    await settle(host)
                    guard let table = tables(host).first(where: { $0.headerView != nil && $0.numberOfRows == 24 }) else {
                        fatalError("FAIL: Routes must use a shared native table header and row grid")
                    }
                    let expected = protocolVisible && table.frame.width >= 630 ? 5 : 4
                    precondition(table.numberOfColumns == expected, "Unexpected route columns")
                    for column in 0..<table.numberOfColumns {
                        let header = table.headerView!.headerRect(ofColumn: column)
                        let cell = table.frameOfCell(atColumn: column, row: 0)
                        precondition((0...16).contains(cell.minX - header.minX) && (0...16).contains(header.maxX - cell.maxX),
                                     "Route header and cell geometry diverged: column \(column), header \(header), cell \(cell)")
                    }
                    precondition(table.frame.width <= host.bounds.width, "Route table overflowed")
                    let unselectedHeight = table.enclosingScrollView!.frame.height
                    if width == 800 {
                        let viewport = table.visibleRect
                        let fullRows = (0..<table.numberOfRows).filter {
                            let row = table.rect(ofRow: $0)
                            return row.minY >= viewport.minY - 0.5 && row.maxY <= viewport.maxY + 0.5
                        }.count
                        precondition(fullRows >= 5, "Compact routes must show five complete rows: \(fullRows), viewport \(viewport)")
                    }
                    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                    await settle(host)
                    precondition(abs(table.enclosingScrollView!.frame.height - unselectedHeight) < 1,
                                 "Selecting a route must not resize its list")
                    precondition(store.snapshot?.revision == "1", "Inspecting a route must not activate it")
                    table.deselectAll(nil)
                }
            }
        }
        window.setContentSize(NSSize(width: 1320, height: 780))
        await settle(host)
        guard let wideRoutes = tables(host).first(where: { $0.numberOfRows == 24 }) else { fatalError("Wide routes missing") }
        let wideListHeight = wideRoutes.enclosingScrollView!.frame.height
        wideRoutes.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await settle(host)
        guard let inspectedRoutes = tables(host).first(where: { $0.numberOfRows == 24 }) else { fatalError("Inspected routes missing") }
        precondition(inspectedRoutes.frame.width < 1000, "Wide route inspector must sit beside its table")
        precondition(abs(inspectedRoutes.enclosingScrollView!.frame.height - wideListHeight) < 1,
                     "A side inspector must not reduce table height")
        precondition(store.snapshot?.revision == "1", "A side inspector must not switch routes")
        window.setContentSize(NSSize(width: 1040, height: 700))
        selection.section = .activity
        await settle(host)
        for _ in 0..<10 {
            if tables(host).contains(where: { $0.headerView != nil && [3, 6].contains($0.numberOfColumns) && $0.numberOfRows == 24 }) { break }
            await settle(host)
        }
        guard let activityTable = tables(host).first(where: { $0.headerView != nil && [3, 6].contains($0.numberOfColumns) && $0.numberOfRows == 24 }),
              let scroll = activityTable.enclosingScrollView else { fatalError("Activity fixture did not render") }
        precondition(scroll.frame.height >= 400, "Empty activity details still consume list height: \(scroll.frame.height)")
        window.setContentSize(NSSize(width: 800, height: 560))
        await settle(host)
        precondition(activityTable.numberOfColumns == 3, "Compact activity must group related information instead of squeezing six columns")
        precondition(activityTable.tableColumns[0].width >= 190 && activityTable.tableColumns[1].width >= 175,
                     "Compact activity must leave readable target and outbound columns")
        let visibleWidth = scroll.contentView.bounds.width - scroll.contentInsets.left - scroll.contentInsets.right
        precondition(activityTable.frame.width <= visibleWidth + 1,
                     "Compact activity columns overflow: \(activityTable.frame.width), viewport \(visibleWidth), columns \(activityTable.tableColumns.map(\.width))")
        let horizontalPosition = activityTable.visibleRect.minX
        for row in [1, 9, 23] {
            activityTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            await settle(host)
            let selectedFrame = activityTable.rect(ofRow: row)
            let visible = activityTable.visibleRect
            precondition(selectedFrame.minY >= visible.minY - 1 && selectedFrame.maxY <= visible.maxY + 1,
                         "Activity inspector hid selected row \(row): \(selectedFrame), viewport \(visible)")
            precondition(scroll.frame.height >= 100, "Activity inspector must leave a usable table")
            let firstCell = activityTable.frameOfCell(atColumn: 0, row: row)
            let lastCell = activityTable.frameOfCell(atColumn: activityTable.numberOfColumns - 1, row: row)
            precondition(firstCell.minX >= activityTable.visibleRect.minX - 1 && lastCell.maxX <= activityTable.visibleRect.maxX + 1,
                         "Compact connection columns must stay visible: \(firstCell), \(lastCell), viewport \(activityTable.visibleRect)")
            precondition(abs(activityTable.visibleRect.minX - horizontalPosition) < 1,
                         "Vertical selection scrolling changed the horizontal position: \(horizontalPosition) to \(activityTable.visibleRect.minX)")
        }
        print("PASS: compact activity inspector keeps second, middle and last selected rows visible")
        window.setContentSize(NSSize(width: 1320, height: 780))
        await settle(host)
        guard let wideActivity = tables(host).first(where: { [3, 6].contains($0.numberOfColumns) && $0.numberOfRows == 24 }) else { fatalError("Wide activity missing") }
        precondition(wideActivity.selectedRow == 23 && wideActivity.frame.width < 1000,
                     "Changing inspector placement must preserve the selected connection")
        precondition(wideActivity.enclosingScrollView!.frame.height > 400, "Side details must preserve vertical table space")
        selection.section = .routes
        await settle(host)
        selection.section = .activity
        await settle(host)
        precondition(tables(host).first(where: { $0.numberOfRows == 24 })?.selectedRow == 23,
                     "Navigating away from activity must preserve the selected connection")
        tables(host).first(where: { $0.numberOfRows == 24 })?.deselectAll(nil)
        await settle(host)
        precondition(tables(host).first(where: { $0.numberOfRows == 24 })?.numberOfColumns == 6,
                     "Wide activity without an inspector must retain its detailed six-column table")
        let activitySession = NativeActivitySession()
        activitySession.paused = true
        let activityHost = NSHostingView(rootView: NativeActivityWorkspace(store: store, session: activitySession)
            .environment(preferences))
        window.contentView = activityHost
        for width in [800.0, 1040.0] {
            window.setContentSize(NSSize(width: width, height: width == 800 ? 560 : 700))
            activitySession.tab = .connections
            await settle(activityHost)
            guard let connections = tables(activityHost).first(where: { $0.numberOfRows == 24 }),
                  let connectionScroll = connections.enclosingScrollView else { fatalError("Connections missing") }
            let connectionHeight = connectionScroll.frame.height
            for (tab, count) in [(ActivityTab.rules, 12), (.providers, 3)] {
                activitySession.tab = tab
                await settle(activityHost)
                guard let table = tables(activityHost).first(where: { $0.numberOfRows == count }),
                      let scroll = table.enclosingScrollView else { fatalError("Activity subpage missing: \(tab)") }
                precondition(scroll.frame.height >= connectionHeight + 64,
                             "Rules and providers must reclaim the connection summary height: \(scroll.frame.height), connections \(connectionHeight)")
            }
            activitySession.tab = .connections
            await settle(activityHost)
            let restoredHeight = tables(activityHost).first(where: { $0.numberOfRows == 24 })?.enclosingScrollView?.frame.height
            precondition(restoredHeight.map { abs($0 - connectionHeight) < 1 } == true,
                         "Returning to connections must restore its summary without changing the table layout")
        }
        print("PASS: rules and providers reclaim summary space at compact and standard widths; connections retain their summary")
        for count in [1, 6] {
            let measurement = LayoutMeasurement()
            let changes = (0..<count).map {
                NativePendingChange(id: String($0), scope: .proxy, title: "Example change \($0)",
                                    previousValue: "Off", proposedValue: "On", affectsTraffic: true)
            }
            let pendingHost = NSHostingView(rootView: VStack(spacing: 0) {
                NativePendingChangesList(changes: changes)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measurement.height = $0 }
                Spacer(minLength: 0)
            }.frame(width: 640))
            window.contentView = pendingHost
            window.setContentSize(NSSize(width: 640, height: 300))
            await settle(pendingHost)
            precondition(measurement.height >= 32 && measurement.height <= 160,
                         "Pending list must remain visible and capped: \(measurement.height)")
            if count == 1 {
                precondition(measurement.height <= 60, "A single pending change must fit its content: \(measurement.height)")
            } else {
                precondition(measurement.height >= 120, "Long pending lists must use the available height: \(measurement.height)")
            }
        }
        print("PASS: pending changes fit one row and scroll at the height cap")
        window.contentView = host
        selection.section = .connection
        for width in [1040.0, 800.0] {
            window.setContentSize(NSSize(width: width, height: width == 1040 ? 700 : 560))
            for scheme in [TezAppearance.light, .dark] {
                preferences.appearance = scheme
                host.rootView = LiveWorkspaceView(store: store, selection: Binding(get: { selection.section }, set: { selection.section = $0 }))
                    .environment(preferences).preferredColorScheme(scheme.colorScheme)
                await settle(host)
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Connection view did not render") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError() }
                try png.write(to: URL(fileURLWithPath: "output.noindex/lifecycle-\(Int(width))-\(scheme.rawValue).png"))
            }
        }
        precondition(store.snapshot?.core.lifecycle == inspection && store.isReadOnlyConnection)
        precondition(!store.supports("native_core_start") && !store.supports("native_prepare_shutdown"))
        for scheme in [TezAppearance.light, .dark] {
            let upgradeHost = NSHostingView(rootView: NativeCoreUpgradeView(store: store).preferredColorScheme(scheme.colorScheme))
            window.setContentSize(NSSize(width: 540, height: 380))
            window.contentView = upgradeHost
            await settle(upgradeHost)
            guard let bitmap = upgradeHost.bitmapImageRepForCachingDisplay(in: upgradeHost.bounds) else { fatalError("Upgrade view did not render") }
            upgradeHost.cacheDisplay(in: upgradeHost.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError() }
            try png.write(to: URL(fileURLWithPath: "output.noindex/core-upgrade-\(scheme.rawValue).png"))
        }
        print("PASS: route headers and stable selection layout at 1040/800 widths, light/dark and protocol on/off; selection never activates a route; offline status never claims a running core; reduced motion disables authored animations; activity/lifecycle/upgrade fixtures render without core control")
    }

    @MainActor static func settle(_ host: NSView) async {
        try? await Task.sleep(for: .milliseconds(650))
        host.layoutSubtreeIfNeeded()
    }

    static func checkLatencySort() throws {
        let value = try NativeSnapshot.decode(Self.snapshot())
        guard let view = value.proxyView, let group = view.global else { fatalError("Missing routes fixture") }
        var rows = group.members.enumerated().map {
            LiveRouteMember(member: $0.element, index: $0.offset, view: view, isCurrent: $0.element.name == group.now)
        }
        let missing = rows.filter { $0.sortDelay == nil }.map(\.id)
        let ascending = rows.sorted(using: LiveRouteLatencyComparator())
        let descending = rows.sorted(using: LiveRouteLatencyComparator(order: .reverse))
        precondition(ascending.first?.sortDelay == 49 && descending.first?.sortDelay == 203)
        for sorted in [ascending, descending] {
            precondition(sorted.suffix(missing.count).map(\.id) == missing, "Failed and unmeasured routes must remain last in both directions")
            precondition(Set(sorted.map(\.id)) == Set(rows.map(\.id)), "Sorting must preserve route identities")
        }
        rows[5].measuredLatency = NativeLatencyPayload.Result(name: rows[5].name, delay: 1, error: nil)
        precondition(rows.sorted(using: LiveRouteLatencyComparator()).first?.id == rows[5].id, "Sorting must use fresh latency results")
        rows[5].measuredLatency = NativeLatencyPayload.Result(name: rows[5].name, delay: nil, error: "timeout")
        precondition(rows[5].sortDelay == nil, "A failed measurement must replace historical latency")
        print("PASS: latency sorting in both directions, missing values last, stable identities and latest results")
    }

    @MainActor static func profileSearchCheck(_ host: NSView) async throws {
        await settle(host)
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        guard let field = fields(host).first(where: { $0.placeholderString == "搜索配置" }),
              let table = tables(host).first(where: { $0.headerView == nil && $0.numberOfRows > 4 }) else {
            fatalError("Profile search controls did not render")
        }
        let originalCount = table.numberOfRows
        let originalHeights = (0..<originalCount).map { table.rect(ofRow: $0).height }
        func resultTable() -> NSTableView? {
            let x = field.convert(field.bounds, to: nil).midX
            return tables(host).first { table in
                guard table.headerView == nil, let scroll = table.enclosingScrollView else { return false }
                let frame = scroll.convert(scroll.bounds, to: nil)
                return frame.minX < x && x < frame.maxX
            }
        }
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        await settle(host)
        for (index, query) in ["Research", "Research", "Rules", "no-matching-profile", "Daily", "Research"].enumerated() {
            print("[profile-search] round \(index + 1): filter \(query)")
            field.stringValue = query
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            await settle(host)
            guard let filteredTable = resultTable() else { fatalError("Filtered list missing") }
            precondition(filteredTable.numberOfRows < originalCount, "Profile query did not reach the real list")
            field.stringValue = ""
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            print("[profile-search] round \(index + 1): clear")
            await settle(host)
            guard let restoredTable = resultTable() else { fatalError("Restored list missing") }
            precondition(field.stringValue.isEmpty && restoredTable.numberOfRows == originalCount, "Profile clear did not restore the real list")
            let restoredHeights = (0..<restoredTable.numberOfRows).map { restoredTable.rect(ofRow: $0).height }
            precondition(restoredHeights == originalHeights, "Profile clear changed row geometry")
            if query == "Research" {
                precondition(restoredTable.selectedRow == 2, "Clearing search must keep Research selected, not return to the current Daily profile")
            }
        }
        print("PASS: profile search and clear use the real native list")
    }

    @MainActor static func tables(_ view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables($0) }
    }

    @MainActor static func checkTaskModels() throws {
        let snapshot = try NativeSnapshot.decode(snapshot())
        let summary = NativeAccessSummary(snapshot: snapshot, connected: true)
        precondition(summary.accessTitle == "系统代理与 TUN 已开启" && summary.routeTitle == "Tokyo 01")
        precondition(NativeAccessSummary(snapshot: snapshot, connected: false).routeTitle == "连接后台后读取")
        let direct = try NativeSnapshot.decode(Self.snapshot(mode: "direct", systemProxy: false, tun: false))
        precondition(NativeAccessSummary(snapshot: direct, connected: true).routeTitle == "直连，不经过代理节点")
        precondition(NativeAccessSummary(snapshot: direct, connected: true).accessTitle == "未开启流量接入")
        let route = NativeRecentRoute(profileID: "profile-1", group: "GLOBAL", name: "Tokyo 01")
        precondition(route.isAvailable(in: snapshot) && route.isCurrent(in: snapshot))
        precondition(!NativeRecentRoute(profileID: "profile-2", group: "GLOBAL", name: "Tokyo 01").isAvailable(in: snapshot))
        precondition(!NativeRecentRoute(profileID: "profile-1", group: "GLOBAL", name: "Missing").isAvailable(in: snapshot))
        guard let view = snapshot.proxyView, let global = view.global, let policy = view.groups.first else { fatalError() }
        precondition(NativeRoutePresentation.groups(in: view, mode: "rule").map(\.name) == ["Daily Policy", "GLOBAL"])
        precondition(NativeRoutePresentation.groups(in: view, mode: "global").first?.name == "GLOBAL")
        precondition(NativeRoutePresentation.groups(in: view, mode: "direct").first?.name == "Daily Policy")
        precondition(NativeRoutePresentation.title("GLOBAL") == "全局代理" && global.name == "GLOBAL")
        var change = NativeRouteSwitchChange(group: "GLOBAL", target: "Tokyo 01")
        precondition(!change.isConfirmed(by: global), "A matching snapshot must not confirm an unfinished request")
        change.outcome = .applied
        precondition(change.isConfirmed(by: global) && !change.isConfirmed(by: policy))
        change.outcome = .notApplied
        precondition(!change.isConfirmed(by: global))
        let samplerState = NativeRouteSamplerState()
        let held = NativeRouteSamplerState.Reading(samples: [], testing: false, origin: "snapshot")
        let latest = NativeRouteSamplerState.Reading(samples: [.init(date: .now, delay: 42)], testing: false, origin: "session")
        samplerState.held = held
        samplerState.accept(latest)
        precondition(samplerState.held == held, "New data must not replace a held reading")
        samplerState.captureNext = true
        samplerState.accept(latest)
        precondition(samplerState.held == latest && !samplerState.captureNext)
        samplerState.reset()
        precondition(samplerState.held == nil && !samplerState.captureNext)
        var selection = NativeRouteComparisonSelection()
        for id in ["a", "a", "b", "c", "d"] { selection.add(id) }
        precondition(selection.ids == ["a", "b", "c"] && selection.isFull)
        selection.remove("b"); selection.add("d"); selection.retain(["a", "d"])
        precondition(selection.ids == ["a", "d"])
        selection.clear(); precondition(selection.ids.isEmpty)
        let historical = NativeRouteMeasurement(sessionDate: nil, snapshotTime: "2026-10-29T10:00:00Z")
        precondition(historical.origin == .snapshot && historical.date != nil)
        let fractional = NativeRouteMeasurement(sessionDate: nil, snapshotTime: "2026-10-29T18:00:00.125+08:00")
        precondition(fractional.date?.timeIntervalSince(historical.date!) == 0.125)
        let invalid = NativeRouteMeasurement(sessionDate: nil, snapshotTime: "unavailable")
        precondition(invalid.date == nil && invalid.rawTime == "unavailable")
        let date = Date(timeIntervalSince1970: 100)
        let fresh = NativeRouteMeasurement(sessionDate: date, snapshotTime: "2026-10-29T10:00:00Z")
        precondition(fresh.origin == .session && fresh.date == date)
        let failed = NativeRouteMeasurement(sessionDate: nil, snapshotTime: "2026-10-29T10:00:00Z", hasSessionResult: true)
        precondition(failed.origin == .session && failed.date == nil)
    }

    @MainActor private static func showUI(app: NSApplication, window: NSWindow, preferences: TezPreviewPreferences, store: NativeBackendStore, selection: LayoutSelection, suite: String) {
        let target = LayoutMenuTarget(window: window, preferences: preferences, store: store, selection: selection, suite: suite)
        uiTarget = target
        app.delegate = target
        let menu = NSMenu()
        let item = NSMenuItem(); let appMenu = NSMenu()
        for (title, selector, key) in [("Compact Window", #selector(LayoutMenuTarget.compact), "1"),
                                       ("Standard Window", #selector(LayoutMenuTarget.standard), "2"),
                                       ("Wide Window", #selector(LayoutMenuTarget.wide), "3"),
                                       ("Open Menu Panel", #selector(LayoutMenuTarget.openMenuPanel), "b"),
                                       ("Disconnect Fixture", #selector(LayoutMenuTarget.disconnectFixture), "0"),
                                       ("Toggle Dark Mode", #selector(LayoutMenuTarget.toggleDark), "d"),
                                       ("Toggle Protocol", #selector(LayoutMenuTarget.toggleProtocol), "p"),
                                       ("Toggle Reduced Motion", #selector(LayoutMenuTarget.toggleMotion), "m"),
                                       ("Toggle Reduced Transparency", #selector(LayoutMenuTarget.toggleTransparency), "t")] {
            let action = appMenu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            action.target = target
        }
        appMenu.addItem(withTitle: "Quit Layout Check", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); app.mainMenu = menu
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class LayoutMenuTarget: NSObject, NSApplicationDelegate {
    let window: NSWindow
    let preferences: TezPreviewPreferences
    let store: NativeBackendStore
    let selection: LayoutSelection
    let suite: String
    private var panel: NSWindow?
    init(window: NSWindow, preferences: TezPreviewPreferences, store: NativeBackendStore, selection: LayoutSelection, suite: String) {
        self.window = window; self.preferences = preferences; self.store = store; self.selection = selection; self.suite = suite
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        store.disconnect()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    @objc func compact() { window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 800, height: 560)), display: true) }
    @objc func standard() { window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1040, height: 700)), display: true) }
    @objc func wide() { window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1320, height: 780)), display: true) }
    @objc func toggleDark() { window.appearance = NSAppearance(named: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua) }
    @objc func toggleProtocol() { preferences.showProtocol.toggle() }
    @objc func toggleMotion() { preferences.reduceMotion.toggle() }
    @objc func toggleTransparency() { preferences.reduceTransparency.toggle() }
    @objc func disconnectFixture() { store.disconnect() }
    @objc func openMenuPanel() {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: window.frame.maxX - 340, y: window.frame.midY - 270, width: 340, height: 540),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Tez 菜单面板 · 模拟数据"
        panel.contentView = NSHostingView(rootView: NativeMenuBarPanel(store: store,
            openWorkspace: { self.window.makeKeyAndOrderFront(nil) },
            openRoutes: { self.selection.section = .routes; self.window.makeKeyAndOrderFront(nil) },
            connect: { self.store.connect() }, quit: { NSApp.terminate(nil) }).environment(preferences))
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}
