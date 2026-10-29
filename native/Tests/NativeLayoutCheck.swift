import AppKit
import SwiftUI

@MainActor @Observable
private final class LayoutSelection {
    var section: WorkspaceSection? = .routes
}

@main
struct NativeLayoutCheck {
    @MainActor private static var uiTarget: LayoutMenuTarget?
    private static var routeControlsEnabled: Bool {
        CommandLine.arguments.contains("--route-controls") || Bundle.main.object(forInfoDictionaryKey: "TezLayoutFixtureUI") as? Bool == true
    }
    static let inspection = NativeCoreInspection(state: "runningReadOnly", source: "service", canStart: false,
        reason: "service-upgrade-required", corePid: 123, serviceGeneration: 42,
        serviceStartedAt: 1793180000,
        processes: [NativeCoreProcess(pid: 123, uid: 0,
            executable: "/Library/Application Support/fixture-service/cores/mihomo", startedAt: "Wed Oct 28 17:33:02 2026")],
        serviceProtocol: "2.5", serviceControlAvailable: false)
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

    static func snapshot(current: String? = nil, revision: String = "1") throws -> BackendJSON {
        let names = (1...24).map { $0 == 2 ? "Tokyo Residential - Long Route Name 02" : "Tokyo \(String(format: "%02d", $0))" }
        let records = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            let id = "node-\(index)"
            let history = index % 6 == 0 ? [] : [NativeDelayHistory(time: "2026-10-29T10:00:00Z", delay: index == 4 ? 0 : UInt64(42 + index * 7))]
            return (id, NativeProxyNode(recordId: id, name: name, type: "Shadowsocks", history: history,
                id: nil, hidden: false, icon: nil, testUrl: nil, udp: true, xudp: false, tfo: false,
                mptcp: false, smux: false, source: NativeProxySource(kind: "core", proxyName: name, providerName: nil)))
        })
        let group = NativeProxyGroup(name: "GLOBAL", type: "Selector", now: current ?? names[0], fixed: nil,
            hidden: false, icon: nil, testUrl: nil, history: [], udp: true, xudp: false, tfo: false,
            mptcp: false, smux: false, members: names.enumerated().map {
                NativeProxyMember(kind: "node", name: $0.element, recordId: "node-\($0.offset)", reason: nil)
            })
        return try json(NativeSnapshot(revision: revision, profiles: NativeProfilesSnapshot(state: "ready",
            current: "profile-1", items: profiles, message: nil),
            proxyView: NativeProxyView(schemaVersion: 1, orderSource: "core", providerState: "ready",
                global: group, direct: nil, groups: [], records: records, standalone: [], providers: []),
            core: NativeCoreSnapshot(state: "ready", message: nil, source: "service", lifecycle: inspection),
            network: NativeNetworkSnapshot(systemProxy: NativeObservedSwitch(state: "ready", enabled: true),
                pac: NativeObservedSwitch(state: "ready", enabled: false), tun: NativeObservedSwitch(state: "ready", enabled: true),
                mode: NativeObservedMode(state: "ready", value: "global"))))
    }

    static func fixture() throws {
        func emit(_ message: BackendMessage) throws {
            try FileHandle.standardOutput.write(contentsOf: BackendWire.encode(message))
        }
        let routeControls = routeControlsEnabled
        var current: String?
        var revision = 1
        var activityReads = 0
        var closedConnections: Set<String> = []
        let capabilities = ["native_continuous_session", "native_subscribe",
            "native_get_snapshot", "native_get_activity", "native_close_connection", "native_get_settings", "native_get_logs", "native_inspect_core", "native_subscription_details",
            "native_claim_core", "native_get_core_control", "native_prepare_core_upgrade", "native_upgrade_core", "native_install_service"]
            + (routeControls ? ["native_select_route", "native_test_latency"] : [])
        try emit(.hello(sessionID: "layout-fixture", capabilities: capabilities))
        while let line = readLine() {
            guard case .request(let id, let command, let params) = try BackendWire.decode(Data(line.utf8)) else { fatalError() }
            let result: BackendJSON
            switch command {
            case "native_close_connection":
                guard case .string(let id) = params["id"], id.hasPrefix("connection-") else { fatalError() }
                closedConnections.insert(id)
                result = .object(["closed": .bool(true), "id": .string(id)])
            case "native_subscribe", "native_get_snapshot": result = try snapshot(current: current, revision: String(revision))
            case "native_select_route" where routeControls:
                guard case .string(let name) = params["name"] else { fatalError() }
                Thread.sleep(forTimeInterval: 0.5)
                current = name
                revision += 1
                result = .object(["applied": .bool(true), "persisted": .bool(true)])
            case "native_test_latency" where routeControls:
                guard case .array(let names) = params["names"] else { fatalError() }
                Thread.sleep(forTimeInterval: 0.45)
                result = .object(["results": .array(names.enumerated().map { index, name in
                    .object(["name": name, "delay": .integer(Int64(38 + index * 17)), "error": .null])
                })])
            case "native_inspect_core": result = try json(inspection)
            case "native_get_core_control": result = .object(["generation": .integer(42), "pid": .integer(123), "started_at": .integer(1793180000)])
            case "native_claim_core": result = .object(["claimed": .bool(true), "reconnectRequired": .bool(true)])
            case "native_prepare_core_upgrade": result = .object(["path": .string("/fixture/tez-" + String(repeating: "a", count: 64)), "sha256": .string(String(repeating: "a", count: 64)), "version": .string("fixture-1")])
            case "native_upgrade_core": result = .object(["outcome": .string("rolled_back"), "pid": .integer(124), "versionSelectionSaved": .bool(true)])
            case "native_get_settings": result = .object(["values": .object([:]), "mode": .string("rule")])
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
                    "process": .string(index % 2 == 0 ? "Terminal" : "Browser"), "rule": .string("MATCH"), "chains": .array([.string("Daily Policy"), .string("Tokyo Residential - Long Route Name 02")]),
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
        let offline = TezConnectionPresentation(state: .failed, hasSnapshot: true, coreState: "ready", writable: true)
        precondition(offline.coreTitle == "内核状态未确认" && offline.context.contains("离线快照"))
        let connected = TezConnectionPresentation(state: .connected, hasSnapshot: true, coreState: "ready", writable: false)
        precondition(connected.coreTitle == "内核运行中" && connected.context == "只读访问")
        precondition(TezMotion(reduced: true).feedback == nil && TezMotion(reduced: true).layout == nil)
        let suite = "tez.layout-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = TezPreviewPreferences(defaults: defaults)
        let selection = LayoutSelection()
        if Bundle.main.object(forInfoDictionaryKey: "TezProfilesFixtureUI") as? Bool == true { selection.section = .profiles }
        if CommandLine.arguments.contains("--profile-search-check") { selection.section = .profiles }
        let store = NativeBackendStore(helperURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            arguments: ["--fixture"] + (routeControlsEnabled ? ["--route-controls"] : []), mode: .attach)
        store.connect()
        for _ in 0..<200 {
            if store.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard store.state == .connected else { fatalError("Layout fixture did not connect") }
        let root = LiveWorkspaceView(store: store, selection: Binding(get: { selection.section }, set: { selection.section = $0 }))
            .environment(preferences).preferredColorScheme(preferences.appearance.colorScheme)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1040, height: 700),
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
            showUI(app: app, window: window, preferences: preferences, store: store, suite: suite)
            return
        }
        defer { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
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
                    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                    await settle(host)
                    precondition(abs(table.enclosingScrollView!.frame.height - unselectedHeight) < 1,
                                 "Selecting a route must not resize its list")
                    precondition(store.snapshot?.revision == "1", "Inspecting a route must not activate it")
                    table.deselectAll(nil)
                }
            }
        }
        window.setContentSize(NSSize(width: 1040, height: 700))
        selection.section = .activity
        await settle(host)
        for _ in 0..<10 {
            if tables(host).contains(where: { $0.headerView != nil && $0.numberOfColumns == 6 && $0.numberOfRows == 24 }) { break }
            await settle(host)
        }
        guard let activityTable = tables(host).first(where: { $0.headerView != nil && $0.numberOfColumns == 6 && $0.numberOfRows == 24 }),
              let scroll = activityTable.enclosingScrollView else { fatalError("Activity fixture did not render") }
        precondition(scroll.frame.height >= 400, "Empty activity details still consume list height: \(scroll.frame.height)")
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
        }
        print("PASS: profile search and clear use the real native list")
    }

    @MainActor static func tables(_ view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables($0) }
    }

    @MainActor static func showUI(app: NSApplication, window: NSWindow, preferences: TezPreviewPreferences, store: NativeBackendStore, suite: String) {
        let target = LayoutMenuTarget(window: window, preferences: preferences, store: store, suite: suite)
        uiTarget = target
        app.delegate = target
        let menu = NSMenu()
        let item = NSMenuItem(); let appMenu = NSMenu()
        for (title, selector, key) in [("Compact Window", #selector(LayoutMenuTarget.compact), "1"),
                                       ("Standard Window", #selector(LayoutMenuTarget.standard), "2"),
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
    let suite: String
    init(window: NSWindow, preferences: TezPreviewPreferences, store: NativeBackendStore, suite: String) {
        self.window = window; self.preferences = preferences; self.store = store; self.suite = suite
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        store.disconnect()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    @objc func compact() { window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 800, height: 560)), display: true) }
    @objc func standard() { window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1040, height: 700)), display: true) }
    @objc func toggleDark() { window.appearance = NSAppearance(named: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua) }
    @objc func toggleProtocol() { preferences.showProtocol.toggle() }
    @objc func toggleMotion() { preferences.reduceMotion.toggle() }
    @objc func toggleTransparency() { preferences.reduceTransparency.toggle() }
}
