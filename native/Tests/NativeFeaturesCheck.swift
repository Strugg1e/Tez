import Foundation
import AppKit
import SwiftUI

@main
struct NativeFeaturesCheck {
    static let snapshot: BackendJSON = .object([
        "revision": .string("1"),
        "profiles": .object(["state": .string("ready"), "current": .null, "items": .array([]), "message": .null]),
        "proxyView": .null, "core": .object(["state": .string("unavailable"), "message": .null])
    ])

    static func emit(_ value: BackendMessage) throws { try FileHandle.standardOutput.write(contentsOf: BackendWire.encode(value)) }
    static func fixture() throws {
        try emit(.hello(sessionID: "features-fixture", capabilities: ["native_continuous_session", "native_subscribe", "native_get_snapshot", "native_get_settings", "native_patch_settings", "native_get_dns", "native_save_dns", "native_set_dns_override", "native_get_logs", "native_import_subscription", "native_create_local_profile", "native_subscription_details", "native_patch_subscription", "native_list_local_backups", "native_create_local_backup", "native_delete_local_backup", "native_import_local_backup", "native_export_local_backup", "native_restore_local_backup", "native_get_webdav_config", "native_save_webdav_config", "native_list_webdav_backups", "native_create_webdav_backup", "native_delete_webdav_backup", "native_restore_webdav_backup"]))
        var next = 1
        var backups: [String] = []
        var remoteBackups: [String] = []
        while let line = readLine() {
            guard case .request(let id, let command, let params) = try BackendWire.decode(Data(line.utf8)) else { fatalError() }
            precondition(id == "seq:\(next)"); next += 1
            switch command {
            case "native_subscribe", "native_get_snapshot": try emit(.response(id: id, outcome: .result(snapshot)))
            case "native_get_settings":
                Thread.sleep(forTimeInterval: 0.25)
                try emit(.response(id: id, outcome: .result(.object(["values": .object(["verge_mixed_port": .integer(7897)]), "mode": .string("rule")]))))
            case "native_patch_settings":
                try emit(.response(id: id, outcome: .error(.init(detail: "Injected failure", code: .string("SETTINGS_WRITE_FAILED"), operation: nil))))
            case "native_get_dns":
                try emit(.response(id: id, outcome: .result(.object(["content": .string("dns:\n  enable: true\n  nameserver:\n    - https://example.test/dns-query\n"), "uid": .string("fixture"), "enabled": .bool(false)]))))
            case "native_get_logs":
                try emit(.response(id: id, outcome: .result(.object(["lines": .array([.string("[info] Fixture core ready"), .string("[warn] Example log entry"), .string("[info] No production core is connected")])]))))
            case "native_subscription_details":
                try emit(.response(id: id, outcome: .result(.object(["uid": .string("fixture"), "name": .string("示例订阅"), "url": .string("https://example.test/sub"), "interval": .integer(1440), "autoUpdate": .bool(true), "withProxy": .bool(false), "usage": .object(["upload": .integer(1048576), "download": .integer(10485760), "total": .integer(10737418240), "expire": .integer(1800000000)])]))))
            case "native_import_subscription", "native_create_local_profile", "native_patch_subscription", "native_save_dns", "native_set_dns_override":
                try emit(.response(id: id, outcome: .result(.object(["saved": .bool(true), "status": .string("applied")]))))
            case "native_create_local_backup":
                backups.append("fixture.zip")
                try emit(.response(id: id, outcome: .result(.object(["filename": .string("fixture.zip")]))))
            case "native_list_local_backups":
                try emit(.response(id: id, outcome: .result(.object(["backups": .array(backups.map { .object(["filename": .string($0), "lastModified": .string("2026-01-01T00:00:00Z"), "size": .integer(42)]) })]))))
            case "native_delete_local_backup":
                guard case .string(let name) = params["filename"] else { fatalError() }
                backups.removeAll { $0 == name }
                try emit(.response(id: id, outcome: .result(.object(["deleted": .bool(true)]))))
            case "native_import_local_backup":
                backups.append("imported.zip")
                try emit(.response(id: id, outcome: .result(.object(["filename": .string("imported.zip")]))))
            case "native_export_local_backup":
                try emit(.response(id: id, outcome: .result(.object(["exported": .bool(true)]))))
            case "native_restore_local_backup", "native_restore_webdav_backup":
                try emit(.response(id: id, outcome: .result(.object(["restored": .bool(true), "requiresRestart": .bool(true)]))))
            case "native_get_webdav_config":
                try emit(.response(id: id, outcome: .result(.object(["url": .string("https://example.test/dav"), "username": .string("fixture"), "passwordConfigured": .bool(true)]))))
            case "native_save_webdav_config":
                try emit(.response(id: id, outcome: .result(.object(["saved": .bool(true)]))))
            case "native_create_webdav_backup":
                remoteBackups.append("remote.zip")
                try emit(.response(id: id, outcome: .result(.object(["filename": .string("remote.zip")]))))
            case "native_list_webdav_backups":
                try emit(.response(id: id, outcome: .result(.object(["backups": .array(remoteBackups.map { .object(["filename": .string($0), "lastModified": .string("2026-01-01T00:00:00Z")]) })]))))
            case "native_delete_webdav_backup":
                guard case .string(let name) = params["filename"] else { fatalError() }
                remoteBackups.removeAll { $0 == name }
                try emit(.response(id: id, outcome: .result(.object(["deleted": .bool(true)]))))
            default: fatalError("Unexpected fixture command")
            }
        }
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--fixture") { try fixture(); return }
        if Bundle.main.object(forInfoDictionaryKey: "TezFeatureFixtureUI") as? Bool == true { launchUI(); return }
        let suite = "tez.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = TezPreviewPreferences(defaults: defaults)
        preferences.appearance = .dark; preferences.showProtocol = false; preferences.reduceTransparency = true
        let restored = TezPreviewPreferences(defaults: defaults)
        precondition(restored.appearance == .dark && !restored.showProtocol && restored.reduceTransparency)

        let latency = NativeLatencyModel()
        var calls: [[String]] = []
        let names = (1...9).map { "node-\($0)" }
        await latency.test(names: names + [names[0]], url: "https://example.test", timeout: 1000) { command, params in
            precondition(command == "native_test_latency")
            precondition(params["timeout"] == .integer(1000))
            guard case .array(let targets) = params["names"] else { fatalError() }
            let values = try targets.map { try $0.decoded(String.self) }
            calls.append(values)
            return .object(["results": .array(values.reversed().map { .object(["name": .string($0), "delay": .integer(42)]) })])
        }
        precondition(calls.map(\.count) == [4, 4, 1])
        precondition(latency.completed == 9 && latency.results.count == 9 && !latency.busy)
        precondition(latency.label(for: names[0], fallback: "old") == "42 ms")
        calls = []
        await latency.test(names: names, url: "https://example.test", timeout: 1000) { _, params in
            guard case .array(let targets) = params["names"] else { fatalError() }
            let values = try targets.map { try $0.decoded(String.self) }; calls.append(values)
            latency.stopAfterCurrentBatch()
            return .object(["results": .array(values.map { .object(["name": .string($0), "delay": .null, "error": .string("PROBE_FAILED")]) })])
        }
        precondition(calls.count == 1 && latency.stopped && latency.completed == 4)
        precondition(latency.label(for: names[0], fallback: "old") == "超时 / 失败")
        await latency.test(names: ["node"], url: "https://example.test", timeout: 1000) { _, _ in
            .object(["results": .array([.object(["name": .string("wrong"), "delay": .integer(5)])])])
        }
        precondition(latency.error != nil && latency.completed == 0 && !latency.busy)

        let backend = NativeBackendStore(helperURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            arguments: ["--fixture"], timeout: .seconds(1), mode: .attach)
        backend.connect()
        for _ in 0..<200 {
            if backend.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(backend.state == .connected)
        let operation = NativeFeatureOperation()
        precondition(backend.supports("native_create_local_backup"))
        let created = await operation.request(backend, "native_create_local_backup")
        precondition(created == .object(["filename": .string("fixture.zip")]))
        guard let listing = await operation.request(backend, "native_list_local_backups") else { fatalError("Missing backup list") }
        let backups = try listing.decoded(NativeBackupList.self).backups
        precondition(backups.count == 1 && backups[0].filename == "fixture.zip" && backups[0].size == 42)
        let deleted = await operation.request(backend, "native_delete_local_backup", ["filename": .string("fixture.zip")])
        precondition(deleted == .object(["deleted": .bool(true)]))
        let task = Task { await operation.request(backend, "native_get_settings") }
        try await Task.sleep(for: .milliseconds(50))
        precondition(backend.workspaceBusy && operation.busy)
        backend.refresh() // Deferred until the long operation completes, not timed out behind it.
        do { _ = try await backend.request("native_patch_settings"); preconditionFailure("Concurrent workspace request accepted") } catch {}
        let settings = try await task.value?.decoded(NativeSettingsPayload.self)
        precondition(settings?.mode == "rule" && settings?.values["verge_mixed_port"] == .integer(7897))
        precondition(!backend.workspaceBusy && !operation.busy)
        let overlapping = Task { @MainActor in await operation.request(backend, "native_get_settings") }
        backend.refresh()
        let concurrent = await overlapping.value
        precondition(concurrent != nil)
        try await Task.sleep(for: .milliseconds(50))
        precondition(backend.state == .connected, "A deferred snapshot refresh must not break the managed connection")
        let failed = await operation.request(backend, "native_patch_settings", ["values": .object(["verge_mixed_port": .integer(7897)])])
        precondition(failed == nil && operation.error?.contains("SETTINGS_WRITE_FAILED") == true)
        try await Task.sleep(for: .milliseconds(50))
        precondition(backend.state == .connected)
        backend.disconnect()
        print("Native feature checks passed: backup protocol, mocked latency batching, preferences, serial requests, error preservation")
    }

    @MainActor static func launchUI() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let helper = Bundle.main.object(forInfoDictionaryKey: "TezIsolatedHelper") as? String
        let root = "/private/tmp/tez-native-isolated-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let backend = helper.map { NativeBackendStore(helperURL: URL(fileURLWithPath: $0), arguments: ["--stdio", "--isolated", root], mode: .managed) }
            ?? NativeBackendStore(helperURL: Bundle.main.executableURL!, arguments: ["--fixture"], mode: .attach)
        let preferences = TezPreviewPreferences(defaults: .standard)
        let delegate = FeatureCheckDelegate(backend: backend, root: helper == nil ? nil : root)
        application.delegate = delegate
        let content = FeatureCheckUI(backend: backend, isolated: helper != nil)
            .environment(preferences).frame(minWidth: 760, minHeight: 720)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = helper == nil ? "Tez 功能界面检查 · 模拟数据" : "Tez 功能界面检查 · 隔离内核"
        window.contentView = NSHostingView(rootView: content)
        let menu = NSMenu()
        let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出界面检查", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); application.mainMenu = menu
        window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class FeatureCheckDelegate: NSObject, NSApplicationDelegate {
    let backend: NativeBackendStore
    let root: String?
    init(backend: NativeBackendStore, root: String?) { self.backend = backend; self.root = root }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            let safe = await backend.shutdownForTermination()
            if safe, let root { try? FileManager.default.removeItem(atPath: root) }
            sender.reply(toApplicationShouldTerminate: safe)
        }
        return .terminateLater
    }
}

private struct FeatureCheckUI: View {
    @Bindable var backend: NativeBackendStore
    let isolated: Bool
    @State private var fixtureURL = ""
    @State private var status = "等待隔离后台"
    @State private var addingSubscription = false
    var body: some View {
        VStack {
            HStack { Text(status); Spacer(); if !fixtureURL.isEmpty { Text(fixtureURL).textSelection(.enabled).accessibilityIdentifier("fixture.url") } }.font(.caption).padding(8)
            TabView {
                NativeNetworkSettingsView(store: backend).tabItem { Text("网络设置") }
                NativeDNSSettingsView(store: backend).tabItem { Text("DNS") }
                Button("添加配置", systemImage: "plus") { addingSubscription = true }
                    .tabItem { Text("添加订阅") }
                if let profile = backend.snapshot?.profiles.items.first(where: { $0.type == "remote" }) {
                    NativeSubscriptionSheet(store: backend, profile: profile).tabItem { Text("订阅管理") }
                }
                NativeLogsView(store: backend).tabItem { Text("日志") }
                NativeLocalBackupsView(store: backend).tabItem { Text("备份") }
            }
        }.sheet(isPresented: $addingSubscription) { NativeSubscriptionSheet(store: backend, profile: nil) }
        .task {
            backend.connect()
            for _ in 0..<500 {
                if backend.state == .connected { break }
                if backend.state == .failed { status = "隔离后台连接失败"; return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard backend.state == .connected else { status = "隔离后台连接超时"; return }
            if isolated {
                do {
                    while backend.workspaceBusy { try await Task.sleep(for: .milliseconds(20)) }
                    let runtime = try await backend.request("native_get_runtime")
                    if case .object(let fields) = runtime, case .string(let url) = fields["fixtureSubscriptionURL"] { fixtureURL = url }
                    while backend.workspaceBusy { try await Task.sleep(for: .milliseconds(20)) }
                    _ = try await backend.request("native_core_start")
                    backend.refresh()
                    status = "隔离内核运行中 · 当前代理未更改"
                } catch { status = "隔离内核启动失败：\(NativeFeatureError.message(error))" }
            } else { status = "模拟数据 · 不连接内核" }
        }
    }
}
