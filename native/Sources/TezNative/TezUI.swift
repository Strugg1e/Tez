import SwiftUI

enum TezTone {
    case neutral, success, warning, error

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .success: TezStyle.success
        case .warning: TezStyle.warning
        case .error: Color(nsColor: .systemRed)
        }
    }

    var symbol: String {
        switch self {
        case .neutral: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

struct TezMotion {
    let reduced: Bool
    var feedback: Animation? { reduced ? nil : .easeOut(duration: 0.16) }
    var layout: Animation? { reduced ? nil : .spring(duration: 0.22, bounce: 0) }
    var symbol: ContentTransition { reduced ? .identity : .symbolEffect(.replace) }
}

struct TezSearchField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String
    var surface = Color(nsColor: .controlBackgroundColor)

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).accessibilityIdentifier(identifier)
            Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("清除搜索").accessibilityLabel("清除搜索")
                .opacity(text.isEmpty ? 0 : 1).disabled(text.isEmpty)
                .accessibilityHidden(text.isEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).frame(height: 30)
        .background(surface, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct TezToolButton: View {
    let title: String
    let symbol: String
    var enabled = true
    var motion = TezMotion(reduced: true)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 14, height: 14)
                .contentTransition(motion.symbol)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help(title).accessibilityLabel(title).disabled(!enabled)
        .animation(motion.feedback, value: symbol)
    }
}

struct TezMetric: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .secondary
    var motion = TezMotion(reduced: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
            }.font(.system(size: 11))
            Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit()
                .lineLimit(1).contentTransition(motion.reduced ? .identity : .numericText())
                .animation(motion.feedback, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TezUsageMeter: View {
    let used: UInt64
    let total: UInt64
    var motion = TezMotion(reduced: true)

    private var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(NativeActivityFormat.bytes(used)).font(.system(size: 17, weight: .medium)).monospacedDigit()
                Spacer()
                Text("共 \(NativeActivityFormat.bytes(total))").font(.caption).foregroundStyle(.secondary)
            }
            if total > 0 {
                ProgressView(value: fraction)
                    .tint(fraction >= 0.9 ? TezStyle.warning : TezStyle.accent)
                    .animation(motion.feedback, value: fraction)
                    .accessibilityLabel("订阅流量用量")
                    .accessibilityValue("\(NativeActivityFormat.bytes(used)) / \(NativeActivityFormat.bytes(total))")
            }
        }.padding(.vertical, 4)
    }
}

struct TezDetailField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).lineLimit(2)
                .textSelection(.enabled).help(value).contentTransition(.opacity)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TezInspectorHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .lineLimit(2).textSelection(.enabled).help(title).contentTransition(.opacity)
            Spacer(minLength: 0)
            TezToolButton(title: "收起详情", symbol: "xmark", action: close)
        }
    }
}

struct TezEmptyState: View {
    let title: String
    let symbol: String
    var detail: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let detail { Text(detail) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TezProfileRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let current: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .lineLimit(2, reservesSpace: true).help(title)
                Text(subtitle).font(.system(size: 11))
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "checkmark.circle.fill").accessibilityLabel("当前配置")
            }
        }
        .frame(height: 60)
    }
}

// Native table cell hosts do not inherit the workspace's observable preferences.
struct TezStatusLabel: View {
    let title: String
    var tone: TezTone = .neutral
    var symbol: String? = nil
    var motion = TezMotion(reduced: true)
    var inheritsForeground = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            let icon = Image(systemName: symbol ?? tone.symbol).contentTransition(motion.symbol)
            if inheritsForeground { icon } else { icon.foregroundStyle(tone.color) }
        }
        .font(.system(size: 12))
        .animation(motion.feedback, value: title)
        .accessibilityElement(children: .combine)
    }
}

struct TezOperationFeedback: View {
    let message: String
    var details: String? = nil
    var tone: TezTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).foregroundStyle(.primary).textSelection(.enabled)
            } icon: {
                Image(systemName: tone.symbol).foregroundStyle(tone.color)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            if let details {
                DisclosureGroup("技术详情") {
                    ScrollView {
                        Text(details).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TezLatencyValue: View {
    let label: String
    var testing = false
    var failed = false
    var motion = TezMotion(reduced: true)
    var inheritsForeground = false

    var body: some View {
        HStack(spacing: 5) {
            if testing { ProgressView().controlSize(.mini) }
            if inheritsForeground {
                value
            } else {
                value.foregroundStyle(failed ? TezTone.warning.color : Color.secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .animation(motion.feedback, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("延迟：\(label)")
    }

    private var value: some View {
        Text(label).monospacedDigit()
            .contentTransition(motion.reduced ? .identity : .numericText())
    }
}

struct TezConnectionPresentation {
    let state: NativeBackendState
    let hasSnapshot: Bool
    let coreState: String?
    let writable: Bool

    var busy: Bool { state == .connecting || state == .renewing || state == .stopping }
    var title: String {
        switch state {
        case .disconnected: "后台未连接"
        case .connecting: "正在连接后台"
        case .connected: "后台已连接"
        case .renewing: "正在恢复只读连接"
        case .failed: "后台连接失败"
        case .stopping: "正在安全退出后台"
        case .shutdownFailed: "后台退出未确认"
        }
    }
    var tone: TezTone {
        switch state {
        case .connected: .success
        case .failed, .shutdownFailed: .error
        case .renewing: .warning
        default: .neutral
        }
    }
    var context: String {
        if state == .stopping { return "等待内核停止，暂不可重新连接" }
        if state == .shutdownFailed { return "请重试安全退出" }
        if state == .connected { return writable ? "管理访问" : "只读访问" }
        return hasSnapshot ? "离线快照 · 数据不再同步" : "内核与系统代理状态未读取"
    }
    var coreTitle: String {
        guard state == .connected else { return "内核状态未确认" }
        switch coreState {
        case "ready": return "内核运行中"
        case "unavailable": return "内核不可用"
        case "error": return "内核读取失败"
        default: return "内核状态未确认"
        }
    }
    var coreTone: TezTone { state == .connected && coreState == "ready" ? .success : .neutral }
}

struct TezConnectionBar: View {
    let presentation: TezConnectionPresentation
    let error: String?
    let reconnect: () -> Void
    let retryShutdown: () -> Void
    var motion = TezMotion(reduced: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    status
                    Spacer(minLength: 8)
                    context
                    action
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { status; Spacer(minLength: 8); action }
                    context
                }
            }
            if let error {
                DisclosureGroup("查看错误详情") {
                    Text(error).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, TezStyle.pageInset)
        .padding(.vertical, presentation.state == .connected && error == nil ? 6 : 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("live.connection.status")
    }

    private var status: some View {
        HStack(spacing: 8) {
            if presentation.busy { ProgressView().controlSize(.small) }
            TezStatusLabel(title: presentation.title, tone: presentation.tone, motion: motion)
                .fontWeight(.medium).fixedSize()
        }
    }

    private var context: some View {
        HStack(spacing: 12) {
            if presentation.state == .connected {
                TezStatusLabel(title: presentation.coreTitle, tone: presentation.coreTone, symbol: "cpu")
            }
            Text(presentation.context).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        switch presentation.state {
        case .disconnected, .failed:
            Button(presentation.state == .failed ? "重新连接" : "连接后台", systemImage: "link", action: reconnect)
                .accessibilityIdentifier("live.connect")
        case .shutdownFailed:
            Button("重试安全退出", systemImage: "arrow.clockwise", action: retryShutdown)
        default: EmptyView()
        }
    }
}
