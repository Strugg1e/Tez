import SwiftUI

extension NativeRecentRoute {
    func isAvailable(in snapshot: NativeSnapshot?) -> Bool {
        guard let snapshot, snapshot.profiles.state == "ready", let profileID,
              snapshot.profiles.current == profileID, let view = snapshot.proxyView,
              let currentGroup = resolvedGroup(in: snapshot),
              ["selector", "urltest", "fallback"].contains(currentGroup.type.lowercased().replacingOccurrences(of: "-", with: "")) else { return false }
        let matches = currentGroup.members.filter { $0.name == name }
        guard matches.count == 1, let member = matches.first else { return false }
        switch member.kind {
        case "node": return member.recordId.flatMap { view.records[$0] } != nil
        case "group": return view.groups.contains { $0.name == name } || view.global?.name == name
        default: return false
        }
    }

    func isCurrent(in snapshot: NativeSnapshot?) -> Bool {
        isAvailable(in: snapshot) && resolvedGroup(in: snapshot)?.now == name
    }

    private func resolvedGroup(in snapshot: NativeSnapshot?) -> NativeProxyGroup? {
        guard let view = snapshot?.proxyView else { return nil }
        return view.groups.first { $0.name == group } ?? (view.global?.name == group ? view.global : nil)
    }
}

struct NativeMenuBarPanel: View {
    let store: NativeBackendStore
    let openWorkspace: () -> Void
    let openRoutes: () -> Void
    let connect: () -> Void
    let quit: () -> Void
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var pending: MenuChange?
    @State private var feedbackTone: TezTone = .neutral
    @State private var feedbackDetails: String?

    private var connected: Bool { store.state == .connected }
    private var busy: Bool { operation.busy || store.workspaceBusy || store.serviceSetupInProgress }
    private var summary: NativeAccessSummary { NativeAccessSummary(snapshot: store.snapshot, connected: connected) }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var recentRoutes: [NativeRecentRoute] { preferences.recentRoutes.filter { $0.isAvailable(in: store.snapshot) } }
    private var canConnect: Bool {
        !store.isReadOnlyConnection && !busy && !store.requiresManagedShutdown
            && (store.state == .disconnected || store.state == .failed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            currentStatus.padding(16)
            Divider()
            accessControls.padding(16)
            Divider()
            recentSelections.padding(.horizontal, 16).padding(.vertical, 12)
            if operation.busy || operation.error != nil || operation.message != nil {
                Divider()
                feedback.padding(16)
            }
            Divider()
            navigation.padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: 340)
        .background { TezContentMaterial(material: .popover) }
        .animation(motion.feedback, value: operation.busy)
        .accessibilityIdentifier("live.menubar.panel")
        .onChange(of: connected) { _, connected in
            if !connected {
                operation.message = nil
                feedbackDetails = nil
            }
        }
        .confirmationDialog(pending?.title ?? "应用改动？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let change = pending {
                Button(change.actionTitle, role: .destructive) { Task { await apply(change) } }
                    .disabled(!canApply(change))
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.warning ?? "此操作会改变流量路径，并可能中断现有连接。")
        }
    }

    private var currentStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "network").font(.system(size: 20)).foregroundStyle(TezStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tez").font(TezType.section)
                    TezStatusLabel(title: summary.accessTitle, tone: summary.accessTone, motion: motion)
                }
                Spacer(minLength: 8)
                if !connected {
                    Button("连接后台", systemImage: "link", action: connect)
                        .labelStyle(.iconOnly).help("连接后台并启动内核")
                        .disabled(!canConnect)
                        .accessibilityIdentifier("live.menubar.connect")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                summaryRow("当前线路", value: summary.routeTitle)
                summaryRow("当前配置", value: summary.profileTitle)
            }
            Text("连通性尚未验证").font(TezType.metadata).foregroundStyle(.secondary)
            if !connected {
                Text(store.errorMessage ?? store.statusText)
                    .font(TezType.metadata).foregroundStyle(store.errorMessage == nil ? Color.secondary : TezTone.warning.color)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle).help(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(TezType.body)
        .accessibilityElement(children: .combine)
    }

    private var accessControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            accessToggle("系统代理", symbol: "network", key: "enable_system_proxy", observed: store.snapshot?.network?.systemProxyControl)
                .help("控制系统代理与 PAC；使用 macOS 代理的应用跟随此设置。")
                .accessibilityIdentifier("live.menubar.system")
            accessToggle("虚拟网卡（TUN）", symbol: "point.3.connected.trianglepath.dotted", key: "enable_tun_mode", observed: store.snapshot?.network?.tun)
                .help("接管范围取决于路由，不代表全部流量。")
                .accessibilityIdentifier("live.menubar.tun")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("分流模式")
                    Spacer()
                    Text(summary.modeTitle).foregroundStyle(.secondary)
                }.font(TezType.body)
                Picker("分流模式", selection: Binding(get: { observedMode }, set: { if $0 != observedMode { pending = .mode($0) } })) {
                    if observedMode.isEmpty { Text("未确认").tag("") }
                    Text("规则").tag("rule")
                    Text("全局").tag("global")
                    Text("直连").tag("direct")
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(!connected || busy || !store.supports("native_set_mode") || observedMode.isEmpty)
                .accessibilityIdentifier("live.menubar.mode")
            }
        }
    }

    private var observedMode: String {
        guard connected, let mode = store.snapshot?.network?.mode, mode.state == "ready",
              let value = mode.value, ["rule", "global", "direct"].contains(value) else { return "" }
        return value
    }

    private func accessToggle(_ title: String, symbol: String, key: String, observed: NativeObservedSwitch?) -> some View {
        Toggle(isOn: Binding(get: { connected && observed?.state == "ready" && observed?.enabled == true }, set: { pending = .access(key: key, title: title, enabled: $0) })) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 4)
                Text(connected ? observed?.label ?? "未确认" : "未确认")
                    .font(TezType.metadata).foregroundStyle(.secondary)
            }
        }
        .font(TezType.body).toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel(title)
        .disabled(!connected || busy || !store.supports("native_patch_settings") || observed?.state != "ready" || observed?.enabled == nil)
    }

    private var recentSelections: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近线路").font(TezType.body.weight(.medium))
                Spacer()
                Button("全部线路", systemImage: "chevron.right", action: openRoutes)
                    .labelStyle(.iconOnly).help("打开全部线路")
                    .accessibilityIdentifier("live.menubar.routes")
            }
            if recentRoutes.isEmpty || !connected {
                Text(!connected ? "连接后台后可查看当前配置的最近线路。" : preferences.recentRoutes.isEmpty ? "暂无已确认的线路选择。" : "当前配置没有可用的最近线路。")
                    .font(TezType.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recentRoutes) { route in
                    Button { pending = .route(route) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: route.isCurrent(in: store.snapshot) ? "checkmark" : "clock.arrow.circlepath")
                                .frame(width: 16).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TezProxyName.title(route.name)).font(TezType.body).lineLimit(1).truncationMode(.middle)
                                Text(TezProxyName.title(route.group)).font(TezType.metadata).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if route.isCurrent(in: store.snapshot) { Text("此组已选").font(TezType.metadata).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle()).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain).disabled(!canApply(.route(route)))
                    .help("\(route.group)：\(route.name)")
                    .accessibilityLabel("\(TezProxyName.title(route.group))，\(TezProxyName.title(route.name))\(route.isCurrent(in: store.snapshot) ? "，此组当前选择" : "")")
                }
            }
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if operation.busy {
                ProgressView("等待后台确认…").controlSize(.small).font(TezType.metadata)
            } else if let error = operation.error {
                TezOperationFeedback(message: "改动结果未确认。", details: error, tone: .error)
            } else if let message = operation.message {
                TezOperationFeedback(message: message, details: feedbackDetails, tone: feedbackTone)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button("打开 Tez", systemImage: "macwindow", action: openWorkspace)
                .accessibilityIdentifier("live.menubar.workspace")
            Spacer(minLength: 8)
            SettingsLink { Label("设置…", systemImage: "gearshape") }
                .labelStyle(.iconOnly).help("设置…")
                .accessibilityIdentifier("live.menubar.settings")
            Button("退出 Tez", systemImage: "power", action: quit)
                .labelStyle(.iconOnly).help("安全退出 Tez")
                .accessibilityIdentifier("live.menubar.quit")
        }
        .controlSize(.small)
    }

    private func canApply(_ change: MenuChange) -> Bool {
        guard connected, !busy, store.supports(change.command) else { return false }
        switch change {
        case .access(let key, _, let enabled):
            let observed = key == "enable_system_proxy" ? store.snapshot?.network?.systemProxyControl : store.snapshot?.network?.tun
            return observed?.state == "ready" && observed?.enabled != nil && observed?.enabled != enabled
        case .mode(let value): return !observedMode.isEmpty && ["rule", "global", "direct"].contains(value) && observedMode != value
        case .route(let route): return store.snapshot?.core.state == "ready" && route.isAvailable(in: store.snapshot) && !route.isCurrent(in: store.snapshot)
        }
    }

    @MainActor
    private func apply(_ change: MenuChange) async {
        pending = nil
        guard canApply(change) else {
            operation.error = "当前状态已变化。请检查当前设置；未发送改动。"
            return
        }
        feedbackDetails = nil
        guard let result = await operation.request(store, change.command, change.params, refresh: true) else { return }
        guard case .object(let fields) = result else {
            operation.error = "后台返回格式无效。执行结果未确认；不会自动重试。"
            return
        }
        if case .route(let route) = change {
            guard case .bool(let applied) = fields["applied"], case .bool(let persisted) = fields["persisted"] else {
                operation.error = "后台未确认线路切换结果；不会自动重试。\n\(render(result))"
                return
            }
            let cleanupIncomplete: Bool
            if case .object(let cleanup) = fields["connectionCleanup"] {
                cleanupIncomplete = cleanup["requested"] == .bool(true) && cleanup["completed"] != .bool(true)
            } else { cleanupIncomplete = false }
            if applied { preferences.recordRoute(profileID: route.profileID, group: route.group, name: route.name) }
            feedbackTone = !applied ? .error : persisted && !cleanupIncomplete ? .success : .warning
            if !applied {
                operation.message = "线路未切换。请检查当前线路。"
            } else if !persisted && cleanupIncomplete {
                operation.message = "线路已切换；选择保存与旧连接清理未完成。"
            } else if !persisted {
                operation.message = "线路已切换，但选择未保存。"
            } else if cleanupIncomplete {
                operation.message = "线路已切换并保存；部分旧连接未关闭。"
            } else {
                operation.message = "已切换到 \(TezProxyName.title(route.name))，选择已保存。"
            }
            feedbackDetails = persisted && applied && !cleanupIncomplete ? nil : render(result)
        } else {
            let key = change.command == "native_set_mode" ? "applied" : "saved"
            guard fields[key] == .bool(true) else {
                operation.error = "后台未确认目标设置。请检查当前状态；不会自动重试。\n\(render(result))"
                return
            }
            feedbackTone = .success
            operation.message = change.command == "native_set_mode" ? "\(change.actionTitle)：后台已确认。" : "\(change.actionTitle)：设置已保存。"
        }
    }

    private func render(_ value: BackendJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
    }

    private enum MenuChange {
        case access(key: String, title: String, enabled: Bool)
        case mode(String)
        case route(NativeRecentRoute)

        var actionTitle: String {
            switch self {
            case .access(_, let title, let enabled): "\(enabled ? "开启" : "关闭")\(title)"
            case .mode(let value): "使用\(NativeObservedMode(state: "ready", value: value).label)模式"
            case .route(let route): "切换到 \(TezProxyName.title(route.name))"
            }
        }
        var title: String { "\(actionTitle)？" }
        var warning: String {
            switch self {
            case .access(let key, _, let enabled):
                if key == "enable_system_proxy" {
                    return "目标状态：系统代理\(enabled ? "开启" : "关闭")。\(enabled ? "使用 macOS 代理的应用将跟随代理设置。" : "系统代理与 PAC 将关闭。")此操作会改变流量路径，并可能中断现有连接。"
                }
                return "目标状态：TUN \(enabled ? "开启" : "关闭")。接管范围取决于路由。此操作会改变流量路径，并可能中断现有连接。"
            case .mode(let value):
                let effect = value == "direct" ? "流量将直接连接目标。" : value == "global" ? "代理流量将使用全局策略组。" : "流量将按当前配置中的规则分流。"
                return "目标模式：\(NativeObservedMode(state: "ready", value: value).label)。\(effect)此操作可能中断现有连接。"
            case .route(let route):
                return "分组：\(TezProxyName.title(route.group))。目标线路：\(TezProxyName.title(route.name))。此操作会改变流量路径，并可能中断现有连接。"
            }
        }
        var command: String {
            switch self { case .access: "native_patch_settings"; case .mode: "native_set_mode"; case .route: "native_select_route" }
        }
        var params: [String: BackendJSON] {
            switch self {
            case .access(let key, _, let enabled): ["values": .object([key: .bool(enabled)])]
            case .mode(let value): ["mode": .string(value)]
            case .route(let route): ["group": .string(route.group), "name": .string(route.name)]
            }
        }
    }
}
