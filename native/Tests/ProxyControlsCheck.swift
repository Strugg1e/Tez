import AppKit
import SwiftUI

@main
struct ProxyControlsCheck {
    @MainActor private static var uiDelegate: ProxyCheckDelegate?
    static func json<T: Encodable>(_ value: T) throws -> BackendJSON { try JSONDecoder().decode(BackendJSON.self, from: JSONEncoder().encode(value)) }
    static func fixture() throws {
        func emit(_ message: BackendMessage) throws { try FileHandle.standardOutput.write(contentsOf: BackendWire.encode(message)) }
        var revision = 1
        var mode = "rule"
        var pacEnabled = CommandLine.arguments.contains("--pac-enabled")
        var values: [String: BackendJSON] = ["enable_system_proxy": .bool(false), "enable_tun_mode": .bool(false), "use_default_bypass": .bool(true), "enable_bypass_check": .bool(true)]
        var config: [String: BackendJSON] = ["tun": .object(["stack": .string("system"), "device": .string("utun1024"), "mtu": .integer(1500), "auto-route": .bool(true), "auto-detect-interface": .bool(true), "strict-route": .bool(false), "dns-mode": .string(""), "dns-hijack": .array([.string("any:53")]), "route-exclude-address": .array([])]), "ipv6": .bool(false)]
        var chains: [NativeProxyChain] = []
        var active: String?
        let names = ["Fixture Entry", "Fixture Exit", "Fixture Spare"]
        let capabilities = ["native_continuous_session", "native_get_snapshot", "native_subscribe", "native_get_settings", "native_patch_settings", "native_set_mode", "native_get_proxy_config", "native_patch_proxy_config", "native_get_proxy_chains", "native_save_proxy_chain", "native_delete_proxy_chain", "native_activate_proxy_chain", "native_deactivate_proxy_chain"]
        try emit(.hello(sessionID: "proxy-controls-fixture", capabilities: capabilities))
        while let line = readLine() {
            guard case .request(let id, let command, let params) = try BackendWire.decode(Data(line.utf8)) else { fatalError() }
            let result: BackendJSON
            switch command {
            case "native_get_snapshot", "native_subscribe":
                result = try json(NativeSnapshot(revision: String(revision), profiles: NativeProfilesSnapshot(state: "ready", current: nil, items: [], message: nil), proxyView: nil,
                    core: NativeCoreSnapshot(state: "ready", message: nil, source: "sidecar"),
                    network: NativeNetworkSnapshot(systemProxy: NativeObservedSwitch(state: "ready", enabled: values["enable_system_proxy"] == .bool(true)), pac: NativeObservedSwitch(state: "ready", enabled: pacEnabled), tun: NativeObservedSwitch(state: "ready", enabled: values["enable_tun_mode"] == .bool(true)), mode: NativeObservedMode(state: "ready", value: mode))))
            case "native_get_settings": result = .object(["values": .object(values), "mode": .string(mode)])
            case "native_patch_settings":
                guard case .object(let changes) = params["values"] else { fatalError() }; values.merge(changes) { _, value in value }; revision += 1
                if changes["enable_system_proxy"] == .bool(false) { pacEnabled = false }
                result = .object(["saved": .bool(true)])
            case "native_set_mode":
                guard case .string(let next) = params["mode"], ["rule", "global", "direct"].contains(next) else { fatalError() }; mode = next; revision += 1
                result = .object(["applied": .bool(true)])
            case "native_get_proxy_config": result = .object(["values": .object(config)])
            case "native_patch_proxy_config":
                guard case .object(let changes) = params["values"] else { fatalError() }; config.merge(changes) { _, value in value }
                result = .object(["saved": .bool(true), "applied": .bool(true)])
            case "native_get_proxy_chains":
                result = .object(["chains": try json(chains), "activeId": active.map(BackendJSON.string) ?? .null, "applied": .bool(active != nil), "available": .array(names.map(BackendJSON.string)), "groups": .array([.string("Fixture"), .string("GLOBAL")])])
            case "native_save_proxy_chain":
                guard let value = params["chain"] else { fatalError() }; let chain = try value.decoded(NativeProxyChain.self)
                chains.removeAll { $0.id == chain.id }; chains.append(chain); result = .object(["saved": .bool(true)])
            case "native_delete_proxy_chain":
                guard case .string(let id) = params["id"] else { fatalError() }; chains.removeAll { $0.id == id }; result = .object(["saved": .bool(true)])
            case "native_activate_proxy_chain":
                guard case .string(let id) = params["id"], chains.contains(where: { $0.id == id }) else { fatalError() }; active = id
                result = .object(["applied": .bool(true), "persisted": .bool(true)])
            case "native_deactivate_proxy_chain": active = nil; result = .object(["applied": .bool(true), "persisted": .bool(true), "selectionRestored": .bool(true)])
            default: fatalError("Isolated UI fixture rejected unexpected command \(command)")
            }
            try emit(.response(id: id, outcome: .result(result)))
        }
    }
    @MainActor static func connect(pacEnabled: Bool = false) async throws -> NativeBackendStore {
        let store = NativeBackendStore(helperURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL, arguments: ["--fixture"] + (pacEnabled ? ["--pac-enabled"] : []), mode: .attach)
        store.connect()
        for _ in 0..<500 { if store.state == .connected { return store }; try await Task.sleep(for: .milliseconds(10)) }
        throw BackendWireError.invalid("Fixture failed to connect")
    }
    @MainActor static func checks() async throws {
        try systemProxyChecks()
        precondition(NativeProxyInput.entries("192.168.1.0/24\nfd00::/8\n").count == 2)
        precondition(NativeProxyInput.validCIDR("192.168.1.0/24") && NativeProxyInput.validCIDR("fd00::/8"))
        precondition(!NativeProxyInput.validCIDR("192.168.1.0/33") && !NativeProxyInput.validCIDR("fd00::/129"))
        precondition(!NativeProxyInput.validCIDR("not-an-address/24") && !NativeProxyInput.validCIDR("192.168.1.0"))
        let store = try await connect()
        defer { store.disconnect() }
        precondition(!store.supports("native_core_restart") && !store.supports("native_test_latency"))
        _ = try await store.request("native_patch_settings", params: ["values": .object(["enable_system_proxy": .bool(true), "enable_tun_mode": .bool(true)])])
        _ = try await store.request("native_set_mode", params: ["mode": .string("global")])
        let snapshot = try NativeSnapshot.decode(await store.request("native_get_snapshot"))
        precondition(snapshot.network?.systemProxy.enabled == true && snapshot.network?.tun.enabled == true && snapshot.network?.mode.value == "global")
        _ = try await store.request("native_patch_proxy_config", params: ["values": .object(["tun": .object(["stack": .string("mixed"), "mtu": .integer(1400)])])])
        let proxy = try await store.request("native_get_proxy_config").decoded(NativeSettingsPayload.self)
        precondition(proxy.values["tun"] == .object(["stack": .string("mixed"), "mtu": .integer(1400)]))
        let chain = NativeProxyChain(name: "Fixture chain", group: "Fixture", nodes: ["Fixture Entry", "Fixture Exit"])
        _ = try await store.request("native_save_proxy_chain", params: ["chain": json(chain)])
        _ = try await store.request("native_activate_proxy_chain", params: ["id": .string(chain.id)])
        let activated = try await store.request("native_get_proxy_chains").decoded(NativeProxyChainPayload.self)
        precondition(activated.applied && activated.activeId == chain.id)
        _ = try await store.request("native_deactivate_proxy_chain")
        _ = try await store.request("native_delete_proxy_chain", params: ["id": .string(chain.id)])
        let deleted = try await store.request("native_get_proxy_chains").decoded(NativeProxyChainPayload.self)
        precondition(deleted.chains.isEmpty && !deleted.applied)
        try await pacCloseCheck()
        print("PASS: isolated native protocol controls, independent proxy switches, routing mode, TUN fields and chain CRUD/enable/disable; no core or latency capability")
    }
    private static func systemProxyChecks() throws {
        let on = NativeObservedSwitch(state: "ready", enabled: true)
        let off = NativeObservedSwitch(state: "ready", enabled: false)
        let unknown = NativeObservedSwitch(state: "unavailable", enabled: nil)
        let cases: [(String, NativeObservedSwitch, NativeObservedSwitch, NativeObservedSwitch)] = [
            ("ordinary proxy", on, off, on),
            ("PAC only", off, on, on),
            ("both on", on, on, on),
            ("both off", off, off, off),
            ("unknown", unknown, unknown, unknown),
            ("unknown PAC", off, unknown, unknown),
            ("unknown ordinary proxy", unknown, off, unknown),
            ("ordinary proxy with unknown PAC", on, unknown, on),
            ("PAC with unknown ordinary proxy", unknown, on, on),
            ("missing observed value", NativeObservedSwitch(state: "ready", enabled: nil), off, unknown),
        ]
        for (name, system, pac, expected) in cases {
            let network = NativeNetworkSnapshot(systemProxy: system, pac: pac, tun: off, mode: NativeObservedMode(state: "ready", value: "rule"))
            guard network.systemProxyControl == expected else {
                throw BackendWireError.invalid("System proxy control must reflect \(name): expected \(expected), got \(network.systemProxyControl)")
            }
        }
        print("PASS: system proxy control combines observed ordinary proxy and PAC without treating unknown as off")
    }
    @MainActor private static func pacCloseCheck() async throws {
        let store = try await connect(pacEnabled: true)
        defer { store.disconnect() }
        let before = try NativeSnapshot.decode(await store.request("native_get_snapshot"))
        guard before.network?.systemProxy.enabled == false, before.network?.pac.enabled == true,
              let enabled = before.network?.systemProxyControl.enabled else {
            throw BackendWireError.invalid("PAC-only fixture must expose an observed system proxy control")
        }
        let value = BackendJSON.bool(!enabled)
        guard value == .bool(false) else { throw BackendWireError.invalid("Closing PAC must send enable_system_proxy=false") }
        _ = try await store.request("native_patch_settings", params: ["values": .object(["enable_system_proxy": value])])
        let after = try NativeSnapshot.decode(await store.request("native_get_snapshot"))
        guard after.network?.systemProxy.enabled == false, after.network?.pac.enabled == false,
              after.network?.systemProxyControl.enabled == false else {
            throw BackendWireError.invalid("Closing the system proxy control must turn off PAC")
        }
        print("PASS: PAC-only system proxy control closes with enable_system_proxy=false")
    }
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--fixture") { try fixture(); return }
        let app = NSApplication.shared
        Task { @MainActor in
            do {
                if Bundle.main.object(forInfoDictionaryKey: "TezProxyFixtureUI") as? Bool == true { try await launchUI(app) }
                else { try await checks(); exit(0) }
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor private static func launchUI(_ app: NSApplication) async throws {
        app.setActivationPolicy(.regular)
        let store = try await connect()
        let suite = "tez.proxy-controls.\(UUID().uuidString)"
        let preferences = TezPreviewPreferences(defaults: UserDefaults(suiteName: suite)!)
        let root = LiveWorkspaceView(store: store).environment(preferences)
            .preferredColorScheme(CommandLine.arguments.contains("--dark") ? .dark : .light)
        let compact = CommandLine.arguments.contains("--compact")
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: compact ? 800 : 1040, height: compact ? 680 : 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Tez Proxy Controls Check · 隔离模拟"
        window.contentView = NSHostingView(rootView: root)
        let delegate = ProxyCheckDelegate(store: store, suite: suite)
        uiDelegate = delegate
        app.delegate = delegate
        let menu = NSMenu(); let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出隔离检查", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); app.mainMenu = menu
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    }
}
@MainActor private final class ProxyCheckDelegate: NSObject, NSApplicationDelegate {
    let store: NativeBackendStore; let suite: String
    init(store: NativeBackendStore, suite: String) { self.store = store; self.suite = suite }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store.disconnect(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}
