import AppKit
import SwiftUI

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case connection, routes, profiles, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: "连接"
        case .routes: "线路"
        case .profiles: "配置"
        case .activity: "活动"
        }
    }

    var symbol: String {
        switch self {
        case .connection: "network"
        case .routes: "point.3.connected.trianglepath.dotted"
        case .profiles: "doc.text"
        case .activity: "waveform.path"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .connection: "1"
        case .routes: "2"
        case .profiles: "3"
        case .activity: "4"
        }
    }
}

struct WorkspaceView: View {
    @Binding var selection: WorkspaceSection?
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var routes = TezRoutesSession()
    @State private var connected = false
    @State private var policy = "规则分流"
    @State private var profileSelection: String? = "daily"
    @State private var activitySearch = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    TezBrandMark()
                        .frame(width: 34, height: 34)
                    Text("Tez")
                        .font(.system(size: 24, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 20)
                .accessibilityElement(children: .combine)

                List(WorkspaceSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.symbol)
                        .font(.system(size: 13, weight: selection == section ? .semibold : .regular))
                        .tag(section)
                        .padding(.vertical, 5)
                        .accessibilityIdentifier("sidebar.\(section.rawValue)")
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .tint(TezStyle.accent)

                sidebarFooter
            }
            .background {
                // NavigationSplitView already owns the sidebar material and vibrancy.
                if preferences.reduceTransparency || systemReduceTransparency || preferences.increaseContrast || contrast == .increased {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
        } detail: {
            Group {
                switch selection ?? .routes {
                case .connection:
                    ConnectionPreviewView(
                        routes: routes,
                        connected: $connected,
                        policy: $policy,
                        openRoutes: { selection = .routes }
                    )
                case .routes:
                    RoutesView(session: routes)
                case .profiles:
                    ProfilesPreviewView(selection: $profileSelection)
                case .activity:
                    ActivityPreviewView(search: $activitySearch)
                }
            }
            .navigationTitle((selection ?? .routes).title)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.bar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(TezWindowSurface())
        .tint(TezStyle.accent)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("当前线路", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(routes.activeRouteName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .help(routes.activeRouteName)
            Text("预览 · 示例数据")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            HStack {
                SettingsLink {
                    Label("设置", systemImage: "slider.horizontal.3")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("设置（⌘,）")
                Spacer()
                Text("⌘ ,")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 21)
        .padding(.bottom, 20)
        .padding(.top, 16)
    }
}

private struct ConnectionPreviewView: View {
    let routes: TezRoutesSession
    @Binding var connected: Bool
    @Binding var policy: String
    let openRoutes: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(TezPreviewPreferences.self) private var preferences

    private var reduceMotion: Bool { systemReduceMotion || preferences.reduceMotion }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 16) {
                    TezBrandMark()
                        .foregroundStyle(connected ? TezStyle.accent : Color.secondary)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(connected ? "连接演示中" : "未连接")
                            .font(.system(size: 25, weight: .semibold))
                        Text("未接管系统网络")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(connected ? "断开演示" : "连接演示") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            connected.toggle()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("connection.toggle")
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("当前配置")
                        .font(.headline)
                        .padding(.bottom, 12)
                    Divider()
                    connectionRow("配置", value: "日常网络 · 示例")
                    Divider()
                    HStack {
                        Text("代理线路")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(action: openRoutes) {
                            HStack(spacing: 6) {
                                Text(routes.activeRouteName)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(TezStyle.accent)
                        .help("选择代理线路")
                    }
                    .padding(.vertical, 15)
                    Divider()
                    HStack {
                        Text("分流模式")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("分流模式", selection: $policy) {
                            Text("规则分流").tag("规则分流")
                            Text("全局代理").tag("全局代理")
                            Text("直接连接").tag("直接连接")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.vertical, 12)
                    Divider()
                    connectionRow("网络接管", value: "未启用")
                    Divider()
                }
            }
            .frame(maxWidth: 700)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func connectionRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .padding(.vertical, 15)
    }
}

private struct ProfilesPreviewView: View {
    @Binding var selection: String?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                profileRow("日常网络", subtitle: "订阅 · 示例", symbol: "arrow.triangle.2.circlepath")
                    .tag("daily")
                profileRow("本地配置", subtitle: "YAML · 示例", symbol: "doc.text")
                    .tag("local")
            }
            .listStyle(.inset)
            .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)

            Form {
                Section("配置详情") {
                    LabeledContent("名称", value: selection == "local" ? "本地配置" : "日常网络")
                    LabeledContent("来源", value: selection == "local" ? "本地文件" : "订阅")
                    LabeledContent("状态", value: "示例，未应用")
                }
                Section("更新") {
                    LabeledContent("自动更新", value: "暂停")
                    LabeledContent("上次更新", value: "未更新")
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func profileRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(TezStyle.accent)
                .frame(width: 23)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct ActivityPreviewView: View {
    @Binding var search: String
    private let events = [
        PreviewEvent(time: "10:42:18", level: "信息", message: "配置载入完成", symbol: "doc.badge.checkmark"),
        PreviewEvent(time: "10:42:18", level: "信息", message: "策略组选择东京 01", symbol: "point.3.connected.trianglepath.dotted"),
        PreviewEvent(time: "10:42:17", level: "提示", message: "增强脚本等待确认", symbol: "exclamationmark.circle")
    ]

    private var filteredEvents: [PreviewEvent] {
        events.filter { search.isEmpty || $0.message.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Table(filteredEvents) {
            TableColumn("时间") { event in
                Text(event.time).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(86)
            TableColumn("级别") { event in
                Text(event.level).foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("事件") { event in
                Label(event.message, systemImage: event.symbol)
                    .padding(.vertical, 6)
            }
        }
        .overlay {
            if filteredEvents.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索示例事件")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("静态示例记录")
                Spacer()
                Text("\(filteredEvents.count) 条事件")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct PreviewEvent: Identifiable {
    let time: String
    let level: String
    let message: String
    let symbol: String
    var id: String { message }
}
