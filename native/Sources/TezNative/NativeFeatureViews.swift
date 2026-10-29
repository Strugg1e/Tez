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
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var backups: [NativeBackupEntry] = []
    @State private var pending: BackupAction?
    @State private var location: BackupLocation = .local
    @State private var showingWebdavSettings = false
    @State private var loaded = false

    private var busy: Bool { operation.busy || store.workspaceBusy }
    private enum BackupLocation: String, CaseIterable { case local = "本地", webdav = "远程（WebDAV）" }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
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
            VStack(alignment: .leading, spacing: 16) {
                Text("备份与恢复").font(.system(size: 18, weight: .semibold))
                HStack(spacing: 10) {
                    Picker("备份位置", selection: $location) {
                        ForEach(BackupLocation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 210).disabled(busy)
                    Spacer(minLength: 0)
                    if operation.busy { ProgressView().controlSize(.small) }
                    if location == .webdav {
                        TezToolButton(title: "远程备份服务器设置", symbol: "gearshape", enabled: !busy && store.supports("native_get_webdav_config")) {
                            showingWebdavSettings = true
                        }
                    } else {
                        TezToolButton(title: "导入本地备份", symbol: "square.and.arrow.down", enabled: !busy && store.supports("native_import_local_backup"), action: importBackup)
                    }
                    TezToolButton(title: "刷新备份列表", symbol: "arrow.clockwise", enabled: !busy && store.supports(listCommand)) { Task { await load() } }
                    Button("创建备份", systemImage: "plus") { Task { await create() } }
                        .modifier(TezPrimaryActionStyle()).disabled(busy || !store.supports("native_create_\(prefix)_backup"))
                }
                Text("恢复会覆盖当前配置，并可能中断连接。恢复前会创建一份本地备份。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(TezStyle.pageInset)
            Divider()
            if !store.supports(listCommand) {
                TezEmptyState(title: "备份不可用", symbol: "archivebox", detail: "后台未开放此位置的备份操作。")
            } else if backups.isEmpty && loaded {
                TezEmptyState(title: location == .local ? "暂无本地备份" : "暂无远程备份", symbol: "archivebox")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                      ForEach(backups) { backup in
                       HStack(spacing: 12) {
                        Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backup.filename).font(.system(size: 13, weight: .medium)).lineLimit(2).help(backup.filename)
                            Text(detail(backup))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if location == .local {
                            TezToolButton(title: "导出备份", symbol: "square.and.arrow.up", enabled: !busy && store.supports("native_export_local_backup")) { exportBackup(backup) }
                        }
                        TezToolButton(title: "恢复备份", symbol: "arrow.uturn.backward", enabled: !busy && store.supports("native_restore_\(prefix)_backup")) {
                            pending = BackupAction(kind: .restore, backup: backup, location: location)
                        }
                        Button(role: .destructive) { pending = BackupAction(kind: .delete, backup: backup, location: location) } label: {
                            Image(systemName: "trash").frame(width: 14, height: 14)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("删除备份")
                        .accessibilityLabel("删除备份")
                        .disabled(busy || !store.supports("native_delete_\(prefix)_backup"))
                       }.frame(minHeight: 58).padding(.vertical, 6).padding(.horizontal, TezStyle.pageInset).accessibilityElement(children: .contain)
                       Divider()
                      }
                    }
                }
                .overlay { if !loaded && operation.busy { ProgressView() } }
            }
            if operation.error != nil || operation.message != nil {
                Divider()
                Group {
                    if let error = operation.error { TezOperationFeedback(message: "未收到成功结果，请刷新备份列表确认。", details: error, tone: .error) }
                    else if let message = operation.message { TezOperationFeedback(message: message, tone: .success) }
                }.padding(16)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(motion.feedback, value: operation.message)
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
    private var validURL: Bool {
        guard let value = URLComponents(string: url) else { return false }
        return ["https", "http"].contains(value.scheme?.lowercased() ?? "") && !(value.host ?? "").isEmpty && value.user == nil && value.password == nil
    }
    var body: some View {
        VStack(spacing: 0) {
            TezSettingsPage(title: "远程备份服务器", summary: "连接 WebDAV 服务器以存放远程备份。") {
                TezSettingsSection(title: "服务器地址") {
                    TextField("服务器地址", text: $url).textFieldStyle(.roundedBorder).labelsHidden()
                    Text(verbatim: "完整地址，例如 https://example.com/dav/。推荐使用 HTTPS。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if !url.isEmpty && !validURL {
                        TezStatusLabel(title: "请输入不含用户名或密码的 HTTP / HTTPS 地址", tone: .warning)
                    }
                    if url.lowercased().hasPrefix("http://") {
                        TezStatusLabel(title: "HTTP 会以明文传输用户名和密码", tone: .warning)
                    }
                }
                TezSettingsSection(title: "访问凭据") {
                    TezSettingRow(title: "用户名") { TextField("用户名", text: $username).textFieldStyle(.roundedBorder).frame(width: 280) }
                    TezSettingRow(title: "密码") { SecureField("密码", text: $password).textFieldStyle(.roundedBorder).frame(width: 280) }
                    Text(requiresPassword ? "首次连接，或更改地址与用户名后，必须填写密码。" : "留空保留已保存的密码。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.privacySensitive()
            }
            .disabled(operation.busy)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                NativeSettingsFeedback(operation: operation)
                HStack {
                    if operation.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(operation.busy)
                    Button("保存服务器", systemImage: "checkmark") {
                        if url.lowercased().hasPrefix("http://") { confirmHTTP = true }
                        else { Task { await save() } }
                    }
                    .modifier(TezPrimaryActionStyle()).keyboardShortcut(.defaultAction)
                    .disabled(operation.busy || !validURL || username.isEmpty || (requiresPassword && password.isEmpty) || !store.supports("native_save_webdav_config"))
                }
            }.padding(16)
        }.frame(width: 540, height: 470).interactiveDismissDisabled(operation.busy)
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

struct NativeSettingsFeedback: View {
    let operation: NativeFeatureOperation
    var errorMessage = "未收到成功结果。当前输入仍保留，请重新读取确认。"
    var previousSuccess: String? = nil

    var body: some View {
        if let error = operation.error {
            TezOperationFeedback(message: errorMessage, details: error, tone: .error)
            if let previousSuccess {
                TezStatusLabel(title: previousSuccess, tone: .success)
            }
        } else if let message = operation.message {
            TezOperationFeedback(message: message, tone: .success)
        }
    }
}

struct NativeNetworkSettingsView: View {
    @Bindable var store: NativeBackendStore
    var showsCloseButton = false
    @Environment(\.dismiss) private var dismiss
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var values: [String: BackendJSON] = [:]
    @State private var original: [String: BackendJSON] = [:]
    @State private var mode = "rule"
    @State private var originalMode = "rule"
    @State private var confirmsApply = false
    @State private var confirmsReload = false
    @State private var confirmsMode = false
    @State private var confirmsClose = false
    @State private var confirmsDiscard = false
    @State private var showsTunSettings = false
    @State private var advancedExpanded = false
    @State private var pendingExpanded = false
    @State private var attemptedScope: NativePendingChange.Scope?
    @State private var previousSuccess: String?
    @State private var loaded = false

    private var changes: [String: BackendJSON] { values.filter { original[$0.key] != $0.value } }
    private var canRead: Bool { store.supports("native_get_settings") }
    private var dirty: Bool { !changes.isEmpty || mode != originalMode }
    private var pendingChanges: [NativePendingChange] {
        NativeNetworkPendingChanges.make(values: values, original: original, mode: mode, originalMode: originalMode)
    }
    private var errorMessage: String {
        switch attemptedScope {
        case .proxy: "代理设置未收到成功结果，部分网络状态未确认。草稿仍保留；重新读取仅核对已保存设置。"
        case .mode: "分流模式未收到成功结果。当前草稿仍保留，请重新读取确认。"
        case nil: "未收到成功结果。当前输入仍保留，请重新读取确认。"
        }
    }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var portsValid: Bool {
        ["verge_mixed_port", "verge_port", "verge_socks_port"].allSatisfy { key in
            let fallback = key == "verge_mixed_port" ? "7897" : key == "verge_port" ? "7899" : "7898"
            return Int(text(key, fallback)).map { (1...65535).contains($0) } ?? false
        }
    }
    private var timeoutValid: Bool { Int(text("default_latency_timeout", "5000")).map { (100...30000).contains($0) } ?? false }
    private var guardIntervalValid: Bool { Int(text("proxy_guard_duration", "30")).map { (1...86400).contains($0) } ?? false }
    private var testURLValid: Bool {
        guard let url = URLComponents(string: text("default_latency_test", "https://www.gstatic.com/generate_204")) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TezSettingsPage(title: "网络代理", summary: "代理设置与分流模式分别应用。修改可能中断当前连接。") {
                TezSettingsSection(title: "流量接入") {
                    TezSettingToggle(title: "系统代理", detail: "让遵循 macOS 系统代理的应用使用 Tez。", isOn: boolean("enable_system_proxy"))
                    TezSettingToggle(title: "虚拟网卡（TUN）", detail: "由虚拟网卡接收流量，接入范围取决于当前配置。", isOn: boolean("enable_tun_mode"))
                    Button("TUN 与内核详细设置…", systemImage: "slider.horizontal.3") { showsTunSettings = true }
                        .disabled(!store.supports("native_get_proxy_config"))
                        .accessibilityIdentifier("proxy.settings.advanced")
                }
                TezSettingsSection(title: "分流模式") {
                    Picker("分流模式", selection: $mode) {
                        Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
                    }.pickerStyle(.segmented)
                    Text(modeDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("上次确认：\(loaded ? modeTitle(originalMode) : "未读取")").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                TezSettingsDisclosure(title: "高级设置", summary: "代理端口 · 自动代理（PAC） · 绕过列表 · 测速与日志",
                                      isExpanded: $advancedExpanded, motion: motion) {
                    TezSettingsSection(title: "代理端口") {
                        portField("混合代理端口", key: "verge_mixed_port", fallback: "7897", detail: "HTTP 与 SOCKS 共用；整数 1–65535。")
                        TezSettingToggle(title: "独立 HTTP 端口", detail: "为 HTTP 代理单独开放一个端口。", isOn: boolean("verge_http_enabled"))
                        portField("HTTP 端口", key: "verge_port", fallback: "7899", detail: "整数 1–65535；独立 HTTP 端口开启后使用。")
                        TezSettingToggle(title: "独立 SOCKS 端口", detail: "为 SOCKS 代理单独开放一个端口。", isOn: boolean("verge_socks_enabled"))
                        portField("SOCKS 端口", key: "verge_socks_port", fallback: "7898", detail: "整数 1–65535；独立 SOCKS 端口开启后使用。")
                    }
                    TezSettingsSection(title: "系统代理行为") {
                        TezSettingRow(title: "代理主机", detail: "主机名或 IP 地址，例如 127.0.0.1。") {
                            TextField("代理主机", text: string("proxy_host", "127.0.0.1")).textFieldStyle(.roundedBorder).frame(width: 190)
                        }
                        TezSettingToggle(title: "使用默认绕过列表", detail: "在自定义地址之外保留默认的绕过地址。", isOn: boolean("use_default_bypass"))
                        TezSettingRow(title: "检查绕过列表") {
                            Toggle("检查绕过列表", isOn: boolean("enable_bypass_check")).labelsHidden().toggleStyle(.switch)
                        }
                        TezSettingToggle(title: "自动代理（PAC）", detail: "系统代理开启时，改用 PAC 脚本决定请求去向。", isOn: boolean("proxy_auto_config"))
                        TezSettingToggle(title: "保持系统代理", detail: "系统代理开启时，定期恢复 Tez 的系统代理设置。", isOn: boolean("enable_proxy_guard"))
                        TezSettingRow(title: "代理保持间隔", detail: "秒（s）；范围 1–86400。") {
                            TextField("代理保持间隔（秒）", text: port("proxy_guard_duration", "30")).textFieldStyle(.roundedBorder).frame(width: 96)
                        }
                        if !guardIntervalValid { TezStatusLabel(title: "代理保持间隔必须是 1–86400 的整数", tone: .warning) }
                        TezSettingRow(title: "切换模式或线路时关闭已有连接") {
                            Toggle("切换模式或线路时关闭已有连接", isOn: boolean("auto_close_connection")).labelsHidden().toggleStyle(.switch)
                        }
                        if values["proxy_auto_config"] == .bool(true) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("PAC 脚本").font(.system(size: 13))
                                TextEditor(text: string("pac_file_content", "function FindProxyForURL(url, host) { return \"PROXY %proxy_host%:%mixed-port%; SOCKS5 %proxy_host%:%mixed-port%; DIRECT;\"; }"))
                                    .font(.system(size: 12, design: .monospaced)).padding(8).frame(height: 150)
                                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)) }
                                    .accessibilityLabel("PAC 脚本")
                                Text("JavaScript 格式；保留 FindProxyForURL 函数。").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("不经过系统代理的地址").font(.system(size: 13))
                            TextField("绕过地址", text: string("system_proxy_bypass", ""), axis: .vertical)
                                .textFieldStyle(.roundedBorder).lineLimit(2...4).labelsHidden()
                            Text("用英文逗号分隔，例如 localhost, 127.0.0.1。仅影响系统代理。").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    TezSettingsSection(title: "测速与日志") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("测速地址").font(.system(size: 13))
                            TextField("测速地址", text: string("default_latency_test", "https://www.gstatic.com/generate_204"))
                                .textFieldStyle(.roundedBorder).labelsHidden()
                            Text("完整的 HTTP 或 HTTPS 地址，用于线路延迟测试。").font(.system(size: 11)).foregroundStyle(.secondary)
                            if !testURLValid { TezStatusLabel(title: "请输入不含用户名或密码的 HTTP / HTTPS 地址", tone: .warning) }
                        }
                        TezSettingRow(title: "测速超时", detail: "毫秒（ms）；范围 100–30000。") {
                            TextField("测速超时（毫秒）", text: port("default_latency_timeout", "5000"))
                                .textFieldStyle(.roundedBorder).frame(width: 96)
                        }
                        if !timeoutValid { TezStatusLabel(title: "测速超时必须是 100–30000 的整数", tone: .warning) }
                        TezSettingRow(title: "应用日志级别", detail: "调试与跟踪会记录更多诊断信息。") {
                            Picker("应用日志级别", selection: string("app_log_level", "info")) {
                                ForEach(["silent", "error", "warn", "info", "debug", "trace"], id: \.self) { Text(logTitle($0)).tag($0) }
                            }.labelsHidden().frame(width: 160)
                        }
                    }
                }
            }.disabled(operation.busy || !canRead || !loaded)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                NativeSettingsFeedback(operation: operation, errorMessage: errorMessage, previousSuccess: previousSuccess)
                HStack(spacing: 12) {
                    if dirty {
                        Button {
                            withAnimation(motion.layout) { pendingExpanded.toggle() }
                        } label: {
                            Label("\(pendingChanges.count) 项待应用", systemImage: pendingExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pendingExpanded ? "收起" : "展开") \(pendingChanges.count) 项待应用更改")
                        .accessibilityIdentifier("network.pending.toggle")
                    } else {
                        TezStatusLabel(title: !canRead ? "后台未连接，设置不可用" : !loaded ? "代理设置尚未读取" : "网络设置无改动",
                                       motion: motion)
                    }
                    Spacer(minLength: 0)
                    if operation.busy { ProgressView().controlSize(.small) }
                    TezToolButton(title: "放弃全部未应用的更改", symbol: "arrow.uturn.backward", enabled: !operation.busy && dirty) {
                        confirmsDiscard = true
                    }
                    TezToolButton(title: "重新读取网络设置", symbol: "arrow.clockwise", enabled: !operation.busy && canRead) {
                        if dirty { confirmsReload = true } else { Task { await load() } }
                    }
                    if showsCloseButton { Button("完成") { close() }.disabled(operation.busy) }
                }
                if pendingExpanded && dirty {
                    NativePendingChangesList(changes: pendingChanges)
                }
                if pendingChanges.contains(where: \.affectsTraffic) {
                    TezStatusLabel(title: "流量相关更改可能中断当前连接", tone: .warning, motion: motion)
                }
                HStack(spacing: 10) {
                    Text("代理设置 \(changes.count) 项 · 分流模式 \(mode == originalMode ? 0 : 1) 项")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("应用分流模式", systemImage: "checkmark") { confirmsMode = true }
                        .disabled(operation.busy || !loaded || mode == originalMode || !store.supports("native_set_mode"))
                        .accessibilityIdentifier("network.apply.mode")
                    Button("应用代理设置", systemImage: "checkmark") { confirmsApply = true }
                        .modifier(TezPrimaryActionStyle())
                        .disabled(operation.busy || !loaded || changes.isEmpty || !portsValid || !timeoutValid || !guardIntervalValid || !testURLValid || !store.supports("native_patch_settings"))
                        .accessibilityIdentifier("network.apply.proxy")
                }
                if !portsValid || !timeoutValid || !guardIntervalValid || !testURLValid {
                    Text("高级设置中有无效输入，请展开后修改。").font(.system(size: 11)).foregroundStyle(TezStyle.warning)
                }
            }.padding(16)
        }
        .task(id: canRead) { if canRead && !loaded { await load() } }
        .interactiveDismissDisabled(showsCloseButton && (dirty || operation.busy))
        .onExitCommand { if showsCloseButton && !operation.busy { close() } }
        .sheet(isPresented: $showsTunSettings) { NativeAdvancedProxySettings(store: store) }
        .confirmationDialog("放弃未应用的网络改动？", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("放弃并关闭", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("当前填写的代理设置与分流模式尚未全部应用。") }
        .confirmationDialog("应用分流模式？", isPresented: $confirmsMode, titleVisibility: .visible) {
            Button("应用分流模式", role: .destructive) { Task { await applyMode() } }
            Button("取消", role: .cancel) {}
        } message: { Text("只应用分流模式，不应用其他代理设置。改变分流模式可能中断现有连接。") }
        .confirmationDialog("应用代理设置？", isPresented: $confirmsApply, titleVisibility: .visible) {
            Button("应用") { Task { await apply() } }
            Button("取消", role: .cancel) {}
        } message: { Text("只应用代理设置，不应用分流模式。端口、系统代理和 TUN 的改动可能中断当前连接。") }
        .alert("放弃全部未应用的更改？", isPresented: $confirmsDiscard) {
            Button("保留改动", role: .cancel) {}
            Button("放弃更改", role: .destructive) {
                values = original; mode = originalMode
                pendingExpanded = false
            }
        } message: { Text("恢复为上次读取或成功应用的值。此操作不会撤销已经发送到后台的更改。") }
        .alert("舍弃未应用的网络改动？", isPresented: $confirmsReload) {
            Button("保留改动", role: .cancel) {}
            Button("重新读取", role: .destructive) { Task { await load() } }
        } message: { Text("重新读取会替换当前填写的代理设置与分流模式。") }
    }

    private func close() {
        if dirty { confirmsClose = true } else { dismiss() }
    }

    private func portField(_ title: String, key: String, fallback: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TezSettingRow(title: title, detail: detail) {
                TextField(title, text: port(key, fallback)).textFieldStyle(.roundedBorder).frame(width: 96)
            }
            if Int(text(key, fallback)).map({ (1...65535).contains($0) }) != true {
                TezStatusLabel(title: "\(title)必须是 1–65535 的整数", tone: .warning)
            }
        }
    }

    private func modeTitle(_ value: String) -> String {
        NativeNetworkPendingChanges.modeTitle(value)
    }
    private var modeDescription: String {
        switch mode {
        case "global": "全局：统一按全局策略组的选择分流。"
        case "direct": "直连：不经过代理节点。"
        default: "规则：按当前配置中的规则决定请求去向。"
        }
    }
    private func logTitle(_ value: String) -> String {
        NativeNetworkPendingChanges.logTitle(value)
    }

    private func text(_ key: String, _ fallback: String, from source: [String: BackendJSON]? = nil) -> String {
        switch (source ?? values)[key] { case .string(let value): value; case .integer(let value): String(value); case .unsigned(let value): String(value); default: fallback }
    }
    private func string(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { text(key, fallback) }, set: {
            values[key] = $0 == text(key, fallback, from: original) ? original[key] : .string($0)
        })
    }
    private func port(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { text(key, fallback) }, set: {
            let value = Int64($0).map(BackendJSON.integer) ?? .string($0)
            let baseline = text(key, fallback, from: original)
            let previous = Int64(baseline).map(BackendJSON.integer) ?? .string(baseline)
            values[key] = value == previous ? original[key] : value
        })
    }
    private func boolean(_ key: String) -> Binding<Bool> {
        Binding(get: { values[key] == .bool(true) }, set: {
            values[key] = $0 == (original[key] == .bool(true)) ? original[key] : .bool($0)
        })
    }
    private func load() async {
        attemptedScope = nil
        guard let result = await operation.request(store, "native_get_settings") else { return }
        do {
            let payload = try result.decoded(NativeSettingsPayload.self)
            values = payload.values; original = payload.values
            mode = payload.mode ?? "rule"; originalMode = mode
            previousSuccess = nil
            pendingExpanded = false
            loaded = true
        } catch { operation.error = NativeFeatureError.message(error) }
    }
    private func apply() async {
        let submitted = changes
        attemptedScope = .proxy
        guard await operation.request(store, "native_patch_settings", ["values": .object(submitted)], refresh: true) != nil else { return }
        original.merge(submitted) { _, applied in applied }
        previousSuccess = "上次成功：代理设置（\(submitted.count) 项）"
        operation.message = mode != originalMode ? "代理设置已应用；分流模式仍待应用。" : "代理设置已应用"
    }
    private func applyMode() async {
        let submitted = mode
        attemptedScope = .mode
        guard await operation.request(store, "native_set_mode", ["mode": .string(submitted)], refresh: true) != nil else { return }
        originalMode = submitted
        previousSuccess = "上次成功：分流模式（\(modeTitle(submitted))）"
        operation.message = changes.isEmpty ? "分流模式已应用" : "分流模式已应用；代理设置仍待应用。"
    }
}

struct NativeDNSPayload: Decodable { var content: String; var uid: String?; var enabled: Bool }

struct NativeDNSSettingsView: View {
    @Bindable var store: NativeBackendStore
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var content = ""
    @State private var original = ""
    @State private var uid: String?
    @State private var enabled = false
    @State private var originalEnabled = false
    @State private var loaded = false
    @State private var confirmsReload = false
    @State private var confirmation: String?
    @State private var showConfirmation = false

    private var canRead: Bool { store.supports("native_get_dns") }
    private var dirty: Bool { content != original || enabled != originalEnabled }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var profileName: String {
        guard let uid else { return "尚未选择配置" }
        guard let profile = store.snapshot?.profiles.items.first(where: { $0.uid == uid }), !profile.name.isEmpty else { return uid }
        return profile.name
    }

    var body: some View {
        VStack(spacing: 0) {
            TezSettingsPage(title: "DNS 覆写", summary: "保存草稿不会改变正在运行的 DNS。应用会重新载入配置，可能中断连接。") {
                TezSettingsSection(title: "目标配置") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profileName).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        TezStatusLabel(title: !canRead ? "后台未连接，配置状态未确认" : !loaded ? "正在读取配置"
                                       : originalEnabled ? "此配置正在使用 DNS 覆写" : "此配置使用原有 DNS", symbol: "server.rack", motion: motion)
                    }
                    TezSettingToggle(title: "使用 DNS 覆写", detail: "用已保存的 DNS 草稿替代此配置中的 DNS。", isOn: $enabled)
                        .disabled(uid == nil)
                }
                TezSettingsSection(title: "DNS 草稿") {
                    Text("YAML 映射格式；保存后再应用到上方的目标配置。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $content).font(.system(size: 12, design: .monospaced))
                        .padding(8).frame(height: 200)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)) }
                        .accessibilityLabel("DNS 草稿，YAML 格式")
                }
            }.disabled(operation.busy || !canRead || !loaded)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                NativeSettingsFeedback(operation: operation)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        TezStatusLabel(title: !canRead ? "后台未连接，设置不可用" : !loaded ? "草稿尚未读取" : content != original ? "草稿未保存，请先保存" : "草稿已保存",
                                       tone: content != original ? .warning : .neutral, motion: motion)
                        Text("目标：\(profileName)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(profileName)
                    }
                    Spacer(minLength: 0)
                    if operation.busy { ProgressView().controlSize(.small) }
                    TezToolButton(title: "重新读取 DNS 设置", symbol: "arrow.clockwise", enabled: !operation.busy && canRead) {
                        if dirty { confirmsReload = true } else { Task { await load() } }
                    }
                    Button("保存草稿", systemImage: "square.and.arrow.down") { Task { await save() } }
                        .disabled(operation.busy || content == original || !store.supports("native_save_dns"))
                    Button("应用到此配置", systemImage: "checkmark") { Task { await apply(confirmation: nil) } }
                        .modifier(TezPrimaryActionStyle())
                        .disabled(operation.busy || uid == nil || content != original || !store.supports("native_set_dns_override"))
                }
            }.padding(16)
        }
        .task(id: canRead) { if canRead && !loaded { await load() } }
        .alert("覆写订阅中的 DNS？", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) { confirmation = nil }
            Button("确认覆写") { Task { await apply(confirmation: confirmation) } }
        } message: { Text("当前订阅带有自己的 DNS。确认后，用已保存的 DNS 草稿覆写当前配置。") }
        .alert("舍弃未保存的 DNS 改动？", isPresented: $confirmsReload) {
            Button("保留改动", role: .cancel) {}
            Button("重新读取", role: .destructive) { Task { await load() } }
        } message: { Text("重新读取会替换当前 DNS 草稿和覆写开关。") }
    }
    private func load() async {
        guard let result = await operation.request(store, "native_get_dns") else { return }
        do {
            let payload = try result.decoded(NativeDNSPayload.self)
            content = payload.content; original = content; uid = payload.uid; enabled = payload.enabled
            originalEnabled = payload.enabled; loaded = true
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

struct NativeActivityWorkspace: View {
    let store: NativeBackendStore
    @State private var session = NativeActivitySession()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("活动视图", selection: Binding(get: { session.showsLogs ? "logs" : session.tab.rawValue }, set: { value in
                    if let next = ActivityTab(rawValue: value) { session.tab = next; session.showsLogs = false }
                    else { session.showsLogs = true }
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
            if session.showsLogs { NativeLogsView(store: store, session: session.logs) }
            else { NativeActivityView(store: store, session: session) }
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
    @State private var session: NativeLogSession
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var isVisible = false
    @State private var exports = false
    @State private var exportDocument = NativeLogDocument(content: "")
    private var pollKey: String { "\(store.state)-\(session.paused)" }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var lines: [String] { session.lines }
    private var logGap: Bool { session.snapshot?.gap ?? false }
    private var logTruncated: Bool { session.snapshot?.truncated ?? false }
    private var windowCount: Int { session.snapshot?.entries.count ?? 0 }

    init(store: NativeBackendStore, session: NativeLogSession = NativeLogSession()) {
        self.store = store
        _session = State(initialValue: session)
    }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("级别", selection: $session.level) { ForEach(["all", "error", "warn", "info", "debug", "trace"], id: \.self) { Text($0 == "all" ? "全部级别" : $0).tag($0) } }
                    .labelsHidden().frame(width: 102).help("日志级别")
                    .accessibilityIdentifier("live.logs.level")
                TezSearchField(prompt: "搜索缓存日志", text: $session.query, identifier: "live.logs.search", surface: Color(nsColor: .textBackgroundColor))
                Toggle("跟随", isOn: $session.followsTail).toggleStyle(.checkbox)
                    .fixedSize().help("滚动到最新日志")
                TezToolButton(title: session.paused ? "继续日志" : "暂停日志", symbol: session.paused ? "play.fill" : "pause.fill",
                              enabled: store.supports("native_get_logs"), motion: motion) { session.paused.toggle() }
                    .accessibilityIdentifier("live.logs.pause")
                TezToolButton(title: "刷新日志", symbol: "arrow.clockwise", enabled: !operation.busy && !store.workspaceBusy && store.supports("native_get_logs")) {
                    Task { await load() }
                }.accessibilityIdentifier("live.logs.refresh")
                    .help(session.paused ? "读取最新日志并替换冻结窗口；保持暂停" : "读取最新日志")
                TezToolButton(title: "导出日志", symbol: "square.and.arrow.up", enabled: !lines.isEmpty) {
                    exportDocument = .init(content: lines.joined(separator: "\n")); exports = true
                }
            }.padding(.horizontal, TezStyle.pageInset).frame(height: 48)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let target = session.relatedTarget {
                HStack(spacing: 8) {
                    Text("关键词关联：\(target) · 非连接追踪").lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    TezToolButton(title: "关闭关联说明", symbol: "xmark") { session.relatedTarget = nil }
                }.font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, TezStyle.pageInset).padding(.vertical, 6)
                    .accessibilityIdentifier("live.logs.related")
                Divider()
            }
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
                .onChange(of: lines) { _, _ in if session.followsTail { proxy.scrollTo("log-tail", anchor: .bottom) } }
                .overlay {
                    if lines.isEmpty {
                        TezEmptyState(title: !store.supports("native_get_logs") ? "日志读取不可用" : session.query.isEmpty && session.level == "all" ? "暂无日志" : "缓存内没有匹配的日志", symbol: "text.alignleft")
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("匹配 \(lines.count) / 缓存 \(windowCount) 行 · 上限 \(NativeLogSession.limit)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(session.paused ? "仅筛选最近读取的冻结窗口；暂停期间不读取新日志" : "筛选最近读取的最多 1000 行日志")
                Spacer(minLength: 0)
                if logGap || logTruncated {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(TezStyle.warning)
                        .help(logGap ? "日志连接曾中断，期间记录可能缺失" : "日志缓存或响应达到上限，较早记录可能缺失")
                        .accessibilityLabel(logGap ? "日志连接曾中断，期间记录可能缺失" : "日志达到缓存上限")
                }
                TezStatusLabel(title: !store.supports("native_get_logs") ? "未连接" : session.paused ? "已暂停" : operation.error != nil ? "读取失败" : session.snapshot?.streaming == true ? "实时日志" : "定时读取",
                               tone: logGap || logTruncated ? .warning : .neutral,
                               symbol: session.paused ? "pause.circle" : "text.alignleft", motion: motion)
            }.padding(.horizontal, TezStyle.pageInset).frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: pollKey) {
            guard store.supports("native_get_logs") else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if !session.paused { await load() }
            while !Task.isCancelled && !session.paused {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await load()
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; session.stop() }
        .fileExporter(isPresented: $exports, document: exportDocument, contentType: .plainText, defaultFilename: "Tez-Core.log") { result in
            if case .failure(let error) = result { operation.error = NativeFeatureError.message(error) }
        }
    }
    private func load() async {
        guard isVisible, store.supports("native_get_logs"), !Task.isCancelled, !store.workspaceBusy else { return }
        let generation = session.generation
        guard let result = await operation.request(store, "native_get_logs", ["limit": .integer(Int64(NativeLogSession.limit)), "level": .string("all"), "query": .string("")]) else { return }
        guard isVisible, !Task.isCancelled else { return }
        do { session.accept(try result.decoded(NativeLogPayload.self), generation: generation) }
        catch { operation.error = NativeFeatureError.message(error) }
    }
}
