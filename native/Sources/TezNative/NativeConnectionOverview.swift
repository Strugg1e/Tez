import SwiftUI

struct NativeAccessSummary {
    let accessTitle: String
    let modeTitle: String
    let routeTitle: String
    let profileTitle: String
    let accessTone: TezTone

    init(snapshot: NativeSnapshot?, connected: Bool) {
        guard connected, let snapshot else {
            accessTitle = "流量接入未确认"
            modeTitle = "未确认"
            routeTitle = "连接后台后读取"
            profileTitle = "未确认"
            accessTone = .neutral
            return
        }
        let system = snapshot.network?.systemProxyControl
        let tun = snapshot.network?.tun
        let systemOn = system?.state == "ready" ? system?.enabled : nil
        let tunOn = tun?.state == "ready" ? tun?.enabled : nil
        switch (systemOn, tunOn) {
        case (true, true): accessTitle = "系统代理与 TUN 已开启"; accessTone = .neutral
        case (true, false): accessTitle = "系统代理已开启"; accessTone = .neutral
        case (false, true): accessTitle = "TUN 已开启"; accessTone = .neutral
        case (false, false): accessTitle = "未开启流量接入"; accessTone = .warning
        case (true, nil): accessTitle = "系统代理已开启 · TUN 未确认"; accessTone = .warning
        case (nil, true): accessTitle = "TUN 已开启 · 系统代理未确认"; accessTone = .warning
        default: accessTitle = "流量接入未确认"; accessTone = .neutral
        }
        modeTitle = snapshot.network?.mode.label ?? "未确认"
        profileTitle = snapshot.profiles.items.first { $0.uid == snapshot.profiles.current }?.name ?? "未指定"
        let mode = snapshot.network?.mode.state == "ready" ? snapshot.network?.mode.value : nil
        switch mode {
        case "direct": routeTitle = "直连，不经过代理节点"
        case "global": routeTitle = snapshot.proxyView?.global?.now.map(TezProxyName.title) ?? "全局代理组尚未返回当前线路"
        case "rule":
            let count = snapshot.proxyView?.groups.count ?? 0
            routeTitle = count > 0 ? "按规则分流 · \(count) 个策略组" : "按规则决定流量去向"
        default: routeTitle = "未确认"
        }
    }
}

struct NativeConnectionOverview: View {
    let summary: NativeAccessSummary
    var openRoutes: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                GridRow { Text("当前配置").foregroundStyle(.secondary); Text(summary.profileTitle) }
                GridRow {
                    Text("流量去向").foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        Text(summary.routeTitle).frame(maxWidth: .infinity, alignment: .leading)
                        if let openRoutes {
                            Button("查看线路", systemImage: "arrow.right", action: openRoutes)
                                .buttonStyle(.link).fixedSize()
                        }
                    }
                }
            }
            .font(TezType.body).textSelection(.enabled)
            Label("连通性尚未验证", systemImage: "questionmark.circle")
                .font(TezType.metadata).foregroundStyle(.secondary)
                .help("接入开关、内核运行状态和节点延迟不能确认应用是否可以访问目标。")
                .accessibilityIdentifier("connection.connectivity.unverified")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
