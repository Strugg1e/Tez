import SwiftUI

struct NativePendingChange: Identifiable, Equatable {
    enum Scope: Equatable { case proxy, mode }

    let id: String
    let scope: Scope
    let title: String
    let previousValue: String
    let proposedValue: String
    let affectsTraffic: Bool
}

enum NativeNetworkPendingChanges {
    private struct Field: Sendable {
        let key: String
        let title: String
        let fallback: BackendJSON
        var affectsTraffic = true
    }

    private static let fields: [Field] = [
        Field(key: "enable_system_proxy", title: "系统代理", fallback: .bool(false)),
        Field(key: "enable_tun_mode", title: "虚拟网卡（TUN）", fallback: .bool(false)),
        Field(key: "verge_mixed_port", title: "混合代理端口", fallback: .integer(7897)),
        Field(key: "verge_http_enabled", title: "独立 HTTP 端口", fallback: .bool(false)),
        Field(key: "verge_port", title: "HTTP 端口", fallback: .integer(7899)),
        Field(key: "verge_socks_enabled", title: "独立 SOCKS 端口", fallback: .bool(false)),
        Field(key: "verge_socks_port", title: "SOCKS 端口", fallback: .integer(7898)),
        Field(key: "proxy_host", title: "代理主机", fallback: .string("127.0.0.1")),
        Field(key: "use_default_bypass", title: "使用默认绕过列表", fallback: .bool(false)),
        Field(key: "enable_bypass_check", title: "检查绕过列表", fallback: .bool(false)),
        Field(key: "proxy_auto_config", title: "自动代理（PAC）", fallback: .bool(false)),
        Field(key: "enable_proxy_guard", title: "保持系统代理", fallback: .bool(false)),
        Field(key: "proxy_guard_duration", title: "代理保持间隔", fallback: .integer(30)),
        Field(key: "auto_close_connection", title: "切换模式或线路时关闭已有连接", fallback: .bool(false)),
        Field(key: "pac_file_content", title: "PAC 脚本", fallback: .string("function FindProxyForURL(url, host) { return \"PROXY %proxy_host%:%mixed-port%; SOCKS5 %proxy_host%:%mixed-port%; DIRECT;\"; }")),
        Field(key: "system_proxy_bypass", title: "不经过系统代理的地址", fallback: .string("")),
        Field(key: "default_latency_test", title: "测速地址", fallback: .string("https://www.gstatic.com/generate_204"), affectsTraffic: false),
        Field(key: "default_latency_timeout", title: "测速超时", fallback: .integer(5000), affectsTraffic: false),
        Field(key: "app_log_level", title: "应用日志级别", fallback: .string("info"), affectsTraffic: false)
    ]

    static func make(values: [String: BackendJSON], original: [String: BackendJSON],
                     mode: String, originalMode: String) -> [NativePendingChange] {
        let changes = values.filter { original[$0.key] != $0.value }
        let knownKeys = Set(fields.map(\.key))
        let orderedKeys = fields.map(\.key).filter { changes[$0] != nil }
            + changes.keys.filter { !knownKeys.contains($0) }.sorted()
        var items = orderedKeys.map { key in
            let field = fields.first { $0.key == key }
            return NativePendingChange(id: key, scope: .proxy, title: field?.title ?? key,
                                       previousValue: displayValue(original[key], key: key),
                                       proposedValue: displayValue(values[key], key: key),
                                       affectsTraffic: field?.affectsTraffic ?? true)
        }
        if mode != originalMode {
            items.insert(NativePendingChange(id: "mode", scope: .mode, title: "分流模式",
                                             previousValue: modeTitle(originalMode), proposedValue: modeTitle(mode),
                                             affectsTraffic: true), at: 0)
        }
        return items
    }

    static func displayValue(_ value: BackendJSON?, key: String) -> String {
        let fallback = fields.first { $0.key == key }?.fallback ?? .null
        let value = value == .null ? fallback : (value ?? fallback)
        if key == "pac_file_content", case .string(let content) = value {
            return content.isEmpty ? "空脚本" : "脚本（\(content.count) 字符）"
        }
        if key == "system_proxy_bypass", case .string(let content) = value {
            let count = content.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            return count == 0 ? "未设置" : "\(count) 个地址"
        }
        if key == "app_log_level", case .string(let level) = value { return logTitle(level) }
        if key == "default_latency_test", case .string(let address) = value {
            guard var url = URLComponents(string: address), url.host != nil else { return "无效地址" }
            url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
            return url.string ?? "已设置地址"
        }
        let text: String
        switch value {
        case .bool(let enabled): text = enabled ? "开启" : "关闭"
        case .string(let content): text = content.isEmpty ? "未设置" : content
        case .integer(let number): text = String(number)
        case .unsigned(let number): text = String(number)
        case .number(let number): text = String(number)
        case .null: text = "未设置"
        case .array(let items): text = "\(items.count) 项"
        case .object(let items): text = "\(items.count) 项设置"
        }
        if key == "proxy_guard_duration" { return "\(text) 秒" }
        if key == "default_latency_timeout" { return "\(text) 毫秒" }
        return text
    }

    static func modeTitle(_ value: String) -> String {
        switch value { case "rule": "规则"; case "global": "全局"; case "direct": "直连"; default: "未确认" }
    }

    static func logTitle(_ value: String) -> String {
        switch value { case "silent": "不记录"; case "error": "错误"; case "warn": "警告"; case "debug": "调试"; case "trace": "跟踪"; default: "常规" }
    }
}

struct NativePendingChangesList: View {
    let changes: [NativePendingChange]
    var locate: ((String) -> Void)? = nil
    @State private var contentHeight: CGFloat = 44

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(changes) { change in
                    Group {
                        if let locate {
                            Button { locate(change.id) } label: { changeRow(change) }
                                .buttonStyle(.plain)
                                .help("定位到\(change.title)")
                        } else {
                            changeRow(change)
                        }
                    }
                    .accessibilityIdentifier("network.pending.\(change.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 44), 160))
        .accessibilityIdentifier("network.pending.list")
    }

    private func changeRow(_ change: NativePendingChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(change.title).font(TezType.body.weight(.medium))
                            if change.affectsTraffic {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(TezType.metadata).foregroundStyle(TezStyle.warning)
                                    .accessibilityLabel("影响流量")
                            }
                            Spacer(minLength: 4)
                            if locate != nil {
                                Image(systemName: "scope").foregroundStyle(.secondary).accessibilityLabel("定位字段")
                            }
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Text("原值：\(change.previousValue)")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text("待应用：\(change.proposedValue)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(TezType.metadata)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
    }
}
