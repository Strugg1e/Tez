import AppKit
import SwiftUI

struct LiveWorkspaceView: View {
    @Bindable var store: NativeBackendStore
    @Binding var selection: WorkspaceSection?
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pendingCoreAction: LiveCoreAction?
    @State private var coreBusy = false
    @State private var coreMessage: String?
    @State private var coreDetails: String?

    init(store: NativeBackendStore, selection: Binding<WorkspaceSection?> = .constant(.connection)) {
        self.store = store
        self._selection = selection
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    TezBrandMark().frame(width: 34, height: 34)
                    Text("Tez").font(.system(size: 24, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(20)
                List(WorkspaceSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.symbol)
                        .padding(.vertical, 5)
                        .tag(section)
                        .accessibilityIdentifier("live.sidebar.\(section.rawValue)")
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                VStack(alignment: .leading, spacing: 9) {
                    Label(hasWriteCapability ? "后台连接" : "只读连接", systemImage: hasWriteCapability ? "link" : "eye")
                        .help(hasWriteCapability ? "仅开放后台声明支持的操作。" : "当前后台未开放配置编辑、线路切换和内核控制。")
                    Text(LiveText.state(store.statusText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.vertical, 5)
                    SettingsLink { Label("设置", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(20)
            }
            .background {
                if preferences.reduceTransparency || systemReduceTransparency || preferences.increaseContrast || contrast == .increased {
                    Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                    statusBanner(LiveText.message(error), symbol: "exclamationmark.triangle")
                }
                if store.snapshot != nil && store.state != .connected {
                    statusBanner("离线快照 · 当前数据不再同步", symbol: "clock.arrow.circlepath")
                }
                Group {
                    if let snapshot = store.snapshot {
                        switch selection ?? .connection {
                        case .connection: connection(snapshot)
                        case .routes: LiveRoutesView(snapshot: snapshot, store: store)
                        case .profiles: LiveProfilesView(snapshot: snapshot, store: store)
                        case .activity: NativeActivityWorkspace(store: store)
                        }
                    } else {
                        ContentUnavailableView {
                            Label(connectionTitle, systemImage: "network")
                        } description: {
                            Text(LiveText.state(store.statusText))
                        } actions: {
                            if store.state == .connecting || store.state == .renewing || store.state == .stopping {
                                ProgressView().controlSize(.small)
                            } else if store.state == .shutdownFailed {
                                Button("重试安全退出", systemImage: "arrow.clockwise") { store.disconnect() }
                            } else {
                                Button(store.isReadOnlyConnection ? "只读查看" : "连接后台", systemImage: "link") { store.connect() }
                                    .accessibilityIdentifier("live.connect")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle((selection ?? .connection).title)
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .principal) {
                        TezWindowDragRegion().frame(width: 240, height: 28)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) {
                        TezWindowDragRegion().frame(width: 240, height: 28)
                    }
                }
                ToolbarItemGroup {
                    if store.state == .connected {
                        Button("刷新", systemImage: "arrow.clockwise") { store.refresh() }
                            .help("刷新后台快照")
                            .accessibilityIdentifier("live.refresh")
                        Button(store.requiresManagedShutdown ? "安全退出后台" : "断开", systemImage: "xmark.circle") { store.disconnect() }
                            .help(store.requiresManagedShutdown ? "等待独立内核停止后退出后台" : "断开只读连接，不停止现有后台")
                            .accessibilityIdentifier("live.disconnect")
                    } else if store.state == .renewing {
                        ProgressView().controlSize(.small).help("正在续期只读连接")
                        Button("取消续期", systemImage: "xmark.circle") { store.disconnect() }
                            .help("取消续期，不停止现有代理")
                    } else if store.state == .stopping {
                        ProgressView().controlSize(.small).help("正在等待后台安全退出")
                    } else if store.state == .shutdownFailed {
                        Button("重试安全退出", systemImage: "arrow.clockwise") { store.disconnect() }
                    } else {
                        Button("连接后台", systemImage: "link") { store.connect() }
                            .disabled(store.state == .connecting)
                            .help("连接现有后台")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.bar, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(TezWindowSurface())
        .tint(TezStyle.accent)
        .alert(item: $pendingCoreAction) { action in
            Alert(title: Text("确认\(action.title)内核？"),
                  message: Text("此操作会改变内核运行状态，并可能中断当前连接。"),
                  primaryButton: .destructive(Text("确认\(action.title)")) { runCore(action) },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    private var hasWriteCapability: Bool {
        ["native_save_profile", "native_select_route", "native_core_start", "native_core_stop", "native_core_restart"].contains { store.supports($0) }
    }

    private var connectionTitle: String {
        switch store.state {
        case .connecting: "正在连接后台"
        case .renewing: "正在续期只读连接"
        case .stopping: "正在安全退出后台"
        case .shutdownFailed: "后台退出尚未确认"
        default: "尚未连接后台"
        }
    }

    private func statusBanner(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
            Text(text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }

    private func connection(_ snapshot: NativeSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    TezBrandMark().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.state == .connected ? "后台已连接" : "后台未连接")
                            .font(.system(size: 25, weight: .semibold))
                        Text(LiveText.state(store.statusText)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(spacing: 0) {
                    LiveMetadataRow(title: "当前配置", value: snapshot.profiles.items.first { $0.uid == snapshot.profiles.current }.map(LiveText.profileName) ?? "未指定")
                    Divider()
                    LiveMetadataRow(title: "配置状态", value: LiveText.state(snapshot.profiles.state))
                    Divider()
                    LiveMetadataRow(title: "内核状态", value: LiveText.state(snapshot.core.state))
                    HStack(spacing: 12) {
                        ForEach(LiveCoreAction.allCases) { action in
                            Button(action.title, systemImage: action.symbol) { pendingCoreAction = action }
                                .disabled(coreBusy || !store.supports(action.command))
                                .accessibilityIdentifier("live.core.\(action.rawValue)")
                        }
                        if coreBusy { ProgressView().controlSize(.small) }
                        Spacer()
                    }.padding(.bottom, 12)
                    if !LiveCoreAction.allCases.contains(where: { store.supports($0.command) }) {
                        Text("只读连接：当前后台未开放内核控制。")
                            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                    }
                    if let coreMessage {
                        LiveCommandFeedback(message: coreMessage, details: coreDetails).padding(.bottom, 12)
                    }
                    if let message = snapshot.core.message {
                        Text(LiveText.message(message)).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                    }
                    Divider()
                    LiveMetadataRow(title: "快照版本", value: snapshot.revision)
                    Divider()
                    HStack {
                        Text("策略组").foregroundStyle(.secondary)
                        Spacer()
                        Button("查看线路", systemImage: "chevron.right") { selection = .routes }
                            .buttonStyle(.plain).foregroundStyle(TezStyle.accent)
                    }.padding(.vertical, 15)
                }
            }
            .frame(maxWidth: 700)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func runCore(_ action: LiveCoreAction) {
        guard !coreBusy, store.supports(action.command) else { return }
        coreBusy = true
        coreMessage = nil
        coreDetails = nil
        Task { @MainActor in
            defer { coreBusy = false }
            do {
                let result = try await store.request(action.command)
                coreMessage = "\(action.title)请求已完成。运行状态以后台快照为准。"
                coreDetails = LiveCommandFeedback.render(result)
            } catch {
                coreMessage = "\(action.title)请求失败。请检查详情和当前内核状态。"
                coreDetails = LiveCommandFeedback.errorDetails(error)
            }
            store.refresh()
        }
    }
}

private enum LiveCoreAction: String, CaseIterable, Identifiable {
    case start, stop, restart
    var id: String { rawValue }
    var command: String { "native_core_\(rawValue)" }
    var title: String { switch self { case .start: "启动"; case .stop: "停止"; case .restart: "重启" } }
    var symbol: String { switch self { case .start: "play.fill"; case .stop: "stop.fill"; case .restart: "arrow.clockwise" } }
}

private struct LiveCommandFeedback: View {
    let message: String
    let details: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout).textSelection(.enabled)
            if let details {
                ScrollView {
                    Text(details).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    static func render(_ value: BackendJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
    static func errorDetails(_ error: Error) -> String {
        if case NativeBackendError.remote(let remote) = error {
            var fields: [String: BackendJSON] = ["detail": .string(remote.detail)]
            fields["code"] = remote.code
            fields["operation"] = remote.operation
            return render(.object(fields))
        }
        return String(describing: error)
    }
}

private struct LiveMetadataRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 13))
        .padding(.vertical, 15)
    }
}

private struct LiveProfilesView: View {
    let snapshot: NativeSnapshot
    let store: NativeBackendStore
    @State private var selectedID: String?
    @State private var enhancementsExpanded = false
    @State private var editingProfile: NativeProfileItem?
    @State private var managingProfile: NativeProfileItem?
    @State private var showingManager = false

    private var canEdit: Bool { store.supports("native_read_profile") && store.supports("native_save_profile") }

    private var configurations: [NativeProfileItem] {
        snapshot.profiles.items.filter { $0.type == "remote" || $0.type == "local" }
    }
    private var enhancements: [NativeProfileItem] {
        snapshot.profiles.items.filter { isEnhancement($0) }
    }
    private var otherFiles: [NativeProfileItem] {
        snapshot.profiles.items.filter { $0.type != "remote" && $0.type != "local" && !isEnhancement($0) }
    }

    private var selected: NativeProfileItem? {
        snapshot.profiles.items.first { $0.uid == selectedID }
            ?? snapshot.profiles.items.first { $0.uid == snapshot.profiles.current }
            ?? configurations.first
            ?? snapshot.profiles.items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("配置与订阅").font(.headline)
                Spacer()
                Button("添加配置", systemImage: "plus") { managingProfile = nil; showingManager = true }
                    .disabled(!store.supports("native_import_subscription"))
            }.padding(16)
            Divider()
        if snapshot.profiles.items.isEmpty {
            ContentUnavailableView {
                Label(snapshot.profiles.state == "error" ? "配置读取失败" : snapshot.profiles.state == "missing" ? "配置文件不可用" : "没有配置", systemImage: snapshot.profiles.state == "error" ? "exclamationmark.triangle" : "doc.text")
            } description: {
                Text(snapshot.profiles.message.map(LiveText.message) ?? "后台未返回配置。")
            }
        } else {
            HSplitView {
                List(selection: Binding(get: { selected?.uid }, set: { selectedID = $0 })) {
                    if !configurations.isEmpty {
                        Section("配置") {
                            ForEach(configurations) { profileRow($0) }
                        }
                    }
                    if !enhancements.isEmpty {
                        DisclosureGroup(isExpanded: $enhancementsExpanded) {
                            ForEach(enhancements) { profileRow($0) }
                        } label: {
                            Text("增强文件（\(enhancements.count)）")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .accessibilityIdentifier("live.profiles.enhancements")
                    }
                    if !otherFiles.isEmpty {
                        Section("其他文件") {
                            ForEach(otherFiles) { profileRow($0) }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let profile = selected {
                            HStack(alignment: .top) {
                                Text(LiveText.profileName(profile)).font(.system(size: 20, weight: .semibold))
                                    .textSelection(.enabled)
                                Spacer()
                                if profile.type == "remote" || profile.type == "local" {
                                    Button("管理", systemImage: "slider.horizontal.3") { managingProfile = profile; showingManager = true }
                                        .disabled(!store.supports("native_subscription_details"))
                                }
                                Button("编辑", systemImage: "square.and.pencil") {
                                    guard canEdit else { return }
                                    editingProfile = profile
                                }
                                .disabled(!canEdit)
                                .accessibilityIdentifier("live.profiles.edit")
                            }.padding(.bottom, 16)
                            if !canEdit {
                                Text("只读连接：当前后台未开放配置编辑。")
                                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                            }
                            Divider()
                            LiveMetadataRow(title: "类型", value: LiveText.profileType(profile.type))
                            Divider()
                            LiveMetadataRow(title: "状态", value: profile.uid == snapshot.profiles.current ? "当前配置" : "未使用")
                            Divider()
                            LiveMetadataRow(title: "配置标识", value: profile.uid)
                            Divider()
                            LiveMetadataRow(title: "更新时间", value: updatedTime(profile.updated))
                            Divider()
                            LiveMetadataRow(title: "读取状态", value: LiveText.state(snapshot.profiles.state))
                            if let message = snapshot.profiles.message {
                                Text(LiveText.message(message)).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled).padding(.top, 14)
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .sheet(item: $editingProfile) { profile in NativeProfileEditor(profile: profile, store: store) }
        }
        }
        .sheet(isPresented: $showingManager) { NativeSubscriptionSheet(store: store, profile: managingProfile) }
    }

    private func profileRow(_ profile: NativeProfileItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.type == "remote" ? "arrow.triangle.2.circlepath" : "doc.text")
                .foregroundStyle(TezStyle.accent).frame(width: 23)
            VStack(alignment: .leading, spacing: 4) {
                Text(LiveText.profileName(profile)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(LiveText.profileType(profile.type)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if snapshot.profiles.current == profile.uid {
                Image(systemName: "checkmark").foregroundStyle(TezStyle.success)
                    .accessibilityLabel("当前配置")
            }
        }
        .padding(.vertical, 10)
        .tag(profile.uid)
    }

    private func isEnhancement(_ profile: NativeProfileItem) -> Bool {
        ["merge", "script", "rules", "proxies", "groups"].contains(profile.type)
    }

    private func updatedTime(_ timestamp: Double?) -> String {
        guard let timestamp, timestamp > 0 else { return "未提供" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct LiveRoutesView: View {
    let snapshot: NativeSnapshot
    let store: NativeBackendStore
    @Environment(TezPreviewPreferences.self) private var preferences
    @State private var groupName: String?
    @State private var selectedID: String?
    @State private var search = ""
    @State private var switching = false
    @State private var switchMessage: String?
    @State private var switchDetails: String?
    @State private var latency = NativeLatencyModel()
    @State private var latencyURL = "https://www.gstatic.com/generate_204"
    @State private var latencyTimeout = 5000

    private var supportsSelection: Bool { store.supports("native_select_route") }
    private var canSwitch: Bool {
        guard supportsSelection, !switching, !store.workspaceBusy, !latency.busy, let group, let selected, selected.isResolved, !selected.isCurrent else { return false }
        return ["selector", "urltest", "fallback"].contains(group.type.lowercased().replacingOccurrences(of: "-", with: ""))
            && rows.filter { $0.member.name == selected.member.name }.count == 1
    }

    private var groups: [NativeProxyGroup] {
        guard let view = snapshot.proxyView else { return [] }
        if let global = view.global, !view.groups.contains(where: { $0.name == global.name }) {
            return [global] + view.groups
        }
        return view.groups
    }
    private var group: NativeProxyGroup? { groups.first { $0.name == groupName } ?? groups.first }
    private var rows: [LiveRouteMember] {
        guard let view = snapshot.proxyView else { return [] }
        let members = group?.members ?? view.standalone.compactMap { id in
            view.records[id].map { NativeProxyMember(kind: "node", name: $0.name, recordId: id, reason: nil) }
        }
        return members.enumerated().map { index, member in
            LiveRouteMember(member: member, index: index, view: view, isCurrent: group?.now == member.name)
        }
    }
    private var visibleRows: [LiveRouteMember] {
        rows.filter { search.isEmpty || "\($0.name) \($0.type) \($0.source)".localizedCaseInsensitiveContains(search) }
    }
    private var selected: LiveRouteMember? { visibleRows.first { $0.id == selectedID } }

    var body: some View {
        if let view = snapshot.proxyView {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    currentRail(compact: geometry.size.width < 700)
                    Divider()
                    filterBar(view)
                    Divider()
                    if view.providerState == "unavailable" {
                        HStack {
                            Label("订阅提供方数据不可用", systemImage: "exclamationmark.circle")
                            Spacer()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                    routeList(showProtocol: preferences.showProtocol && geometry.size.width >= 630)
                    Divider()
                    detailRail
                }
            }
            .onChange(of: group?.name) { _, _ in selectedID = nil }
            .task {
                guard store.supports("native_get_settings"), let response = try? await store.request("native_get_settings"),
                      let settings = try? response.decoded(NativeSettingsPayload.self) else { return }
                if case .string(let url) = settings.values["default_latency_test"] { latencyURL = url }
                if case .integer(let timeout) = settings.values["default_latency_timeout"] { latencyTimeout = Int(timeout) }
                if case .unsigned(let timeout) = settings.values["default_latency_timeout"], timeout <= 30000 { latencyTimeout = Int(timeout) }
            }
        } else {
            ContentUnavailableView {
                Label("线路数据不可用", systemImage: "network.slash")
            } description: {
                Text(snapshot.core.message.map(LiveText.message) ?? "后台未返回线路快照。")
            }
        }
    }

    private func currentRail(compact: Bool) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text("当前选择").font(.caption).foregroundStyle(.secondary)
                Text(LiveText.name(group?.now ?? "", fallback: "未提供"))
                    .font(.system(size: compact ? 19 : 22, weight: .semibold))
                    .foregroundStyle(TezStyle.success)
                    .lineLimit(2).help(group?.now ?? "后台未提供当前选择")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 9) {
                Text(group?.type ?? "独立线路").font(.system(size: 13, weight: .medium))
                Text("\(rows.count) 个成员").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, compact ? 20 : 28)
        .frame(height: 106)
        .background { TezContentMaterial(material: .headerView) }
    }

    private func filterBar(_ view: NativeProxyView) -> some View {
        HStack(spacing: 20) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索线路", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("live.routes.search")
            }
            .frame(maxWidth: .infinity)
            if !groups.isEmpty {
                Picker("策略组", selection: Binding(get: { group?.name ?? "" }, set: { groupName = $0 })) {
                    ForEach(groups) { item in Text(LiveText.name(item.name, fallback: "未命名策略组")).tag(item.name) }
                }
                .labelsHidden().pickerStyle(.menu)
                .frame(maxWidth: 210)
                .help("查看策略组，不更改后台选择")
                .accessibilityIdentifier("live.routes.group")
            }
            if latency.busy {
                ProgressView(value: Double(latency.completed), total: Double(max(1, latency.total))).frame(width: 54)
                Button("停止测速", systemImage: "stop.fill") { latency.stopAfterCurrentBatch() }
                    .labelStyle(.iconOnly).help("当前批次结束后停止")
            } else {
                Button("测速", systemImage: "speedometer") { testLatency(visibleRows) }
                    .disabled(!store.supports("native_test_latency") || store.workspaceBusy || testable(visibleRows).isEmpty)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func routeList(showProtocol: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("线路名称").frame(maxWidth: .infinity, alignment: .leading)
                if showProtocol { Text("协议 / 类型").frame(width: 110, alignment: .leading) }
                Text("延迟").frame(width: 80, alignment: .trailing)
                Text("状态").frame(width: 110, alignment: .trailing)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.leading, 48).padding(.trailing, 28)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor))
            List(selection: $selectedID) {
                ForEach(visibleRows) { row in
                    HStack(spacing: 16) {
                        HStack(spacing: 10) {
                            Image(systemName: row.member.kind == "group" ? "rectangle.3.group" : row.isResolved ? "point.3.connected.trianglepath.dotted" : "questionmark.circle")
                                .foregroundStyle(.secondary).frame(width: 17)
                            Text(row.name).lineLimit(1).help(row.name)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if showProtocol { Text(row.type).foregroundStyle(.secondary).lineLimit(1).frame(width: 110, alignment: .leading) }
                        Text(latency.label(for: row.member.name, fallback: row.latency)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                        Text(row.status).font(.system(size: 11)).foregroundStyle(row.isCurrent && row.isResolved ? TezStyle.success : Color.secondary)
                            .frame(width: 110, alignment: .trailing)
                    }
                    .font(.system(size: 13)).frame(height: 43)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .tag(row.id)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .contextMenu {
                        if row.member.kind == "group", groups.contains(where: { $0.name == row.member.name }) {
                            Button("查看策略组", systemImage: "rectangle.3.group") { groupName = row.member.name }
                        }
                        Button("复制名称", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.name, forType: .string)
                        }
                        Button("测试延迟", systemImage: "speedometer") { testLatency([row]) }
                            .disabled(latency.busy || store.workspaceBusy || !store.supports("native_test_latency") || testable([row]).isEmpty)
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if visibleRows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "没有线路" : "没有匹配的线路", systemImage: search.isEmpty ? "network" : "magnifyingglass")
                }
            }
        }
    }

    private var detailRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let row = selected {
                HStack {
                    Text(row.name).font(.system(size: 14, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if switching { ProgressView().controlSize(.small) }
                    Button("切换到此线路", systemImage: "arrow.right.circle") { switchRoute() }
                        .disabled(!canSwitch)
                        .accessibilityIdentifier("live.routes.select")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) { detailValues(row) }
                    VStack(alignment: .leading, spacing: 12) { detailValues(row) }
                }
            } else {
                Text("选择成员以查看详情").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if !supportsSelection {
                Text("只读连接：当前后台未开放线路切换。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let switchMessage { LiveCommandFeedback(message: switchMessage, details: switchDetails) }
            if let error = latency.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if latency.total > 0 {
                Text("测速 \(latency.completed) / \(latency.total)\(latency.stopped ? " · 已停止" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(visibleRows.count) 个成员")
                Spacer()
                Text("快照 \(snapshot.revision)").lineLimit(1)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .frame(minHeight: 106, alignment: .leading)
        .background { TezContentMaterial(material: .contentBackground) }
    }

    private func switchRoute() {
        guard canSwitch, let group, let selected else { return }
        switching = true
        switchMessage = nil
        switchDetails = nil
        Task { @MainActor in
            defer { switching = false }
            do {
                let result = try await store.request("native_select_route", params: [
                    "group": .string(group.name), "name": .string(selected.member.name)
                ])
                guard case .object(let value) = result,
                      case .bool(let applied) = value["applied"],
                      case .bool(let persisted) = value["persisted"] else {
                    throw BackendWireError.invalid("Invalid native_select_route response")
                }
                if applied && persisted {
                    switchMessage = "线路已切换，选择已保存。"
                } else if applied {
                    switchMessage = "线路已切换，但选择未保存。请检查详情；重新启动后此选择可能丢失。"
                } else {
                    switchMessage = "线路未切换。请检查详情和当前线路。"
                }
                switchDetails = LiveCommandFeedback.render(result)
            } catch {
                switchMessage = "切换请求失败。请检查详情和当前线路；不会自动重试。"
                switchDetails = LiveCommandFeedback.errorDetails(error)
            }
            store.refresh()
        }
    }

    private func testable(_ candidates: [LiveRouteMember]) -> [String] {
        candidates.filter { row in
            row.member.kind == "node" && row.isResolved && !["direct", "reject", "rejectdrop", "pass"].contains(row.type.lowercased())
                && (snapshot.proxyView?.records.values.contains { $0.name == row.member.name && $0.source.kind == "core" } == true
                    || snapshot.proxyView?.records.values.filter { $0.name == row.member.name }.count == 1)
        }.map(\.member.name)
    }

    private func testLatency(_ candidates: [LiveRouteMember]) {
        let names = testable(candidates)
        Task { @MainActor in
            await latency.test(names: names, url: latencyURL, timeout: latencyTimeout) { command, params in
                try await store.request(command, params: params, timeout: .seconds(150), serialWorkspace: true)
            }
            store.refresh()
        }
    }

    @ViewBuilder private func detailValues(_ row: LiveRouteMember) -> some View {
        detailPair("类型", row.type)
        detailPair("UDP", row.udp.map { $0 ? "支持" : "不支持" } ?? "未提供")
        detailPair("来源", row.source)
        detailPair("最近测速", latency.measuredAt[row.member.name]?.formatted(date: .omitted, time: .standard) ?? row.measuredAt ?? "未测速")
    }

    private func detailPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).textSelection(.enabled)
                .lineLimit(2).help(value)
        }
    }
}

private struct LiveRouteMember: Identifiable {
    let member: NativeProxyMember
    let index: Int
    let view: NativeProxyView
    let isCurrent: Bool
    var id: String { "\(index):\(member.kind):\(member.recordId ?? member.name)" }
    var name: String { LiveText.name(member.name, fallback: member.kind == "group" ? "未命名策略组" : "未命名线路") }
    private var node: NativeProxyNode? {
        guard member.kind == "node", let id = member.recordId else { return nil }
        return view.records[id]
    }
    private var group: NativeProxyGroup? {
        guard member.kind == "group" else { return nil }
        return view.groups.first { $0.name == member.name } ?? (view.global?.name == member.name ? view.global : nil)
    }
    var isResolved: Bool { node != nil || group != nil }
    var type: String { node?.type ?? group.map { "策略组 · \($0.type)" } ?? "未解析" }
    var udp: Bool? { node?.udp ?? group?.udp }
    private var latest: NativeDelayHistory? { (node?.history ?? group?.history ?? []).last }
    var latency: String { latest.map { $0.delay == 0 ? "超时" : "\($0.delay) ms" } ?? "未测速" }
    var measuredAt: String? { latest?.time }
    var source: String {
        if let node {
            return node.source.providerName ?? (node.source.kind == "core" ? "内核" : node.source.kind)
        }
        return member.kind == "group" ? "策略组" : "未提供"
    }
    var status: String {
        if isResolved && isCurrent { return "使用中" }
        if isResolved { return member.kind == "group" ? "嵌套策略组" : "线路" }
        switch member.reason {
        case "provider-unavailable": return "提供方不可用"
        case "ambiguous": return "同名，未解析"
        case "missing": return "记录缺失"
        default: return "未解析"
        }
    }
}

private enum LiveText {
    static func profileName(_ profile: NativeProfileItem) -> String {
        name(profile.name, fallback: "\(profileType(profile.type)) · \(profile.uid.suffix(6))")
    }

    static func name(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    static func state(_ value: String) -> String {
        switch value {
        case "ready": "可用"
        case "missing": "文件缺失"
        case "error": "读取失败"
        case "unavailable": "不可用"
        case "Not connected": "未连接"
        case "Connecting": "正在连接"
        case "Connected": "已连接"
        case "Connection failed": "连接失败"
        default: value
        }
    }

    static func profileType(_ value: String) -> String {
        switch value {
        case "remote": "订阅配置"
        case "local": "本地配置"
        case "merge": "合并配置"
        case "script": "脚本"
        case "rules": "规则集"
        case "proxies": "代理集合"
        case "groups": "策略组"
        default: name(value, fallback: "未提供")
        }
    }

    static func message(_ value: String) -> String {
        switch value {
        case "Profile metadata is not available": "配置文件不可用。"
        case "Cannot read profile metadata": "无法读取配置文件。"
        case "Profile metadata is not a supported file": "配置文件格式不受支持。"
        case "Profile metadata exceeds the size limit": "配置文件超出大小限制。"
        case "Profile metadata is invalid": "配置文件内容无效。"
        case "Profile metadata contains invalid identities": "配置文件含无效或重复的配置标识。"
        case "Controller read deadline exceeded": "读取内核状态超时。"
        case "Cannot encode controller snapshot": "无法生成内核快照。"
        case "Cannot read local controller": "无法读取本地内核。"
        case "Local controller is not available": "本地内核不可用。"
        case "Backend exited": "后台连接进程已退出。"
        case "Backend helper could not start": "无法启动后台连接进程。"
        case "Backend handshake timed out": "后台握手超时。"
        case "Backend output closed": "后台输出已关闭。"
        case "Invalid backend frame": "后台返回的数据格式无效。"
        case "Backend disconnected": "后台连接已断开。"
        case "Snapshot refresh failed": "刷新快照失败。"
        case "Backend unavailable or request limit reached": "后台不可用或请求数量超出限制。"
        case "Request timed out": "后台请求超时。"
        case "Backend input closed": "后台输入已关闭。"
        case "Backend handshake rejected": "后台握手未通过。"
        case "Backend subscription failed": "订阅后台事件失败。"
        case "Response before handshake": "后台在握手前返回了响应。"
        case "Backend request failed": "后台请求失败。"
        case "Invalid backend event": "后台事件格式无效。"
        case "Backend event sequence interrupted; reconnect required": "后台事件序列中断。请重新连接。"
        case "Invalid backend snapshot": "后台快照格式无效。"
        case "Unexpected backend request": "后台发送了非预期请求。"
        default: value
        }
    }
}
