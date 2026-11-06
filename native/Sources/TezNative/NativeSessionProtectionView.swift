import SwiftUI

struct NativeTransportReport: Decodable, Equatable {
    struct Node: Decodable, Equatable {
        let name: String
        let `protocol`: String
        let status: String
    }
    struct DNS: Decodable, Equatable {
        let enabled: Bool
        let encryptedResolvers: Int
        let otherResolvers: Int
        let followsRules: Bool
        let nodeResolverConfigured: Bool
    }
    let nodes: [Node]
    let dynamicProviders: Int
    let dns: DNS
    var eligible: Int { nodes.filter { $0.status == "eligible" }.count }
    var existing: Int { nodes.filter { $0.status == "existing" }.count }
    var unsupported: Int { nodes.filter { $0.status == "unsupported" }.count }
    var hasCandidates: Bool { eligible + existing + dynamicProviders > 0 }
}

struct NativeProtectionControl: Decodable, Equatable {
    let generation: UInt64
    let pid: UInt32?
    let started_at: UInt64?
    var protectionSupported: Bool? = nil
    var enabled: Bool? = nil
    var transportSupported: Bool? = nil
    var transportEnabled: Bool? = nil
    var transportReport: NativeTransportReport? = nil

    var identity: BackendJSON? {
        guard let pid, let started_at else { return nil }
        return .object(["generation": .unsigned(generation), "pid": .unsigned(UInt64(pid)), "started_at": .unsigned(started_at)])
    }
}

struct NativeSessionProtectionView: View {
    private static let processHelp = "以临时签名副本运行 Tez 自有内核，减少进程名称和启动参数中的内核关键字。不修改原内核文件，不改变网络协议。仅本次内核会话有效。"
    private static let transportHelp = "订阅兼容版：为未指定握手指纹的兼容 TLS 节点使用 Chrome 风格握手，保留已有设置。DNS 仅做配置检查，不自动修改 DNS 或 TUN。仅本次内核会话有效；应用更改会重启内核并中断连接。"
    let store: NativeBackendStore
    let coreState: String
    @State private var control: NativeProtectionControl?
    @State private var operation = NativeFeatureOperation()
    @State private var readFailed = false
    @State private var processDraft = false
    @State private var transportDraft = false
    @State private var pending: Change?

    private struct Change: Identifiable {
        let id = UUID()
        let process: Bool
        let transport: Bool
        let identity: BackendJSON
    }

    private var canRead: Bool {
        store.state == .connected && !store.isReadOnlyConnection && coreState == "ready" && store.supports("native_get_core_control")
    }
    private var canChange: Bool {
        canRead && !readFailed && control?.identity != nil && control?.enabled != nil && control?.protectionSupported == true
            && store.supports("native_set_session_protection") && !operation.busy && !store.workspaceBusy
    }
    private var transportSupported: Bool {
        control?.transportSupported == true && store.supports("native_set_runtime_protection")
    }
    private var dirty: Bool {
        processDraft != (control?.enabled == true) || transportDraft != (control?.transportEnabled == true)
    }
    private var detail: String {
        if store.isReadOnlyConnection { return "只读连接；仅适用于 Tez 自有内核。" }
        if store.state != .connected { return "后台未连接，当前保护状态未确认。" }
        if coreState != "ready" { return "未运行自有内核；新会话默认关闭。" }
        if readFailed { return "状态读取失败，暂不允许切换。" }
        if control?.protectionSupported == false { return "停止自有内核后，在高级维护中更新后台服务，再点击启动。" }
        if control?.protectionSupported == true && !store.supports("native_set_session_protection") {
            return "后台服务已支持保护模式；重新打开 Tez 后可切换。"
        }
        guard let enabled = control?.enabled else { return "正在读取当前内核状态…" }
        return enabled ? "当前已开启；减少进程名称与启动参数中的内核关键字。" : "当前未开启；减少进程名称与启动参数中的内核关键字。"
    }
    private var transportDetail: String {
        guard canRead else { return "仅适用于 Tez 自有内核。" }
        guard let control else { return "正在读取节点能力…" }
        if !transportSupported { return "更新后台服务并重新打开 Tez 后可用。" }
        if readFailed { return "节点能力读取失败，暂不允许切换。" }
        if control.transportReport?.hasCandidates == false { return "当前配置没有兼容的 TLS 节点；未覆盖的节点保持原行为。" }
        return control.transportEnabled == true ? "当前已开启；兼容节点补充 Chrome TLS 握手特征，已有设置保持不变。"
            : "当前未开启；仅对未指定握手特征的兼容 TLS 节点生效。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TezSettingRow(title: "本机保护", detail: detail) {
                Toggle("本机保护，仅本次内核会话", isOn: $processDraft)
                    .labelsHidden().toggleStyle(.switch).disabled(!canChange)
                    .accessibilityLabel("本机保护，仅本次内核会话")
                    .accessibilityIdentifier("live.core.protection.toggle")
                    .help(Self.processHelp)
            }
            .help(Self.processHelp)
            TezSettingRow(title: "传输保护", detail: transportDetail) {
                Toggle("传输保护，仅本次内核会话", isOn: $transportDraft)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!canChange || !transportSupported || (!transportDraft && control?.transportReport?.hasCandidates != true))
                    .accessibilityLabel("传输保护，仅本次内核会话")
                    .accessibilityIdentifier("live.core.protection.transport.toggle")
                    .help(Self.transportHelp)
            }
            .help(Self.transportHelp)
            Text("两项独立生效；停止内核后关闭，不保存偏好。应用更改会重启内核并中断连接。更新内核前请关闭两项保护。")
                .font(TezType.metadata).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let report = control?.transportReport, transportSupported { coverage(report) }
            if dirty && !operation.busy {
                ViewThatFits(in: .horizontal) {
                    HStack { Text("有尚未应用的更改").font(TezType.metadata).foregroundStyle(.secondary); Spacer(); actions }
                    VStack(alignment: .leading, spacing: 8) { Text("有尚未应用的更改").font(TezType.metadata).foregroundStyle(.secondary); actions }
                }
            }
            if operation.busy {
                ProgressView("等待内核重启与状态确认…").controlSize(.small).font(TezType.metadata)
            } else if let error = operation.error {
                TezOperationFeedback(message: "保护设置应用结果未确认，请检查当前状态。", details: error, tone: .error)
            } else if let message = operation.message {
                TezOperationFeedback(message: message, tone: .neutral)
            }
        }
        .alert(item: $pending) { change in
            Alert(title: Text("应用本次保护设置？"),
                  message: Text("本机保护：\(change.process ? "开启" : "关闭")\n传输保护：\(change.transport ? "开启" : "关闭")\n\n将重启 Tez 自有内核，当前连接会中断。不修改原文件、DNS 或 TUN 设置。"),
                  primaryButton: .destructive(Text("重启并应用")) { apply(change) },
                  secondaryButton: .cancel(Text("取消")))
        }
        .task(id: "\(store.state)-\(coreState)") {
            if !canRead { control = nil; readFailed = false; processDraft = false; transportDraft = false; return }
            while !Task.isCancelled && canRead {
                if !operation.busy && !store.workspaceBusy { await read() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("还原") { syncDraft() }.disabled(!canChange)
            Button("应用本次更改") {
                guard let identity = control?.identity else { return }
                pending = Change(process: processDraft, transport: transportDraft, identity: identity)
            }
            .buttonStyle(.borderedProminent).disabled(!canChange)
            .accessibilityIdentifier("live.core.protection.apply")
        }.fixedSize()
    }

    private func coverage(_ report: NativeTransportReport) -> some View {
        DisclosureGroup("节点覆盖与 DNS 检查") {
            VStack(alignment: .leading, spacing: 8) {
                Text("可增强 \(report.eligible) · 保留原设置 \(report.existing) · 未覆盖 \(report.unsupported)")
                if report.dynamicProviders > 0 {
                    Text("\(report.dynamicProviders) 个订阅分组的节点未逐项确认；加载时仅为兼容节点补充握手特征。")
                }
                ForEach(Array(report.nodes.enumerated()), id: \.offset) { _, node in
                    HStack(alignment: .firstTextBaseline) {
                        Text(node.name).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 12)
                        Text(node.status == "eligible" ? (control?.transportEnabled == true ? "增强中" : "可增强")
                            : node.status == "existing" ? "保留原设置" : "未覆盖")
                            .foregroundStyle(.secondary).fixedSize()
                    }
                }
                Divider()
                Text(report.dns.enabled ? "内核 DNS 已启用：加密解析项 \(report.dns.encryptedResolvers)，其他解析项 \(report.dns.otherResolvers)。"
                    : "内核 DNS 未启用；系统与应用的 DNS 不在本次检查范围。")
                if report.dns.enabled && !report.dns.followsRules { Text("DNS 未设置遵循分流规则；本次不自动修改。") }
                if report.dns.enabled && !report.dns.nodeResolverConfigured { Text("未单独指定节点域名解析；本次不自动修改。") }
                Text("检查范围：内核 DNS 配置。实际 DNS 出口、系统和应用的解析路径未检测。")
                    .foregroundStyle(.secondary)
            }.font(TezType.metadata).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
        }
        .font(TezType.metadata)
        .accessibilityIdentifier("live.core.protection.coverage")
    }

    private func syncDraft() {
        processDraft = control?.enabled == true
        transportDraft = control?.transportEnabled == true
    }

    @MainActor private func read() async {
        do {
            let value = try await store.request("native_get_core_control")
            guard !Task.isCancelled, canRead else { return }
            let keepDraft = dirty && control != nil
            control = try value.decoded(NativeProtectionControl.self)
            if !keepDraft { syncDraft() }
            readFailed = false
        } catch {
            if !Task.isCancelled { readFailed = true }
        }
    }

    private func apply(_ change: Change) {
        guard canChange else { return }
        Task { @MainActor in
            let combined = transportSupported
            let command = combined ? "native_set_runtime_protection" : "native_set_session_protection"
            var params: [String: BackendJSON] = ["confirmed": .bool(true), "expected": change.identity]
            if combined {
                params["processEnabled"] = .bool(change.process)
                params["transportEnabled"] = .bool(change.transport)
            } else { params["enabled"] = .bool(change.process) }
            let value = await operation.request(store, command, params, refresh: true)
            if let value {
                do {
                    control = try value.decoded(NativeProtectionControl.self)
                    control?.protectionSupported = true
                    syncDraft()
                    guard case .object(let fields) = value, case .string(let outcome) = fields["outcome"],
                          ["changed", "unchanged", "rolled_back"].contains(outcome) else {
                        throw BackendWireError.invalid("Runtime protection outcome missing")
                    }
                    operation.message = outcome == "rolled_back" ? "更改未完成，已恢复原内核与保护设置。" : "本次保护设置已应用。"
                } catch { operation.error = NativeFeatureError.message(error) }
            }
            await read()
        }
    }
}
