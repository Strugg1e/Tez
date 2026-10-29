import Network
import SwiftUI

enum NativeProxyInput {
    static func entries(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func validCIDR(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0 else { return false }
        return (IPv4Address(String(parts[0])) != nil && prefix <= 32)
            || (IPv6Address(String(parts[0])) != nil && prefix <= 128)
    }
}

struct NativeProxyControls: View {
    let store: NativeBackendStore
    let snapshot: NativeSnapshot
    @State private var operation = NativeFeatureOperation()
    @State private var pending: ProxyChange?
    @State private var settings = false
    @State private var chains = false
    private var available: Bool { store.state == .connected && !store.workspaceBusy && !operation.busy }
    private func toggle(_ key: String, _ observed: NativeObservedSwitch?) -> Binding<Bool> {
        Binding(get: { observed?.enabled == true }, set: { pending = ProxyChange(key: key, value: .bool($0)) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("流量接入").font(.system(size: 13, weight: .semibold)); Spacer()
                TezToolButton(title: "代理设置", symbol: "gearshape") { settings = true }.accessibilityIdentifier("live.proxy.settings")
                TezToolButton(title: "链式代理", symbol: "link", enabled: store.supports("native_get_proxy_chains")) { chains = true }
                    .accessibilityIdentifier("live.proxy.chains")
            }
            TezSettingToggle(title: "系统代理", detail: "\(store.state == .connected ? snapshot.network?.systemProxyControl.label ?? "未确认" : "未确认") · 使用 macOS 代理的应用跟随此设置。",
                             isOn: toggle("enable_system_proxy", snapshot.network?.systemProxyControl))
                .disabled(!available || !store.supports("native_patch_settings") || snapshot.network?.systemProxyControl.state != "ready")
                .accessibilityIdentifier("live.proxy.system")
            TezSettingToggle(title: "虚拟网卡（TUN）", detail: "\(store.state == .connected ? snapshot.network?.tun.label ?? "未确认" : "未确认") · 接管范围取决于路由，不代表全部流量。",
                             isOn: toggle("enable_tun_mode", snapshot.network?.tun))
                .disabled(!available || !store.supports("native_patch_settings") || snapshot.network?.tun.state != "ready")
                .accessibilityIdentifier("live.proxy.tun")
            VStack(alignment: .leading, spacing: 8) {
                Text("分流模式").font(.system(size: 13))
                Picker("分流模式", selection: Binding(get: { snapshot.network?.mode.value ?? "" }, set: { pending = ProxyChange(key: "mode", value: .string($0)) })) {
                    if snapshot.network?.mode.value == nil { Text("未确认").tag("") }
                    Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
                }.pickerStyle(.segmented).labelsHidden()
                    .disabled(!available || !store.supports("native_set_mode") || snapshot.network?.mode.state != "ready")
                    .accessibilityIdentifier("live.proxy.mode")
                Text(modeSummary).font(.caption).foregroundStyle(.secondary)
            }
            if operation.busy { ProgressView("正在应用代理改动…").controlSize(.small) }
            if let error = operation.error {
                TezOperationFeedback(message: "改动结果未确认。请刷新连接状态后重试。", details: error, tone: .error)
            } else if let message = operation.message {
                TezOperationFeedback(message: message, tone: .success)
            }
        }
        .confirmationDialog("应用代理改动？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let change = pending { Button("应用改动", role: .destructive) { Task { await apply(change) } } }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text("此操作会改变流量路径，并可能中断现有连接。") }
        .sheet(isPresented: $settings) { NativeNetworkSettingsView(store: store, showsCloseButton: true).frame(width: 680, height: 650) }
        .sheet(isPresented: $chains) { NativeProxyChainView(store: store) }
    }
    private var modeSummary: String {
        guard store.state == .connected else { return "尚未确认当前模式，请连接后台后重试。" }
        switch snapshot.network?.mode.value {
        case "rule": return "按当前配置中的规则决定流量去向。"
        case "global": return "所有代理流量使用全局策略组的当前选择。"
        case "direct": return "不经过代理节点，直接连接目标。"
        default: return "尚未确认当前模式，请刷新连接状态。"
        }
    }
    private func apply(_ change: ProxyChange) async {
        pending = nil
        let result = change.key == "mode"
            ? await operation.request(store, "native_set_mode", ["mode": change.value], refresh: true)
            : await operation.request(store, "native_patch_settings", ["values": .object([change.key: change.value])], refresh: true)
        if result != nil { operation.message = "代理改动已应用" }
    }
}
private struct ProxyChange { let key: String; let value: BackendJSON }

struct NativeAdvancedProxySettings: View {
    let store: NativeBackendStore
    @Environment(\.dismiss) private var dismiss
    @State private var operation = NativeFeatureOperation()
    @State private var values: [String: BackendJSON] = [:]
    @State private var original: [String: BackendJSON] = [:]
    @State private var pending: String?
    @State private var loaded = false
    @State private var advanced = false
    @State private var excludedRoutes = ""
    @State private var hijackedDNS = ""
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var changes: [String: BackendJSON] { values.filter { original[$0.key] != $0.value } }
    private var tun: [String: BackendJSON] { if case .object(let fields) = values["tun"] { fields } else { [:] } }
    private func field(_ key: String, _ fallback: BackendJSON, core: Bool = false) -> Binding<BackendJSON> {
        Binding(get: { (core ? values[key] : tun[key]) ?? fallback }, set: { value in
            if core {
                values[key] = value == (original[key] ?? fallback) ? original[key] : value
            } else {
                let baseline: [String: BackendJSON]
                if case .object(let fields) = original["tun"] { baseline = fields } else { baseline = [:] }
                var fields = tun
                fields[key] = value == (baseline[key] ?? fallback) ? baseline[key] : value
                values["tun"] = fields == baseline ? original["tun"] : .object(fields)
            }
        })
    }
    private func text(_ key: String, _ fallback: String, core: Bool = false) -> Binding<String> {
        let value = field(key, .string(fallback), core: core)
        return Binding(get: { if case .string(let text) = value.wrappedValue { text } else { fallback } }, set: { value.wrappedValue = .string($0) })
    }
    private func flag(_ key: String, _ fallback: Bool, core: Bool = false) -> Binding<Bool> {
        let value = field(key, .bool(fallback), core: core)
        return Binding(get: { value.wrappedValue == .bool(true) }, set: { value.wrappedValue = .bool($0) })
    }
    private var mtu: Binding<String> {
        let value = field("mtu", .integer(1500))
        return Binding(get: {
            switch value.wrappedValue { case .integer(let v): String(v); case .unsigned(let v): String(v); case .string(let v): v; default: "1500" }
        }, set: { value.wrappedValue = Int64($0).map(BackendJSON.integer) ?? .string($0) })
    }
    private var mtuError: Bool { Int(mtu.wrappedValue).map { !(1...65535).contains($0) } ?? true }
    private var deviceError: Bool {
        let device = text("device", "utun1024").wrappedValue
        return device.isEmpty || device.utf8.count > 64 || !device.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
    private var routesError: Bool {
        let entries = NativeProxyInput.entries(excludedRoutes)
        return entries.count > 256 || !entries.allSatisfy(NativeProxyInput.validCIDR)
    }
    private var dnsError: Bool {
        let entries = NativeProxyInput.entries(hijackedDNS)
        return entries.count > 64 || entries.contains { $0.utf8.count > 256 || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
    }
    private var inputInvalid: Bool { mtuError || deviceError || routesError || dnsError }
    private func lines(_ key: String, draft: Binding<String>, fallback: [String] = []) -> Binding<String> {
        Binding(get: { draft.wrappedValue }, set: {
            draft.wrappedValue = $0
            field(key, .array(fallback.map(BackendJSON.string))).wrappedValue = .array(NativeProxyInput.entries($0).map(BackendJSON.string))
        })
    }
    private func readLines(_ key: String, fallback: [String] = []) -> String {
        if case .array(let values) = tun[key] {
            return values.compactMap { if case .string(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }
        return fallback.joined(separator: "\n")
    }
    private func close() {
        if changes.isEmpty { dismiss() } else { pending = "close" }
    }
    var body: some View {
        VStack(spacing: 0) {
            TezSettingsPage(title: "TUN 与内核设置", summary: "应用后更新运行配置，可能中断现有连接。TUN 开关仍由网络代理页控制。") {
                if !store.supports("native_get_proxy_config") {
                    Text("当前后台不支持读取这些设置。").foregroundStyle(.secondary)
                }
                TezSettingsSection(title: "流量路由") {
                    TezSettingToggle(title: "自动路由", detail: "自动建立通往虚拟网卡的路由。", isOn: flag("auto-route", true))
                    TezSettingToggle(title: "自动检测出口网卡", detail: "跟随当前网络连接选择出口。", isOn: flag("auto-detect-interface", true))
                    TezSettingToggle(title: "严格路由", detail: "限制未按 TUN 路由的流量；部分应用连接可能受影响。", isOn: flag("strict-route", false))
                }
                TezSettingsSection(title: "访问与地址") {
                    TezSettingToggle(title: "允许局域网访问", detail: "同一网络中的设备可以访问代理端口。仅在可信网络中开启。", isOn: flag("allow-lan", false, core: true))
                    TezSettingToggle(title: "IPv6", detail: "允许内核使用 IPv6 地址。", isOn: flag("ipv6", false, core: true))
                }
                TezSettingsDisclosure(title: "高级设置", summary: "协议栈、设备、路由排除、DNS 与日志", isExpanded: $advanced, motion: motion) {
                    TezSettingsSection(title: "虚拟网卡") {
                        TezSettingRow(title: "协议栈", detail: "决定虚拟网卡处理流量的方式。") {
                            Picker("协议栈", selection: text("stack", "mips")) {
                                Text("System").tag("system"); Text("gVisor").tag("gvisor"); Text("Mixed").tag("mixed"); Text("Mips").tag("mips")
                            }.labelsHidden().frame(width: 160).accessibilityIdentifier("proxy.tun.stack")
                        }
                        TezSettingRow(title: "设备名称", detail: "最多 64 个字母、数字或 - _ .，例如 utun1024。") {
                            TextField("设备名称", text: text("device", "utun1024")).textFieldStyle(.roundedBorder).frame(width: 160)
                        }
                        if deviceError { Text("设备名称格式不正确。").font(.caption).foregroundStyle(.red) }
                        TezSettingRow(title: "MTU", detail: "每个数据包的最大大小，1–65535 字节。") {
                            HStack(spacing: 6) {
                                TextField("MTU", text: mtu).textFieldStyle(.roundedBorder).frame(width: 94).accessibilityIdentifier("proxy.tun.mtu")
                                Text("字节").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if mtuError { Text("MTU 必须是 1–65535 的整数。").font(.caption).foregroundStyle(.red) }
                    }
                    TezSettingsSection(title: "路由排除") {
                        TezMultilineField(title: "不经过 TUN 的网段", text: lines("route-exclude-address", draft: $excludedRoutes))
                            .accessibilityIdentifier("proxy.tun.exclusions")
                        Text("每行一个 CIDR 网段，例如 192.168.1.0/24 或 fd00::/8。留空表示不添加排除项。")
                            .font(.caption).foregroundStyle(.secondary)
                        if routesError { Text("请输入有效的 IP 地址与前缀长度，最多 256 个网段。").font(.caption).foregroundStyle(.red) }
                    }
                    TezSettingsSection(title: "DNS 接管") {
                        TezMultilineField(title: "接管的 DNS 地址", text: lines("dns-hijack", draft: $hijackedDNS, fallback: ["any:53"]))
                        Text("每行一个地址，例如 any:53。这里控制 TUN 接管的请求，不修改 DNS 覆写草稿。")
                            .font(.caption).foregroundStyle(.secondary)
                        if dnsError { Text("最多 64 个地址；每个地址最多 256 字节，不含控制字符。").font(.caption).foregroundStyle(.red) }
                        TezSettingRow(title: "DNS 模式") {
                            Picker("DNS 模式", selection: text("dns-mode", "")) {
                                Text("自动").tag(""); Text("禁用 (Disabled)").tag("disabled"); Text("原生 (Native)").tag("native"); Text("接管 (Hijack)").tag("hijack")
                            }.labelsHidden().frame(width: 180)
                        }
                    }
                    TezSettingsSection(title: "测速与日志") {
                        TezSettingToggle(title: "统一延迟", detail: "使用统一方式计算不同协议的线路延迟。", isOn: flag("unified-delay", false, core: true))
                        TezSettingRow(title: "内核日志级别") {
                            Picker("内核日志级别", selection: text("log-level", "info", core: true)) {
                                Text("不记录").tag("silent"); Text("错误").tag("error"); Text("警告").tag("warning")
                                Text("信息").tag("info"); Text("调试").tag("debug"); Text("跟踪").tag("trace")
                            }.labelsHidden().frame(width: 160)
                        }
                    }
                }
            }.disabled(operation.busy || !loaded)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                NativeSettingsFeedback(operation: operation)
                HStack(spacing: 12) {
                    if operation.busy { ProgressView().controlSize(.small) }
                    Text(!loaded ? "尚未读取设置" : inputInvalid ? "请修正高级设置中的输入" : changes.isEmpty ? "与已读取的设置一致" : "有未应用的更改")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    TezToolButton(title: "重新读取", symbol: "arrow.clockwise", enabled: !operation.busy && store.supports("native_get_proxy_config")) {
                        if changes.isEmpty { Task { await load() } } else { pending = "reload" }
                    }
                    Button("完成") { close() }.disabled(operation.busy)
                    Button("应用设置") { pending = "apply" }.modifier(TezPrimaryActionStyle())
                        .disabled(!loaded || changes.isEmpty || inputInvalid || operation.busy || !store.supports("native_patch_proxy_config"))
                        .accessibilityIdentifier("proxy.tun.apply")
                }
            }.padding(16)
        }.frame(width: 680, height: 650).task { if !loaded { await load() } }
        .interactiveDismissDisabled(!changes.isEmpty || operation.busy)
        .onExitCommand { if !operation.busy { close() } }
        .confirmationDialog(pending == "apply" ? "应用 TUN 与内核设置？" : "放弃未应用的更改？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let action = pending {
                Button(action == "apply" ? "应用设置" : action == "reload" ? "放弃并重新读取" : "放弃并关闭", role: .destructive) {
                    pending = nil
                    if action == "close" { dismiss() }
                    else { Task {
                        if action == "apply" {
                            guard await operation.request(store, "native_patch_proxy_config", ["values": .object(changes)], refresh: true) != nil else { return }
                        }
                        await load()
                        if action == "apply" && operation.error == nil { operation.message = "设置已应用" }
                    } }
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text(pending == "apply" ? "更新运行配置可能中断现有连接。" : "当前输入尚未应用。取消可继续编辑。") }
    }
    private func load() async {
        guard store.supports("native_get_proxy_config"), let result = await operation.request(store, "native_get_proxy_config") else { return }
        do {
            let payload = try result.decoded(NativeSettingsPayload.self)
            values = payload.values; original = payload.values; loaded = true
            excludedRoutes = readLines("route-exclude-address")
            hijackedDNS = readLines("dns-hijack", fallback: ["any:53"])
        }
        catch { operation.error = NativeFeatureError.message(error) }
    }
}

struct NativeProxyChain: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name = "新代理链"
    var group = ""
    var nodes: [String] = []
}
struct NativeProxyChainPayload: Decodable {
    let chains: [NativeProxyChain]; let activeId: String?; let applied: Bool; let available: [String]; let groups: [String]
}
struct NativeProxyChainView: View {
    let store: NativeBackendStore
    @Environment(\.dismiss) private var dismiss
    @State private var operation = NativeFeatureOperation()
    @State private var payload: NativeProxyChainPayload?
    @State private var draft = NativeProxyChain()
    @State private var node = ""
    @State private var pending: String?
    @State private var baseline: NativeProxyChain?
    @State private var navigation: ChainNavigation?
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var saved: NativeProxyChain? { payload?.chains.first { $0.id == draft.id } }
    private var dirty: Bool { baseline.map { $0 != draft } ?? false }
    private var active: Bool { payload?.applied == true && payload?.activeId == draft.id }
    private var validation: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入代理链名称。" }
        if payload?.groups.contains(draft.group) != true { return "请选择当前配置中的策略组。" }
        if draft.nodes.count < 2 { return "至少添加 2 个节点，依次作为入口与出口。" }
        if draft.nodes.contains(where: { !(payload?.available.contains($0) ?? false) }) { return "部分节点已不可用，请移除或更换后保存。" }
        return nil
    }
    private var needsSave: Bool { dirty || saved == nil }
    private enum ChainNavigation { case new, select(String), reload, close }
    private func navigate(_ destination: ChainNavigation) {
        if dirty { navigation = destination } else { move(to: destination) }
    }
    private func move(to destination: ChainNavigation) {
        switch destination {
        case .close: dismiss(); return
        case .reload: Task { await load() }; return
        case .new: draft = NativeProxyChain(group: payload?.groups.first ?? "")
        case .select(let id):
            guard let chain = payload?.chains.first(where: { $0.id == id }) else { return }
            draft = chain
        }
        baseline = draft; node = ""; operation.message = nil; operation.error = nil
    }
    var body: some View {
        VStack(spacing: 0) {
            TezSettingsPage(title: "链式代理", summary: "按入口到出口的顺序连接多个节点。启用会改变流量路径，并影响使用这些节点的其他连接。") {
                HStack(spacing: 12) {
                    Picker("代理链", selection: Binding(get: { draft.id }, set: { navigate(.select($0)) })) {
                        if saved == nil { Text("新代理链 · 未保存").tag(draft.id) }
                        ForEach(payload?.chains ?? []) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("proxy.chain.saved")
                    TezToolButton(title: "新建代理链", symbol: "plus", motion: motion) { navigate(.new) }
                    TezToolButton(title: "删除代理链", symbol: "trash", enabled: !active && saved != nil && store.supports("native_delete_proxy_chain"), motion: motion) {
                        pending = "native_delete_proxy_chain"
                    }
                }
                if let payload {
                    if let current = payload.chains.first(where: { $0.id == payload.activeId }) {
                        TezStatusLabel(title: payload.applied ? "正在使用：\(current.name)" : "未确认生效：\(current.name)",
                                       tone: payload.applied ? .success : .warning, motion: motion)
                    } else { Text("当前未启用代理链").font(.caption).foregroundStyle(.secondary) }
                }
                TezSettingsSection(title: "名称与使用范围") {
                    TezSettingRow(title: "名称") {
                        TextField("代理链名称", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 300)
                            .accessibilityIdentifier("proxy.chain.name")
                    }
                    TezSettingRow(title: "策略组", detail: "启用时，此组将选择代理链入口。") {
                        Picker("策略组", selection: $draft.group) {
                            if !(payload?.groups.contains(draft.group) ?? false) { Text(draft.group.isEmpty ? "选择策略组" : draft.group).tag(draft.group) }
                            ForEach(payload?.groups ?? [], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 300)
                    }
                    if active {
                        Text("这条代理链正在使用。先停用，再修改节点或名称。").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(active)
                TezSettingsSection(title: "连接顺序") {
                    if draft.nodes.isEmpty {
                        Text("尚未添加节点").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(draft.nodes.enumerated()), id: \.element) { index, name in
                            HStack(spacing: 12) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(name).font(.callout).lineLimit(2)
                                    Text(index == 0 ? "入口" : index == draft.nodes.count - 1 ? "出口" : "中转")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if payload?.available.contains(name) != true {
                                        Label("当前配置中不可用", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                TezToolButton(title: "上移 \(name)", symbol: "arrow.up", enabled: index > 0 && !active, motion: motion) { draft.nodes.swapAt(index, index - 1) }
                                TezToolButton(title: "下移 \(name)", symbol: "arrow.down", enabled: index + 1 < draft.nodes.count && !active, motion: motion) { draft.nodes.swapAt(index, index + 1) }
                                TezToolButton(title: "移除 \(name)", symbol: "minus", enabled: !active, motion: motion) { draft.nodes.remove(at: index) }
                            }.padding(.vertical, 10)
                            if index + 1 < draft.nodes.count { Divider() }
                        }
                    }.animation(motion.layout, value: draft.nodes)
                    HStack(spacing: 12) {
                        Picker("节点", selection: $node) {
                            Text("选择节点").tag("")
                            ForEach((payload?.available ?? []).filter { !draft.nodes.contains($0) }, id: \.self) { Text($0).tag($0) }
                        }
                        TezToolButton(title: "添加节点", symbol: "plus", enabled: !node.isEmpty && draft.nodes.count < 16, motion: motion) {
                            draft.nodes.append(node); node = ""
                        }
                    }.disabled(active)
                    Text("\(draft.nodes.count)/16 个节点 · 至少 2 个 · 首项为入口，末项为出口")
                        .font(.caption).foregroundStyle(.secondary)
                    if payload?.available.isEmpty == true { Text("当前配置没有可用节点。请先在配置页检查线路来源。").font(.caption).foregroundStyle(.secondary) }
                }
            }.disabled(operation.busy || payload == nil)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                NativeSettingsFeedback(operation: operation)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(payload == nil ? "尚未读取代理链" : needsSave ? "未保存" : active ? "已启用" : "已保存，尚未启用").font(.callout)
                        Text(payload == nil ? "重新读取后可编辑。" : needsSave ? validation ?? "保存仅更新记录，不改变当前连接。" : active ? "停用后可继续编辑。" : "启用后改变流量路径。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if operation.busy { ProgressView().controlSize(.small) }
                    TezToolButton(title: "重新读取", symbol: "arrow.clockwise", enabled: store.supports("native_get_proxy_chains") && !operation.busy) { navigate(.reload) }
                    Button("完成") { navigate(.close) }.disabled(operation.busy)
                    if needsSave {
                        Button("保存代理链") { Task { await save() } }.modifier(TezPrimaryActionStyle())
                            .disabled(payload == nil || validation != nil || active || operation.busy || !store.supports("native_save_proxy_chain"))
                            .accessibilityIdentifier("proxy.chain.save")
                    } else {
                        Button(active ? "停用代理链" : "启用代理链") {
                            pending = active ? "native_deactivate_proxy_chain" : "native_activate_proxy_chain"
                        }.modifier(TezPrimaryActionStyle())
                            .disabled(operation.busy || (!active && validation != nil) || !store.supports(active ? "native_deactivate_proxy_chain" : "native_activate_proxy_chain"))
                            .accessibilityIdentifier("proxy.chain.activate")
                    }
                }
            }.padding(16)
        }.frame(width: 680, height: 650).task { if payload == nil { await load() } }
        .onChange(of: draft) { _, _ in if dirty { operation.message = nil } }
        .interactiveDismissDisabled(dirty || operation.busy)
        .onExitCommand { if !operation.busy { navigate(.close) } }
        .confirmationDialog("放弃未保存的代理链？", isPresented: Binding(get: { navigation != nil }, set: { if !$0 { navigation = nil } }), titleVisibility: .visible) {
            if let destination = navigation {
                Button("放弃更改", role: .destructive) { navigation = nil; move(to: destination) }
            }
            Button("继续编辑", role: .cancel) { navigation = nil }
        } message: { Text("“\(draft.name)”尚未保存。当前运行的代理链不会改变。") }
        .confirmationDialog(pending == "native_delete_proxy_chain" ? "删除“\(draft.name)”？" : pending == "native_activate_proxy_chain" ? "启用“\(draft.name)”？" : "停用“\(draft.name)”？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let command = pending {
                Button(command == "native_delete_proxy_chain" ? "删除代理链" : command == "native_activate_proxy_chain" ? "启用代理链" : "停用代理链", role: .destructive) { Task {
                    pending = nil
                    let params: [String: BackendJSON] = command == "native_deactivate_proxy_chain" ? [:] : ["id": .string(draft.id)]
                    guard let result = await operation.request(store, command, params, refresh: true) else { return }
                    await load()
                    if case .object(let fields) = result, fields["persisted"] == .bool(false) { operation.error = "运行改动已应用，但保存记录失败。请重新读取确认。" }
                    else if case .object(let fields) = result, fields["selectionRestored"] == .bool(false) { operation.error = "链路已移除，但原线路选择未恢复。请在线路页确认。" }
                    else { operation.message = "代理链状态已更新" }
                } }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text(pending == "native_delete_proxy_chain" ? "删除保存记录及当前未保存的更改。此操作无法撤销。" : "策略组：\(draft.group)。代理链会修改节点拨号关系和策略组选择，可能影响使用这些节点的其他连接。") }
    }
    private func load() async {
        guard store.supports("native_get_proxy_chains"), let result = await operation.request(store, "native_get_proxy_chains") else { return }
        do {
            payload = try result.decoded(NativeProxyChainPayload.self)
            draft = payload?.chains.first(where: { $0.id == draft.id }) ?? payload?.chains.first ?? NativeProxyChain(group: payload?.groups.first ?? "")
            baseline = draft; node = ""
        } catch { operation.error = NativeFeatureError.message(error) }
    }
    private func save() async {
        do {
            let value = try JSONDecoder().decode(BackendJSON.self, from: JSONEncoder().encode(draft))
            guard await operation.request(store, "native_save_proxy_chain", ["chain": value]) != nil else { return }
            await load(); operation.message = "代理链已保存"
        } catch { operation.error = NativeFeatureError.message(error) }
    }
}
