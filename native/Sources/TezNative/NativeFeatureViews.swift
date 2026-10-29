import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension BackendJSON {
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

enum NativeFeatureError {
    static func message(_ error: Error) -> String {
        if case NativeBackendError.remote(let remote) = error {
            let code: String
            if let value = remote.code, case .string(let text) = value { code = text } else { code = "REQUEST_FAILED" }
            var detail = "\(code)：\(String(remote.detail.prefix(4000)))"
            if let operation = remote.operation, operation != .null,
               let data = try? JSONEncoder().encode(operation), let text = String(data: data, encoding: .utf8) {
                detail += "\n\(String(text.prefix(4000)))"
            }
            return detail
        }
        if case NativeBackendError.unavailable(let message) = error {
            return message == "请求超时" ? "请求超时，执行结果未确认。请重新读取状态；不会自动重试。" : message
        }
        return String(describing: error)
    }
}

@Observable @MainActor
final class NativeFeatureOperation {
    private(set) var busy = false
    var error: String?
    var message: String?

    func request(_ store: NativeBackendStore, _ command: String, _ params: [String: BackendJSON] = [:],
                 refresh: Bool = false, timeout: Duration = .seconds(150)) async -> BackendJSON? {
        guard !busy else { return nil }
        busy = true; error = nil; message = nil
        defer { busy = false; if refresh { store.refresh() } }
        do { return try await store.request(command, params: params, timeout: timeout, serialWorkspace: true) }
        catch { self.error = NativeFeatureError.message(error); return nil }
    }
}

struct NativeFeatureFeedback: View {
    let operation: NativeFeatureOperation
    var body: some View {
        if let error = operation.error {
            ScrollView { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 74)
        } else if let message = operation.message {
            Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NativeBackupEntry: Decodable, Identifiable {
    let filename: String
    let lastModified: String
    let size: UInt64?
    var id: String { filename }
}

struct NativeBackupList: Decodable {
    let backups: [NativeBackupEntry]
}

struct NativeLocalBackupsView: View {
    let store: NativeBackendStore
    @State private var operation = NativeFeatureOperation()
    @State private var backups: [NativeBackupEntry] = []
    @State private var pending: BackupAction?
    @State private var location: BackupLocation = .local
    @State private var showingWebdavSettings = false
    @State private var loaded = false

    private var busy: Bool { operation.busy || store.workspaceBusy }
    private enum BackupLocation: String, CaseIterable { case local = "本地", webdav = "WebDAV" }
    private struct BackupAction: Identifiable {
        enum Kind { case delete, restore }
        let kind: Kind
        let backup: NativeBackupEntry
        let location: BackupLocation
        var id: String { "\(location.rawValue)-\(backup.filename)-\(kind)" }
    }
    private var prefix: String { location == .local ? "local" : "webdav" }
    private var listCommand: String { "native_list_\(prefix)_backups" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("备份位置", selection: $location) {
                    ForEach(BackupLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 150).disabled(busy)
                Spacer()
                if operation.busy { ProgressView().controlSize(.small) }
                if location == .webdav {
                    Button { showingWebdavSettings = true } label: { Image(systemName: "gearshape") }
                        .help("WebDAV 设置").disabled(busy || !store.supports("native_get_webdav_config"))
                } else {
                    Button { importBackup() } label: { Image(systemName: "square.and.arrow.down") }
                        .help("导入备份").disabled(busy || !store.supports("native_import_local_backup"))
                }
                Button { Task { await load() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(busy || !store.supports(listCommand))
                Button { Task { await create() } } label: {
                    Label("创建备份", systemImage: "plus")
                }
                .disabled(busy || !store.supports("native_create_\(prefix)_backup"))
            }.padding(16)
            Divider()
            if !store.supports(listCommand) {
                ContentUnavailableView("备份不可用", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if backups.isEmpty && loaded {
                ContentUnavailableView("暂无备份", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                      ForEach(backups) { backup in
                       HStack(spacing: 12) {
                        Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backup.filename).lineLimit(1).truncationMode(.middle)
                            Text(detail(backup))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if location == .local {
                            Button { exportBackup(backup) } label: { Image(systemName: "square.and.arrow.up") }
                                .help("导出备份").accessibilityLabel("导出备份").disabled(busy || !store.supports("native_export_local_backup"))
                        }
                        Button { pending = BackupAction(kind: .restore, backup: backup, location: location) } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }.help("恢复备份").accessibilityLabel("恢复备份").disabled(busy || !store.supports("native_restore_\(prefix)_backup"))
                        Button(role: .destructive) { pending = BackupAction(kind: .delete, backup: backup, location: location) } label: {
                            Image(systemName: "trash")
                        }
                        .help("删除备份")
                        .accessibilityLabel("删除备份")
                        .disabled(busy || !store.supports("native_delete_\(prefix)_backup"))
                       }.padding(.vertical, 10).padding(.horizontal, 16).accessibilityElement(children: .contain)
                       Divider()
                      }
                    }
                }
                .overlay { if !loaded && operation.busy { ProgressView() } }
            }
            if operation.error != nil || operation.message != nil {
                Divider()
                NativeFeatureFeedback(operation: operation).padding(12)
            }
        }
        .task { await load() }
        .onChange(of: store.supports(listCommand)) { _, available in
            if available { Task { await load() } }
        }
        .onChange(of: location) { _, _ in backups = []; loaded = false; Task { await load() } }
        .sheet(isPresented: $showingWebdavSettings, onDismiss: { Task { await load() } }) {
            NativeWebdavSettings(store: store)
        }
        .alert(item: $pending) { action in
            let restore = action.kind == .restore
            return Alert(title: Text(restore ? "恢复备份？" : "删除备份？"),
                  message: Text(restore ? "\(action.backup.filename)\n恢复会覆盖当前配置，并可能中断代理。恢复前会创建本地备份。" : action.backup.filename),
                  primaryButton: .destructive(Text(restore ? "恢复" : "删除")) { Task { await perform(action) } },
                  secondaryButton: .cancel())
        }
    }

    private func load() async {
        guard store.supports(listCommand), !busy else { return }
        guard let result = await operation.request(store, listCommand, timeout: .seconds(350)) else { return }
        do { backups = try result.decoded(NativeBackupList.self).backups; loaded = true }
        catch { operation.error = "无法读取备份列表。" }
    }

    private func create() async {
        guard await operation.request(store, "native_create_\(prefix)_backup", timeout: .seconds(350)) != nil else { return }
        await reloadAfter("备份已创建")
    }

    private func perform(_ action: BackupAction) async {
        let target = action.location == .local ? "local" : "webdav"
        let verb = action.kind == .restore ? "restore" : "delete"
        guard await operation.request(store, "native_\(verb)_\(target)_backup", ["filename": .string(action.backup.filename)], refresh: action.kind == .restore, timeout: .seconds(350)) != nil else { return }
        await reloadAfter(action.kind == .restore ? "配置已恢复，重启 Tez 后完全生效" : "备份已删除")
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard await operation.request(store, "native_import_local_backup", ["source": .string(url.path)], timeout: .seconds(350)) != nil else { return }
            await reloadAfter("备份已导入")
        }
    }

    private func exportBackup(_ backup: NativeBackupEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = backup.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard await operation.request(store, "native_export_local_backup", ["filename": .string(backup.filename), "destination": .string(url.path)], timeout: .seconds(350)) != nil else { return }
            operation.message = "备份已导出"
        }
    }

    private func detail(_ backup: NativeBackupEntry) -> String {
        guard let size = backup.size else { return date(backup.lastModified) }
        return "\(date(backup.lastModified)) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))"
    }

    private func reloadAfter(_ message: String) async {
        await load()
        if let error = operation.error {
            operation.error = "\(message)；刷新列表失败：\(error)"
        } else {
            operation.message = message
        }
    }

    private func date(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct NativeWebdavConfig: Decodable {
    let url: String?
    let username: String?
    let passwordConfigured: Bool
}

struct NativeWebdavSettings: View {
    let store: NativeBackendStore
    @Environment(\.dismiss) private var dismiss
    @State private var operation = NativeFeatureOperation()
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var hasPassword = false
    @State private var originalURL = ""
    @State private var originalUsername = ""
    @State private var confirmHTTP = false
    private var requiresPassword: Bool { !hasPassword || url != originalURL || username != originalUsername }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WebDAV 设置").font(.headline)
            Form {
                TextField("服务器地址", text: $url)
                TextField("用户名", text: $username)
                SecureField(requiresPassword ? "密码" : "密码（留空保留现有密码）", text: $password)
            }.formStyle(.grouped)
            NativeFeatureFeedback(operation: operation)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if url.lowercased().hasPrefix("http://") { confirmHTTP = true }
                    else { Task { await save() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(operation.busy || url.isEmpty || username.isEmpty || (requiresPassword && password.isEmpty) || !store.supports("native_save_webdav_config"))
            }
        }.padding(20).frame(width: 460, height: 310)
        .task {
            guard let value = await operation.request(store, "native_get_webdav_config") else { return }
            do {
                let config = try value.decoded(NativeWebdavConfig.self)
                url = config.url ?? ""; username = config.username ?? ""; hasPassword = config.passwordConfigured
                originalURL = url; originalUsername = username
            } catch { operation.error = "无法读取 WebDAV 设置。" }
        }
        .alert("使用未加密连接？", isPresented: $confirmHTTP) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) { Task { await save() } }
        } message: { Text("HTTP 会以明文传输用户名和密码。") }
    }
    private func save() async {
        let parameters: [String: BackendJSON] = ["url": .string(url), "username": .string(username), "password": password.isEmpty ? .null : .string(password)]
        if await operation.request(store, "native_save_webdav_config", parameters) != nil { dismiss() }
    }
}

struct NativeSettingsPayload: Decodable {
    var values: [String: BackendJSON]
    var mode: String?
}

struct NativeNetworkSettingsView: View {
    @Bindable var store: NativeBackendStore
    @State private var operation = NativeFeatureOperation()
    @State private var values: [String: BackendJSON] = [:]
    @State private var original: [String: BackendJSON] = [:]
    @State private var mode = "rule"
    @State private var originalMode = "rule"
    @State private var confirmsApply = false

    private var changes: [String: BackendJSON] { values.filter { original[$0.key] != $0.value } }
    private var canRead: Bool { store.supports("native_get_settings") }
    private var portsValid: Bool {
        ["verge_mixed_port", "verge_port", "verge_socks_port"].allSatisfy { key in
            let fallback = key == "verge_mixed_port" ? "7897" : key == "verge_port" ? "7899" : "7898"
            return Int(text(key, fallback)).map { (1...65535).contains($0) } ?? false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("代理") {
                    Toggle("系统代理", isOn: boolean("enable_system_proxy"))
                    Toggle("TUN", isOn: boolean("enable_tun_mode"))
                    Toggle("代理守护", isOn: boolean("enable_proxy_guard"))
                    Toggle("PAC", isOn: boolean("proxy_auto_config"))
                }
                Section("端口") {
                    TextField("混合端口", text: port("verge_mixed_port", "7897"))
                    Toggle("HTTP 端口", isOn: boolean("verge_http_enabled"))
                    TextField("HTTP", text: port("verge_port", "7899"))
                    Toggle("SOCKS 端口", isOn: boolean("verge_socks_enabled"))
                    TextField("SOCKS", text: port("verge_socks_port", "7898"))
                }
                Section("分流") {
                    Picker("模式", selection: $mode) {
                        Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
                    }.pickerStyle(.segmented)
                    Button("应用模式") { Task { await applyMode() } }
                        .disabled(mode == originalMode || !store.supports("native_set_mode"))
                }
                Section("检测与日志") {
                    TextField("测速地址", text: string("default_latency_test", "https://www.gstatic.com/generate_204"))
                    TextField("超时（毫秒）", text: port("default_latency_timeout", "5000"))
                    Picker("应用日志级别", selection: string("app_log_level", "info")) {
                        ForEach(["silent", "error", "warn", "info", "debug", "trace"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("代理绕过列表", text: string("system_proxy_bypass", ""), axis: .vertical).lineLimit(2...4)
                }
            }.formStyle(.grouped).disabled(operation.busy || !canRead)
            Divider()
            HStack {
                NativeFeatureFeedback(operation: operation)
                if !canRead { Label("后台未连接", systemImage: "link.badge.plus").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if operation.busy { ProgressView().controlSize(.small) }
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(operation.busy || !canRead)
                Button("应用网络设置") { confirmsApply = true }
                    .disabled(operation.busy || changes.isEmpty || !portsValid || !store.supports("native_patch_settings"))
            }.padding(14)
        }
        .task(id: canRead) { if canRead { await load() } }
        .confirmationDialog("应用网络设置？", isPresented: $confirmsApply, titleVisibility: .visible) {
            Button("应用") { Task { await apply() } }
            Button("取消", role: .cancel) {}
        } message: { Text("端口、系统代理和 TUN 的改动可能中断当前连接。") }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        switch values[key] { case .string(let value): value; case .integer(let value): String(value); case .unsigned(let value): String(value); default: fallback }
    }
    private func string(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { text(key, fallback) }, set: { values[key] = .string($0) })
    }
    private func port(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { text(key, fallback) }, set: { values[key] = Int64($0).map(BackendJSON.integer) ?? .string($0) })
    }
    private func boolean(_ key: String) -> Binding<Bool> {
        Binding(get: { values[key] == .bool(true) }, set: { values[key] = .bool($0) })
    }
    private func load() async {
        guard let result = await operation.request(store, "native_get_settings") else { return }
        do {
            let payload = try result.decoded(NativeSettingsPayload.self)
            values = payload.values; original = payload.values
            mode = payload.mode ?? "rule"; originalMode = mode
        } catch { operation.error = NativeFeatureError.message(error) }
    }
    private func apply() async {
        guard await operation.request(store, "native_patch_settings", ["values": .object(changes)], refresh: true) != nil else { return }
        await load(); operation.message = "网络设置已应用"
    }
    private func applyMode() async {
        guard await operation.request(store, "native_set_mode", ["mode": .string(mode)], refresh: true) != nil else { return }
        originalMode = mode; operation.message = "分流模式已应用"
    }
}

struct NativeDNSPayload: Decodable { var content: String; var uid: String?; var enabled: Bool }

struct NativeDNSSettingsView: View {
    @Bindable var store: NativeBackendStore
    @State private var operation = NativeFeatureOperation()
    @State private var content = ""
    @State private var original = ""
    @State private var uid: String?
    @State private var enabled = false
    @State private var confirmation: String?
    @State private var showConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("当前配置使用 DNS 覆写", isOn: $enabled).disabled(uid == nil)
                Spacer()
                Button("应用到当前配置") { Task { await apply(confirmation: nil) } }
                    .disabled(operation.busy || uid == nil || content != original || !store.supports("native_set_dns_override"))
            }
            TextEditor(text: $content).font(.system(.body, design: .monospaced))
                .border(Color(nsColor: .separatorColor), width: 1)
                .accessibilityLabel("DNS YAML")
            HStack {
                NativeFeatureFeedback(operation: operation)
                Spacer()
                if operation.busy { ProgressView().controlSize(.small) }
                Button("重新读取", systemImage: "arrow.clockwise") { Task { await load() } }
                Button("保存草稿", systemImage: "square.and.arrow.down") { Task { await save() } }
                    .disabled(content == original || !store.supports("native_save_dns"))
            }
        }
        .padding(18).disabled(operation.busy || !store.supports("native_get_dns"))
        .task(id: store.state) { if store.supports("native_get_dns") { await load() } }
        .alert("覆写订阅中的 DNS？", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) { confirmation = nil }
            Button("确认覆写") { Task { await apply(confirmation: confirmation) } }
        } message: { Text("当前订阅带有自己的 DNS。确认后，用已保存的 DNS 草稿覆写当前配置。") }
    }
    private func load() async {
        guard let result = await operation.request(store, "native_get_dns") else { return }
        do {
            let payload = try result.decoded(NativeDNSPayload.self)
            content = payload.content; original = content; uid = payload.uid; enabled = payload.enabled
        } catch { operation.error = NativeFeatureError.message(error) }
    }
    private func save() async {
        guard await operation.request(store, "native_save_dns", ["content": .string(content)]) != nil else { return }
        original = content; operation.message = "草稿已保存，尚未应用"
    }
    private func apply(confirmation: String?) async {
        guard let uid else { return }
        var params: [String: BackendJSON] = ["uid": .string(uid), "enabled": .bool(enabled)]
        if let confirmation { params["confirmation"] = .string(confirmation) }
        guard let result = await operation.request(store, "native_set_dns_override", params, refresh: true) else { return }
        if case .object(let fields) = result, fields["status"] == .string("confirmation_required"),
           let source = fields["source"], case .string(let token) = source {
            self.confirmation = token; showConfirmation = true
        } else {
            await load(); operation.message = "DNS 覆写设置已应用"
        }
    }
}

struct NativeLogPayload: Decodable { var lines: [String]; var gap: Bool?; var truncated: Bool?; var streaming: Bool? }
struct NativeActivityWorkspace: View {
    let store: NativeBackendStore
    @State private var showsLogs = false
    @State private var tab = ActivityTab.connections
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("活动视图", selection: Binding(get: { showsLogs ? "logs" : tab.rawValue }, set: { value in
                    if let next = ActivityTab(rawValue: value) { tab = next; showsLogs = false }
                    else { showsLogs = true }
                })) {
                    ForEach(ActivityTab.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                    Label("日志", systemImage: "text.alignleft").tag("logs")
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel("活动视图").accessibilityIdentifier("live.activity.tabs")
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, TezStyle.pageInset).frame(height: 48)
            Divider()
            if showsLogs { NativeLogsView(store: store) }
            else { NativeActivityView(store: store, tab: $tab) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct NativeLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var content: String
    init(content: String) { self.content = content }
    init(configuration: ReadConfiguration) throws { content = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(content.utf8)) }
}

struct NativeLogsView: View {
    @Bindable var store: NativeBackendStore
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var lines: [String] = []
    @State private var logGap = false
    @State private var logTruncated = false
    @State private var streaming = false
    @State private var level = "all"
    @State private var query = ""
    @State private var paused = false
    @State private var followsTail = true
    @State private var exports = false
    @State private var exportDocument = NativeLogDocument(content: "")
    private var pollKey: String { "\(store.state)-\(level)-\(query)-\(paused)" }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("级别", selection: $level) { ForEach(["all", "error", "warn", "info", "debug", "trace"], id: \.self) { Text($0 == "all" ? "全部级别" : $0).tag($0) } }
                    .labelsHidden().frame(width: 102).help("日志级别")
                    .accessibilityIdentifier("live.logs.level")
                TezSearchField(prompt: "搜索日志", text: $query, identifier: "live.logs.search", surface: Color(nsColor: .textBackgroundColor))
                Toggle("跟随", isOn: $followsTail).toggleStyle(.checkbox)
                    .fixedSize().help("滚动到最新日志")
                TezToolButton(title: paused ? "继续日志" : "暂停日志", symbol: paused ? "play.fill" : "pause.fill",
                              enabled: store.supports("native_get_logs"), motion: motion) { paused.toggle() }
                    .accessibilityIdentifier("live.logs.pause")
                TezToolButton(title: "刷新日志", symbol: "arrow.clockwise", enabled: !operation.busy && !store.workspaceBusy && store.supports("native_get_logs")) {
                    Task { await load() }
                }
                TezToolButton(title: "导出日志", symbol: "square.and.arrow.up", enabled: !lines.isEmpty) {
                    exportDocument = .init(content: lines.joined(separator: "\n")); exports = true
                }
            }.padding(.horizontal, TezStyle.pageInset).frame(height: 48)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let error = operation.error {
                TezOperationFeedback(message: error, tone: .error).padding(.horizontal, TezStyle.pageInset).padding(.vertical, 10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .top, spacing: 14) {
                                Text((index + 1).formatted()).foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing).accessibilityHidden(true)
                                Text(line).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("log-tail")
                    }.font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, TezStyle.pageInset).padding(.vertical, 14)
                }
                .onChange(of: lines) { _, _ in if followsTail { proxy.scrollTo("log-tail", anchor: .bottom) } }
                .overlay {
                    if lines.isEmpty {
                        TezEmptyState(title: !store.supports("native_get_logs") ? "日志读取不可用" : query.isEmpty && level == "all" ? "暂无日志" : "没有匹配的日志", symbol: "text.alignleft")
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text(logGap ? "日志连接曾中断，期间记录可能缺失" : logTruncated ? "日志达到显示上限" : "\(lines.count) 行")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                TezStatusLabel(title: !store.supports("native_get_logs") ? "未连接" : paused ? "已暂停" : operation.error != nil ? "读取失败" : streaming ? "实时日志" : "定时读取",
                               tone: logGap || logTruncated ? .warning : .neutral,
                               symbol: paused ? "pause.circle" : "text.alignleft", motion: motion)
            }.padding(.horizontal, TezStyle.pageInset).frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: pollKey) {
            guard store.supports("native_get_logs") else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if !paused { await load() }
            while !Task.isCancelled && !paused {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await load()
            }
        }
        .fileExporter(isPresented: $exports, document: exportDocument, contentType: .plainText, defaultFilename: "Tez-Core.log") { result in
            if case .failure(let error) = result { operation.error = NativeFeatureError.message(error) }
        }
    }
    private func load() async {
        guard store.supports("native_get_logs"), !Task.isCancelled, !store.workspaceBusy else { return }
        let requestedLevel = level, requestedQuery = query
        guard let result = await operation.request(store, "native_get_logs", ["limit": .integer(1000), "level": .string(requestedLevel), "query": .string(requestedQuery)]) else { return }
        guard !Task.isCancelled, requestedLevel == level, requestedQuery == query else { return }
        do { let payload = try result.decoded(NativeLogPayload.self); lines = payload.lines; logGap = payload.gap ?? false; logTruncated = payload.truncated ?? false; streaming = payload.streaming ?? false }
        catch { operation.error = NativeFeatureError.message(error) }
    }
}
