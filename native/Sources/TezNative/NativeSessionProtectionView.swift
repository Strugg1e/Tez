import SwiftUI

struct NativeProtectionControl: Decodable, Equatable {
    let generation: UInt64
    let pid: UInt32?
    let started_at: UInt64?
    var protectionSupported: Bool? = nil
    var enabled: Bool? = nil

    var identity: BackendJSON? {
        guard let pid, let started_at else { return nil }
        return .object(["generation": .unsigned(generation), "pid": .unsigned(UInt64(pid)), "started_at": .unsigned(started_at)])
    }
}

struct NativeSessionProtectionView: View {
    let store: NativeBackendStore
    let coreState: String
    @State private var control: NativeProtectionControl?
    @State private var operation = NativeFeatureOperation()
    @State private var readFailed = false
    @State private var pending: Change?

    private struct Change: Identifiable {
        let id = UUID()
        let enabled: Bool
        let identity: BackendJSON
    }

    private var canRead: Bool {
        store.state == .connected && !store.isReadOnlyConnection && coreState == "ready" && store.supports("native_get_core_control")
    }
    private var canChange: Bool {
        canRead && !readFailed && control?.identity != nil && control?.enabled != nil && control?.protectionSupported == true
            && store.supports("native_set_session_protection") && !operation.busy && !store.workspaceBusy
    }
    private var detail: String {
        if store.isReadOnlyConnection { return "只读连接；仅适用于 Tez 自有内核。" }
        if store.state != .connected { return "后台未连接，当前保护状态未确认。" }
        if coreState != "ready" { return "未运行自有内核；新会话默认关闭。" }
        if readFailed { return "状态读取失败，暂不允许切换。" }
        if control?.protectionSupported == false { return "停止自有内核后，在高级维护中更新后台服务，再重新打开 Tez。" }
        if control?.protectionSupported == true && !store.supports("native_set_session_protection") {
            return "后台服务已支持保护模式；重新打开 Tez 后可切换。"
        }
        guard let enabled = control?.enabled else { return "正在读取当前内核状态…" }
        return enabled ? "本次内核会话已开启；升级内核前请先关闭。" : "本次会话未开启；开启和关闭都会重启内核。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TezSettingRow(title: "会话保护", detail: detail) {
                Toggle("会话保护，仅本次内核会话", isOn: Binding(get: { control?.enabled == true }, set: { enabled in
                    guard canChange, let identity = control?.identity else { return }
                    pending = Change(enabled: enabled, identity: identity)
                }))
                .labelsHidden().toggleStyle(.switch).disabled(!canChange)
                .accessibilityLabel("会话保护，仅本次内核会话")
                .accessibilityIdentifier("live.core.protection.toggle")
            }
            Text("减少进程名称与启动参数中的内核关键字，不隐藏网络行为。")
                .font(TezType.metadata).foregroundStyle(.secondary)
            if operation.busy {
                ProgressView("等待内核重启与状态确认…").controlSize(.small).font(TezType.metadata)
            } else if let error = operation.error {
                TezOperationFeedback(message: "保护模式切换结果未确认，请检查当前状态。", details: error, tone: .error)
            } else if let message = operation.message {
                TezOperationFeedback(message: message, tone: .neutral)
            }
        }
        .alert(item: $pending) { change in
            Alert(title: Text(change.enabled ? "开启本次会话保护？" : "关闭本次会话保护？"),
                  message: Text(change.enabled
                    ? "将重启 Tez 自有内核，当前连接会中断。仅本次内核会话有效，不保存偏好，不修改原始内核文件。"
                    : "将切回原内核并重启，当前连接会中断。确认后清理本次会话的临时副本。"),
                  primaryButton: .destructive(Text(change.enabled ? "重启并开启" : "重启并关闭")) { apply(change) },
                  secondaryButton: .cancel(Text("取消")))
        }
        .task(id: "\(store.state)-\(coreState)") {
            if !canRead { control = nil; readFailed = false; return }
            while !Task.isCancelled && canRead {
                if !operation.busy && !store.workspaceBusy { await read() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    @MainActor private func read() async {
        do {
            let value = try await store.request("native_get_core_control")
            guard !Task.isCancelled, canRead else { return }
            control = try value.decoded(NativeProtectionControl.self)
            readFailed = false
        } catch {
            if !Task.isCancelled { readFailed = true }
        }
    }

    private func apply(_ change: Change) {
        guard canChange else { return }
        Task { @MainActor in
            let value = await operation.request(store, "native_set_session_protection", [
                "confirmed": .bool(true), "enabled": .bool(change.enabled), "expected": change.identity
            ], refresh: true)
            if let value {
                do {
                    control = try value.decoded(NativeProtectionControl.self)
                    control?.protectionSupported = true
                    guard case .object(let fields) = value, case .string(let outcome) = fields["outcome"],
                          ["changed", "unchanged", "rolled_back"].contains(outcome) else {
                        throw BackendWireError.invalid("Session protection outcome missing")
                    }
                    operation.message = outcome == "rolled_back" ? "切换未完成，已恢复原内核与保护状态。"
                        : control?.enabled == true ? "本次会话保护已开启。" : "本次会话保护已关闭。"
                } catch { operation.error = NativeFeatureError.message(error) }
            }
            await read()
        }
    }
}
