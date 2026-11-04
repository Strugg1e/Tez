import AppKit
import SwiftUI

struct LiveWorkspaceView: View {
    @Bindable var store: NativeBackendStore
    @Binding var selection: WorkspaceSection?
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pendingCoreAction: LiveCoreAction?
    @State private var coreBusy = false
    @State private var coreMessage: String?
    @State private var coreDetails: String?
    @State private var inspectionBusy = false
    @State private var confirmClaim = false
    @State private var claimInspection: NativeCoreInspection?
    @State private var showCoreUpgrade = false
    @State private var confirmServiceInstall = false
    @State private var serviceInstallInspection: NativeCoreInspection?
    @State private var maintenanceExpanded = false
    @State private var routeLatency = NativeLatencyModel()
    @State private var activitySession = NativeActivitySession()

    private var connectionPresentation: TezConnectionPresentation {
        TezConnectionPresentation(state: store.state, hasSnapshot: store.snapshot != nil,
                                  coreState: store.snapshot?.core.state, writable: hasWriteCapability)
    }

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
                    SettingsLink { Label("设置", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.plain)
                }
                .font(TezType.body)
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
                TezConnectionBar(presentation: connectionPresentation,
                                 error: store.errorMessage.map(LiveText.message),
                                 reconnect: { store.connect() }, retryShutdown: { store.disconnect() },
                                 motion: TezMotion(reduced: preferences.reduceMotion || systemReduceMotion))
                Divider()
                Group {
                    if let snapshot = store.snapshot {
                        switch selection ?? .connection {
                        case .connection: connection(snapshot)
                        case .routes: LiveRoutesView(snapshot: snapshot, store: store, latency: routeLatency)
                        case .profiles: LiveProfilesView(snapshot: snapshot, store: store)
                        case .activity:
                            NativeActivityWorkspace(store: store, session: activitySession)
                                .id(ObjectIdentifier(activitySession))
                        }
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: (selection ?? .connection).symbol,
                                               description: Text(emptyDescription))
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
        .confirmationDialog("接管现有内核的控制权？", isPresented: $confirmClaim) {
            Button("接管控制权") { claimCore() }
            Button("取消", role: .cancel) {}
        } message: { Text("将接管 PID \(claimInspection?.corePid ?? 0)。内核进程保持运行。原管理会话将失效。") }
        .sheet(isPresented: $showCoreUpgrade) { NativeCoreUpgradeView(store: store) }
        .onChange(of: store.snapshot?.profiles.current) { _, _ in
            routeLatency = NativeLatencyModel()
            activitySession = NativeActivitySession()
        }
        .confirmationDialog("更新系统后台服务？", isPresented: $confirmServiceInstall) {
            Button("授权并更新后台服务", role: .destructive) { installService() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(serviceInstallInspection?.corePid.map { "将替换系统后台服务，并停止或重启现有内核（PID \($0)）。代理会短暂中断。macOS 将请求管理员授权。" }
                 ?? "将安装系统后台服务。macOS 将请求管理员授权，代理状态会随服务安装而改变。")
        }
    }

    private var hasWriteCapability: Bool {
        ["native_save_profile", "native_select_route", "native_core_start", "native_core_stop", "native_core_restart"].contains { store.supports($0) }
    }

    private var emptyTitle: String {
        switch selection ?? .connection {
        case .connection: "尚无连接概况"
        case .routes: "线路暂不可用"
        case .profiles: "配置暂不可用"
        case .activity: "活动暂不可用"
        }
    }

    private var emptyDescription: String {
        switch selection ?? .connection {
        case .connection: "连接后台后显示内核与当前配置。"
        case .routes: "连接后台后显示策略组、当前线路与延迟。"
        case .profiles: "连接后台后显示配置与订阅。"
        case .activity: "连接后台后显示连接记录与流量。"
        }
    }

    private func connection(_ snapshot: NativeSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("连接概况").font(TezType.page)
                NativeProxyControls(store: store, snapshot: snapshot) {
                    selection = .routes
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("内核与服务").font(TezType.section)
                    if LiveCoreAction.allCases.contains(where: { store.supports($0.command) }) || store.supports("native_upgrade_core") {
                        HStack(spacing: 12) {
                            ForEach(LiveCoreAction.allCases) { action in
                                Button(action.title, systemImage: action.symbol) { pendingCoreAction = action }
                                    .disabled(store.state != .connected || coreBusy || store.workspaceBusy || !store.supports(action.command)
                                              || (action == .start && snapshot.core.state == "ready"))
                                    .accessibilityIdentifier("live.core.\(action.rawValue)")
                            }
                            if coreBusy { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                    }
                    if let inspection = snapshot.core.lifecycle {
                        Text(inspection.explanation).font(TezType.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    NativeSessionProtectionView(store: store, coreState: snapshot.core.state)
                    if store.serviceSetupInProgress {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("等待系统授权并更新后台服务…")
                        }.font(TezType.body).foregroundStyle(.secondary)
                    }
                    if snapshot.core.lifecycle != nil || store.supports("native_upgrade_core") || store.supports("native_install_service") {
                        TezSettingsDisclosure(title: "高级维护", summary: "更新内核、后台服务与控制权", isExpanded: $maintenanceExpanded,
                                              motion: TezMotion(reduced: preferences.reduceMotion || systemReduceMotion)) {
                            if store.supports("native_upgrade_core") {
                                TezSettingRow(title: "更新内核", detail: "选择已下载的内核文件，检查后更新。") {
                                    Button("从文件更新内核…", systemImage: "arrow.up.circle") { showCoreUpgrade = true }
                                        .disabled(store.state != .connected || coreBusy || store.workspaceBusy)
                                }
                            }
                            if snapshot.core.lifecycle == nil && store.supports("native_install_service") {
                                TezSettingRow(title: "后台服务", detail: "先停止内核，再使用当前应用附带的服务重新安装。安装后内核保持停止。") {
                                    Button("重新安装后台服务…", systemImage: "gearshape.2") { inspectServiceInstall() }
                                        .disabled(store.state != .connected || coreBusy || store.workspaceBusy || snapshot.core.state == "ready")
                                        .accessibilityIdentifier("live.service.install")
                                }
                            }
                            if let inspection = snapshot.core.lifecycle {
                                if store.supports("native_install_service") {
                                    TezSettingRow(title: "后台服务", detail: inspection.serviceProtocol == nil ? "尚未安装。安装时 macOS 会请求授权。" : "更新时 macOS 会请求授权。") {
                                        Button(inspection.serviceProtocol == nil ? "安装后台服务…" : "升级后台服务…", systemImage: "gearshape.2") {
                                            serviceInstallInspection = inspection
                                            confirmServiceInstall = true
                                        }
                                        .disabled(coreBusy || store.workspaceBusy)
                                        .accessibilityIdentifier("live.service.install")
                                    }
                                }
                                TezSettingRow(title: "内核控制权", detail: "重新检测运行状态；接管后原管理会话失效。") {
                                    HStack {
                                        TezToolButton(title: "重新检测内核", symbol: "arrow.clockwise", enabled: !inspectionBusy && !store.workspaceBusy && store.state == .connected) { inspectCore() }
                                        if store.supports("native_claim_core") {
                                            Button("接管控制权…", systemImage: "key.fill") { claimInspection = inspection; confirmClaim = true }
                                                .disabled(coreBusy || store.workspaceBusy || inspection.state != "runningReadOnly" || inspection.serviceStartedAt == nil)
                                                .accessibilityIdentifier("live.core.claim")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if snapshot.core.lifecycle == nil && !LiveCoreAction.allCases.contains(where: { store.supports($0.command) }) {
                        Text("只读连接：当前后台未开放内核控制。")
                            .font(TezType.metadata).foregroundStyle(.secondary).padding(.bottom, 12)
                    }
                    if let coreMessage {
                        LiveCommandFeedback(message: coreMessage, details: coreDetails).padding(.bottom, 12)
                    }
                    if let message = snapshot.core.message {
                        Text(LiveText.message(message)).font(TezType.metadata).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                    }
                }
                Divider()
                DisclosureGroup("诊断详情") {
                    LiveMetadataRow(title: "后台", value: connectionPresentation.title)
                    LiveMetadataRow(title: "内核", value: connectionPresentation.coreTitle)
                    LiveMetadataRow(title: "快照版本", value: snapshot.revision)
                    LiveMetadataRow(title: "配置状态", value: LiveText.state(snapshot.profiles.state))
                    if let inspection = snapshot.core.lifecycle {
                        LiveMetadataRow(title: "控制状态", value: inspection.stateLabel)
                        LiveMetadataRow(title: "后台协议", value: inspection.serviceProtocol ?? "未确认")
                        LiveMetadataRow(title: "运行来源", value: inspection.source == "service" ? "系统服务" : inspection.source == "process" ? "检测到的进程" : "未确认")
                        ForEach(inspection.processes) { process in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(process.name) · PID \(process.pid)").font(TezType.body)
                                Text(process.executable).font(TezType.metadata).foregroundStyle(.secondary)
                                Text("用户 \(process.uid) · 启动于 \(process.startedAt)").font(TezType.metadata).foregroundStyle(.secondary)
                            }.textSelection(.enabled).padding(.vertical, 8)
                        }
                    }
                }
                .font(TezType.body)
            }
            .frame(maxWidth: 700)
            .padding(TezStyle.pageInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func inspectCore() {
        guard !inspectionBusy else { return }
        inspectionBusy = true
        Task { @MainActor in
            defer { inspectionBusy = false }
            if store.supports("native_inspect_core") { _ = try? await store.request("native_inspect_core") }
            store.refresh()
        }
    }

    private func claimCore() {
        guard !coreBusy, !store.workspaceBusy, store.supports("native_claim_core"),
              let inspection = claimInspection, let pid = inspection.corePid,
              let generation = inspection.serviceGeneration.flatMap(Int64.init(exactly:)),
              let started = inspection.serviceStartedAt.flatMap(Int64.init(exactly:)) else { return }
        coreBusy = true
        Task { @MainActor in
            defer { coreBusy = false }
            do {
                let result = try await store.request("native_claim_core", params: ["confirmed": .bool(true),
                    "expected": .object(["generation": .integer(generation), "pid": .integer(Int64(pid)), "started_at": .integer(started)])], serialWorkspace: true)
                guard case .object(let fields) = result, fields["claimed"] == .bool(true) else { throw NativeBackendError.unavailable("后台未确认接管结果") }
                coreMessage = "控制权接管成功，正在恢复管理连接。"
                coreDetails = nil
                store.reconnectAfterClaim()
            } catch {
                coreMessage = "接管结果未确认。内核未收到停止或重启请求。"
                coreDetails = LiveCommandFeedback.errorDetails(error)
                store.refresh()
            }
        }
    }

    private func installService() {
        guard !coreBusy, !store.workspaceBusy, let inspection = serviceInstallInspection else { return }
        let expected: BackendJSON
        if let pid = inspection.corePid {
            guard let generation = inspection.serviceGeneration.flatMap(Int64.init(exactly:)),
                  let started = inspection.serviceStartedAt.flatMap(Int64.init(exactly:)) else {
                coreMessage = "内核身份尚未确认，请重新检测后再更新服务。"
                return
            }
            expected = .object(["generation": .integer(generation), "pid": .integer(Int64(pid)), "started_at": .integer(started)])
        } else { expected = .null }
        coreBusy = true
        coreMessage = nil
        coreDetails = nil
        Task { @MainActor in
            defer { coreBusy = false }
            do {
                let result = try await store.installService(params: ["confirmed": .bool(true), "expected": expected])
                guard case .object(let fields) = result, fields["installed"] == .bool(true) else {
                    throw NativeBackendError.unavailable("后台服务更新结果未确认，请重新检测。")
                }
                if fields["reconnectRequired"] == .bool(false) {
                    coreMessage = "后台服务重新安装完成。内核保持停止，请手动启动。"
                    store.refresh()
                } else {
                    coreMessage = "后台服务更新完成，正在恢复连接。检测完成后可启动或接管内核。"
                    store.reconnectAfterClaim()
                }
            } catch {
                coreMessage = "后台服务更新未完成。取消授权后可以重试；其他情况请重新检测内核状态。"
                coreDetails = NativeFeatureError.message(error)
                if store.isReadOnlyConnection, case NativeBackendError.remote = error { store.reconnectAfterClaim() }
                else { store.refresh() }
            }
        }
    }

    private func inspectServiceInstall() {
        guard !coreBusy, !store.workspaceBusy, store.supports("native_inspect_core") else { return }
        coreBusy = true
        Task { @MainActor in
            defer { coreBusy = false }
            do {
                let inspection = try await store.request("native_inspect_core").decoded(NativeCoreInspection.self)
                guard inspection.canStart, inspection.corePid == nil, inspection.processes.isEmpty else {
                    coreMessage = "请先停止内核，并确认没有其他运行中的内核，再重新安装后台服务。"
                    return
                }
                serviceInstallInspection = inspection
                confirmServiceInstall = true
            } catch {
                coreMessage = "后台服务状态尚未确认，未开始安装。"
                coreDetails = NativeFeatureError.message(error)
            }
        }
    }

    private func runCore(_ action: LiveCoreAction) {
        guard !coreBusy, !store.workspaceBusy, store.supports(action.command) else { return }
        coreBusy = true
        coreMessage = nil
        coreDetails = nil
        Task { @MainActor in
            defer { coreBusy = false }
            do {
                let result = try await store.request(action.command, serialWorkspace: true)
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
    var tone: TezTone = .neutral
    var body: some View {
        TezOperationFeedback(message: message, details: details, tone: tone)
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
        .font(TezType.body)
        .padding(.vertical, 15)
    }
}

private enum ProfileManagementTarget: Identifiable {
    case create
    case manage(NativeProfileItem)

    var id: String {
        switch self { case .create: "create"; case .manage(let profile): "manage/\(profile.uid)" }
    }
    var profile: NativeProfileItem? {
        switch self { case .create: nil; case .manage(let profile): profile }
    }
}

private struct LiveProfilesView: View {
    let snapshot: NativeSnapshot
    let store: NativeBackendStore
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var selectedID: String?
    @State private var search = ""
    @State private var enhancementsExpanded = false
    @State private var editingProfile: NativeProfileItem?
    @State private var managementTarget: ProfileManagementTarget?

    private var canEdit: Bool { store.supports("native_read_profile") && store.supports("native_save_profile") }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var filtered: [NativeProfileItem] {
        snapshot.profiles.items.filter { search.isEmpty || "\(LiveText.profileName($0)) \(LiveText.profileType($0.type))".localizedCaseInsensitiveContains(search) }
    }

    private var configurations: [NativeProfileItem] {
        filtered.filter { $0.type == "remote" || $0.type == "local" }
    }
    private var enhancements: [NativeProfileItem] {
        filtered.filter { isEnhancement($0) }
    }
    private var otherFiles: [NativeProfileItem] {
        filtered.filter { $0.type != "remote" && $0.type != "local" && !isEnhancement($0) }
    }

    private var selected: NativeProfileItem? {
        filtered.first { $0.uid == selectedID }
            ?? filtered.first { $0.uid == snapshot.profiles.current }
            ?? configurations.first
            ?? filtered.first
    }

    var body: some View {
        VStack(spacing: 0) {
            profileHeader
            Divider()
            if snapshot.profiles.items.isEmpty {
                TezEmptyState(title: snapshot.profiles.state == "error" ? "配置读取失败" : snapshot.profiles.state == "missing" ? "配置文件不可用" : "没有配置",
                              symbol: snapshot.profiles.state == "error" ? "exclamationmark.triangle" : "doc.text",
                              detail: snapshot.profiles.message.map(LiveText.message) ?? "后台未返回配置。")
            } else {
                HSplitView {
                    profileSidebar
                    profileDetailPane
                }
                .sheet(item: $editingProfile) { profile in NativeProfileEditor(profile: profile, store: store) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $managementTarget) { target in
            NativeSubscriptionSheet(store: store, profile: target.profile).environment(preferences)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc").font(.system(size: 22)).foregroundStyle(TezStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("配置与订阅").font(TezType.page)
                Text("\(snapshot.profiles.items.filter { $0.type == "remote" || $0.type == "local" }.count) 份配置 · \(snapshot.profiles.items.filter { isEnhancement($0) }.count) 个增强文件")
                    .font(TezType.metadata).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("添加配置", systemImage: "plus") { managementTarget = .create }
                .disabled(!store.supports("native_import_subscription"))
                .accessibilityIdentifier("live.profiles.add")
        }
        .padding(.horizontal, TezStyle.pageInset).frame(height: 72)
        .background { TezContentMaterial(material: .headerView) }
    }

    private var profileSidebar: some View {
        VStack(spacing: 0) {
            TezSearchField(prompt: "搜索配置", text: Binding(get: { search }, set: {
                if let selected { selectedID = selected.uid }
                search = $0
            }), identifier: "live.profiles.search")
                .padding(12)
            Divider()
            List(selection: Binding(get: { selected?.uid }, set: { if let id = $0 { selectedID = id } })) {
                if !configurations.isEmpty {
                    Section("配置") {
                        ForEach(configurations) { profileRow($0) }
                    }
                }
                if !enhancements.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || enhancementsExpanded }, set: { enhancementsExpanded = $0 })) {
                        ForEach(enhancements) { profileRow($0) }
                    } label: {
                        Text("增强文件（\(enhancements.count)）")
                            .font(TezType.body.weight(.medium))
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
            // A new result set must not restore rows through AppKit's automatic-height diff.
            .id(search)
            .accessibilityIdentifier("live.profiles.list")
            Divider()
            HStack {
                Text(search.isEmpty ? "\(snapshot.profiles.items.count) 个文件" : "\(filtered.count) 个匹配文件")
                Spacer()
            }.font(TezType.metadata).foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(height: 28)
        }
        .frame(minWidth: 200, idealWidth: 236, maxWidth: 280)
    }

    private var profileDetailPane: some View {
        ScrollView {
            if let profile = selected {
                profileDetails(profile).id(profile.uid).transition(.opacity)
            } else {
                TezEmptyState(title: "没有匹配的配置", symbol: "magnifyingglass")
                    .frame(minHeight: 240)
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .animation(motion.feedback, value: selected?.uid)
    }

    private func profileDetails(_ profile: NativeProfileItem) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text(LiveText.profileName(profile)).font(TezType.page)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                TezStatusLabel(title: profile.uid == snapshot.profiles.current ? "当前配置" : isEnhancement(profile) ? "增强文件" : "非当前配置",
                               tone: profile.uid == snapshot.profiles.current ? .success : .neutral,
                               symbol: profile.uid == snapshot.profiles.current ? "checkmark.circle.fill" : "doc.text", motion: motion)
                HStack(spacing: 10) {
                    if profile.type == "remote" || profile.type == "local" {
                        Button("管理配置", systemImage: "slider.horizontal.3") { managementTarget = .manage(profile) }
                            .modifier(TezPrimaryActionStyle())
                            .disabled(!store.supports("native_subscription_details"))
                            .accessibilityIdentifier("live.profiles.manage")
                    }
                    Button("编辑内容", systemImage: "square.and.pencil") {
                        guard canEdit else { return }
                        editingProfile = profile
                    }
                        .disabled(!canEdit).accessibilityIdentifier("live.profiles.edit")
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    TezDetailField(title: "来源", value: LiveText.profileType(profile.type)).frame(minWidth: 80)
                    TezDetailField(title: "更新时间", value: updatedTime(profile.updated)).frame(minWidth: 140)
                }
                VStack(alignment: .leading, spacing: 18) {
                    TezDetailField(title: "来源", value: LiveText.profileType(profile.type))
                    TezDetailField(title: "更新时间", value: updatedTime(profile.updated))
                }
            }
            if !canEdit {
                TezStatusLabel(title: "内容编辑不可用", symbol: "lock")
                    .help("当前后台未开放配置内容编辑。")
            }
            if let message = snapshot.profiles.message {
                TezOperationFeedback(message: LiveText.message(message), tone: snapshot.profiles.state == "ready" ? .neutral : .warning)
            }
            Divider()
            DisclosureGroup("文件详情") {
                VStack(alignment: .leading, spacing: 16) {
                    TezDetailField(title: "配置标识", value: profile.uid)
                    TezDetailField(title: "读取状态", value: LiveText.state(snapshot.profiles.state))
                }.padding(.top, 12)
            }.font(TezType.body)
        }
        .padding(TezStyle.pageInset)
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("live.profiles.detail")
    }

    private func profileRow(_ profile: NativeProfileItem) -> some View {
        TezProfileRow(title: LiveText.profileName(profile), subtitle: LiveText.profileType(profile.type),
                      symbol: profile.type == "remote" ? "arrow.down.doc" : isEnhancement(profile) ? "doc.badge.gearshape" : "doc.text",
                      current: snapshot.profiles.current == profile.uid)
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var groupName: String?
    @State private var selectedID: String?
    @State private var search = ""
    @State private var switching = false
    @State private var switchMessage: String?
    @State private var switchDetails: String?
    @State private var switchTone: TezTone = .neutral
    let latency: NativeLatencyModel
    @State private var latencyURL = "https://www.gstatic.com/generate_204"
    @State private var latencyTimeout = 5000
    @State private var showsChains = false
    @State private var sortOrder: [LiveRouteLatencyComparator] = []
    @State private var comparison = NativeRouteComparisonSelection()
    @State private var showsComparison = false
    @State private var measurementEmphasis: Set<String> = []
    @State private var showsSampler = false
    @State private var switchChange: NativeRouteSwitchChange?
    @State private var samplerState = NativeRouteSamplerState()

    private var supportsSelection: Bool { store.supports("native_select_route") }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var canSwitch: Bool {
        selected.map(canSwitch(to:)) ?? false
    }
    private func canSwitch(to selected: LiveRouteMember) -> Bool {
        guard store.state == .connected, supportsSelection, !switching, !store.workspaceBusy, !latency.busy, let group, selected.isResolved, !selected.isCurrent else { return false }
        return ["selector", "urltest", "fallback"].contains(group.type.lowercased().replacingOccurrences(of: "-", with: ""))
            && rows.filter { $0.member.name == selected.member.name }.count == 1
    }

    private var mode: String? { snapshot.network?.mode.state == "ready" ? snapshot.network?.mode.value : nil }
    private var groups: [NativeProxyGroup] {
        snapshot.proxyView.map { NativeRoutePresentation.groups(in: $0, mode: mode) } ?? []
    }
    private var group: NativeProxyGroup? { groups.first { $0.name == groupName } ?? groups.first }
    private var rows: [LiveRouteMember] {
        guard let view = snapshot.proxyView else { return [] }
        let members = group?.members ?? view.standalone.compactMap { id in
            view.records[id].map { NativeProxyMember(kind: "node", name: $0.name, recordId: id, reason: nil) }
        }
        return members.enumerated().map { index, member in
            LiveRouteMember(member: member, index: index, view: view, isCurrent: group?.now == member.name,
                            measuredLatency: latency.results[member.name], sessionMeasuredAt: latency.measuredAt[member.name])
        }
    }
    private var visibleRows: [LiveRouteMember] {
        rows.filter { search.isEmpty || "\($0.name) \($0.type) \($0.source)".localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }
    private var selected: LiveRouteMember? { visibleRows.first { $0.id == selectedID } }
    private var comparisonRows: [LiveRouteMember] {
        comparison.ids.compactMap { id in rows.first { $0.id == id } }
    }
    var body: some View {
        if let view = snapshot.proxyView {
            GeometryReader { geometry in
                let compact = geometry.size.width < 700 || geometry.size.height < 560
                VStack(spacing: 0) {
                    groupContext(compact: compact)
                    Divider()
                    filterBar
                    Divider()
                    if view.providerState == "unavailable" {
                        HStack {
                            Label("订阅提供方数据不可用", systemImage: "exclamationmark.circle")
                            Spacer()
                        }
                        .font(TezType.metadata).foregroundStyle(.secondary)
                        .padding(.horizontal, TezStyle.pageInset).padding(.vertical, 9)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                    TezInspectorLayout(isPresented: selected != nil, selectionID: selectedID, reservesBottomSpace: true,
                                       bottomHeight: (compact ? 56 : 88) + (switchMessage != nil || latency.error != nil ? 96 : 0),
                                       motion: motion) {
                        routeList(showProtocol: preferences.showProtocol && geometry.size.width >= 700)
                            .background(TezTableSelectionVisibility(selectionID: selectedID))
                    } inspector: { side in
                        if side { sideInspector } else { detailRail(compact: compact) }
                    }
                    Divider()
                    routeFooter
                }
            }
            .onChange(of: group?.name) { _, _ in
                selectedID = nil
                switchMessage = nil
                switchDetails = nil
                comparison.clear()
                switchChange = nil
                showsSampler = false
                samplerState.reset()
            }
            .sheet(isPresented: $showsChains) { NativeProxyChainView(store: store) }
            .sheet(isPresented: $showsComparison) { comparisonSheet }
            .onChange(of: rows.map(\.id)) { _, ids in
                comparison.retain(Set(ids))
            }
            .onChange(of: mode) { _, _ in groupName = nil }
            .onChange(of: snapshot.profiles.current) { _, _ in
                comparison.clear()
                groupName = nil
                selectedID = nil
                switchChange = nil
                samplerState.reset()
            }
            .onChange(of: latency.measuredAt) { old, new in
                measurementEmphasis = Set(new.keys.filter { old[$0] != new[$0] })
            }
            .task(id: measurementEmphasis) {
                guard !measurementEmphasis.isEmpty else { return }
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                measurementEmphasis = []
            }
            .onChange(of: selectedID) { _, _ in
                if !switching {
                    switchMessage = nil
                    switchDetails = nil
                    switchChange = nil
                }
                showsSampler = false
                samplerState.reset()
            }
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

    private func groupContext(compact: Bool) -> some View {
        NativeRouteContextHeader(groups: groups, group: group, groupName: $groupName, mode: mode,
                                 groupType: group.map { LiveText.groupType($0.type) } ?? "独立线路",
                                 currentName: NativeRoutePresentation.title(LiveText.name(group?.now ?? "", fallback: "后台未提供当前选择")),
                                 previewName: selected.flatMap { $0.isCurrent ? nil : $0.name },
                                 change: switchChange, changeTone: switchTone, connected: store.state == .connected,
                                 switching: switching, compact: compact, motion: motion)
    }

    private var filterBar: some View {
        HStack(spacing: 16) {
          HStack(spacing: 8) {
            TezSearchField(prompt: "搜索线路", text: $search, identifier: "live.routes.search",
                           surface: Color(nsColor: .textBackgroundColor))
            .frame(minWidth: 130, maxWidth: 360)
          }
          Spacer(minLength: 0)
          HStack(spacing: 8) {
            if latency.busy {
                ProgressView(value: Double(latency.completed), total: Double(max(1, latency.total))).frame(width: 54)
                Button("停止测速", systemImage: "stop.fill") { latency.stopAfterCurrentBatch() }
                    .labelStyle(.iconOnly).help("当前批次结束后停止")
            } else {
                Button("测速", systemImage: "speedometer") { testLatency(visibleRows) }
                    .disabled(!canTest(visibleRows))
                    .help("测试当前筛选结果的延迟，不切换线路")
            }
          }
          .frame(width: 94, alignment: .trailing)
          HStack(spacing: 8) {
            Button("对比线路", systemImage: comparison.ids.isEmpty ? "square.split.2x2" : "square.split.2x2.fill") {
                showsComparison = true
            }
            .labelStyle(.iconOnly).help("对比线路（\(comparison.ids.count)/3）")
            .accessibilityValue("\(comparison.ids.count) 条候选线路")
            .accessibilityIdentifier("live.routes.compare")
            .overlay(alignment: .topTrailing) {
                if !comparison.ids.isEmpty {
                    Text("\(comparison.ids.count)").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 3).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: 4, y: -5).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            Button("链式代理", systemImage: "link") { showsChains = true }
                .labelStyle(.iconOnly).help("链式代理管理")
                .disabled(!store.supports("native_get_proxy_chains"))
                .accessibilityIdentifier("live.routes.chains")
          }
        }
        .font(TezType.body)
        .padding(.horizontal, TezStyle.pageInset)
        .frame(height: 48)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func routeList(showProtocol: Bool) -> some View {
        Group {
            if visibleRows.isEmpty {
                ContentUnavailableView(search.isEmpty ? "没有线路" : "没有匹配的线路",
                                       systemImage: search.isEmpty ? "network" : "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } else if showProtocol {
                Table(visibleRows, selection: $selectedID, sortOrder: $sortOrder) {
                    routeIconColumn
                    routeNameColumn
                    TableColumn("协议 / 类型") { row in
                        Text(row.type).foregroundStyle(.secondary).lineLimit(1).help(row.type)
                    }.width(120)
                    routeLatencyColumn
                    routeStatusColumn
                }
            } else {
                Table(visibleRows, selection: $selectedID, sortOrder: $sortOrder) {
                    routeIconColumn
                    routeNameColumn
                    routeLatencyColumn
                    routeStatusColumn
                }
            }
        }
        .font(TezType.body)
        .accessibilityIdentifier("live.routes.table")
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = visibleRows.first(where: { $0.id == id }) {
                if row.member.kind == "group", groups.contains(where: { $0.name == row.member.name }) {
                    Button("查看子分组", systemImage: "rectangle.3.group") { groupName = row.member.name }
                }
                Button("复制名称", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.name, forType: .string)
                }
                Button(comparison.contains(row.id) ? "移出对比" : "加入对比",
                       systemImage: comparison.contains(row.id) ? "pin.slash" : "pin") {
                    toggleComparison(row)
                }
                .disabled(!comparison.contains(row.id) && comparison.isFull)
                Button("测试延迟", systemImage: "speedometer") { testLatency([row]) }
                    .disabled(!canTest([row]))
            }
        }
    }

    private var routeIconColumn: some TableColumnContent<LiveRouteMember, Never> {
        TableColumn("") { (row: LiveRouteMember) in
            Image(systemName: row.member.kind == "group" ? "rectangle.3.group" : row.isResolved ? "point.3.connected.trianglepath.dotted" : "questionmark.circle")
                .foregroundStyle(.secondary).frame(minHeight: 40).accessibilityHidden(true)
        }.width(24).alignment(.center)
    }

    private var routeNameColumn: some TableColumnContent<LiveRouteMember, Never> {
        TableColumn("线路 / 子分组") { (row: LiveRouteMember) in
            Text(row.name).lineLimit(1).help(row.name)
        }.width(min: 150, ideal: 300)
    }

    private var routeLatencyColumn: some TableColumnContent<LiveRouteMember, LiveRouteLatencyComparator> {
        TableColumn("延迟", sortUsing: LiveRouteLatencyComparator()) { (row: LiveRouteMember) in
            VStack(alignment: .trailing, spacing: 3) {
                latencyValue(row, inheritsForeground: true)
                measurementLabel(row)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(measurementEmphasis.contains(row.member.name) ? TezStyle.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .animation(motion.feedback, value: measurementEmphasis.contains(row.member.name))
        }.width(146).alignment(.trailing)
    }

    private var routeStatusColumn: some TableColumnContent<LiveRouteMember, Never> {
        TableColumn("分组状态") { (row: LiveRouteMember) in
         Group {
          if row.isCurrent || !row.isResolved || row.member.kind == "group" {
            TezStatusLabel(title: row.isCurrent && store.state != .connected ? "上次选择" : row.status,
                           tone: row.isCurrent && row.isResolved && store.state == .connected ? .success : .neutral,
                           symbol: row.isCurrent && row.isResolved ? "checkmark.circle.fill" : nil, motion: motion,
                           inheritsForeground: true)
                .transition(.opacity)
          }
         }.animation(motion.feedback, value: row.isCurrent)
        }.width(110).alignment(.trailing)
    }

    private func latencyValue(_ row: LiveRouteMember, inheritsForeground: Bool = false) -> some View {
        TezLatencyValue(label: latency.label(for: row.member.name, fallback: row.latency),
                        testing: latency.testing.contains(row.member.name),
                        failed: row.measuredLatency.map { $0.error != nil || ($0.delay ?? 0) == 0 }
                            ?? (row.latency == "超时"), motion: motion,
                        inheritsForeground: inheritsForeground)
    }

    private func measurementLabel(_ row: LiveRouteMember) -> some View {
        Group {
            if row.measurement.origin != .none {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text("\(row.measurement.originLabel) · \(row.measurement.relativeAge(at: Date()))")
                        .font(TezType.metadata).lineLimit(1)
                        .help("\(row.measurement.originLabel)：\(row.measurement.exactTime)")
                        .accessibilityLabel("\(row.measurement.originLabel)，\(row.measurement.exactTime)")
                }
            }
        }
    }

    private func toggleComparison(_ row: LiveRouteMember) {
        if comparison.contains(row.id) { comparison.remove(row.id) }
        else { comparison.add(row.id) }
    }

    private var comparisonSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("线路对比").font(TezType.page)
                Text("\(comparisonRows.count) / 3").font(TezType.metadata).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Menu {
                    ForEach(rows.filter { !comparison.contains($0.id) }) { row in
                        Button(row.isCurrent ? "此组已选 · \(row.name)" : row.name) { comparison.add(row.id) }
                    }
                } label: {
                    Label("添加候选", systemImage: "plus")
                }
                .disabled(comparison.isFull || rows.allSatisfy { comparison.contains($0.id) })
                .accessibilityIdentifier("live.routes.compare.add")
                Button("清空", systemImage: "trash") { comparison.clear() }
                    .labelStyle(.iconOnly).help("清空候选线路")
                    .disabled(comparison.ids.isEmpty)
                    .accessibilityIdentifier("live.routes.compare.clear")
                Button("关闭", systemImage: "xmark") { showsComparison = false }
                    .labelStyle(.iconOnly).help("关闭对比").keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("live.routes.compare.close")
            }
            .padding(20)
            Divider()
            if comparisonRows.isEmpty {
                ContentUnavailableView("尚无候选线路", systemImage: "square.split.2x2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    comparisonGrid.padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let switchMessage {
                    LiveCommandFeedback(message: switchMessage, details: switchDetails, tone: switchTone)
                }
                if let error = latency.error { TezOperationFeedback(message: error, tone: .error) }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("测速地址：\(latencyURL)").lineLimit(1).help(latencyURL)
                        Text("延迟不代表端到端连接状态。")
                        Text("更改此分组的选择可能中断相关连接。")
                    }
                    .font(TezType.metadata).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if latency.busy {
                        ProgressView(value: Double(latency.completed), total: Double(max(1, latency.total)))
                            .frame(width: 64)
                        Button("停止测速", systemImage: "stop.fill") { latency.stopAfterCurrentBatch() }
                            .labelStyle(.iconOnly).help("当前批次结束后停止")
                    } else {
                        Button("重新测速", systemImage: "speedometer") { testLatency(comparisonRows) }
                            .disabled(!canTest(comparisonRows))
                            .accessibilityIdentifier("live.routes.compare.retest")
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 700, height: 490)
        .background(Color(nsColor: .textBackgroundColor))
        .animation(motion.feedback, value: comparison.ids)
        .accessibilityIdentifier("live.routes.comparison")
    }

    private var comparisonGrid: some View {
        let candidates = comparisonRows
        let width = (660 - 72 - CGFloat(candidates.count) * 12) / CGFloat(max(1, candidates.count))
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 16) {
            GridRow(alignment: .top) {
                Text("线路").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                ForEach(candidates) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 4) {
                            Text(row.name).fontWeight(.semibold).lineLimit(3).help(row.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("移出对比", systemImage: "pin.slash") { comparison.remove(row.id) }
                                .labelStyle(.iconOnly).help("移出对比：\(row.name)")
                                .accessibilityIdentifier("live.routes.compare.remove.\(row.id)")
                        }
                        TezStatusLabel(title: row.isCurrent && store.state != .connected ? "上次选择" : row.status,
                                       tone: row.isCurrent && store.state == .connected ? .success : .neutral, motion: motion)
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            Divider().gridCellColumns(candidates.count + 1)
            GridRow {
                Text("延迟").foregroundStyle(.secondary)
                ForEach(candidates) { row in
                    latencyValue(row)
                        .frame(width: width, alignment: .leading)
                        .padding(.vertical, 4)
                        .background(measurementEmphasis.contains(row.member.name) ? TezStyle.accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        .animation(motion.feedback, value: measurementEmphasis.contains(row.member.name))
                }
            }
            GridRow(alignment: .top) {
                Text("最近测速").foregroundStyle(.secondary)
                ForEach(candidates) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        measurementLabel(row)
                        Text(row.measurement.exactTime).font(TezType.metadata).foregroundStyle(.secondary)
                            .lineLimit(3).textSelection(.enabled)
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            GridRow(alignment: .top) {
                Text("协议 / 类型").foregroundStyle(.secondary)
                ForEach(candidates) { row in
                    Text(row.type).lineLimit(3).help(row.type).frame(width: width, alignment: .leading)
                }
            }
            GridRow(alignment: .top) {
                Text("来源").foregroundStyle(.secondary)
                ForEach(candidates) { row in
                    Text(row.source).lineLimit(3).help(row.source).frame(width: width, alignment: .leading)
                }
            }
            Divider().gridCellColumns(candidates.count + 1)
            GridRow {
                Color.clear.frame(width: 72, height: 1).accessibilityHidden(true)
                ForEach(candidates) { row in
                    let waiting = switching && switchChange?.group == group?.name && switchChange?.target == row.member.name
                    Button {
                        guard let group else { return }
                        switchRoute(row, in: group)
                    } label: {
                        routeSelectionLabel(isCurrent: row.isCurrent, waiting: waiting)
                            .opacity(waiting ? 0 : 1)
                    }
                    .disabled(!canSwitch(to: row))
                    .overlay { routeSelectionProgress(waiting: waiting) }
                    .accessibilityLabel(routeSelectionTitle(isCurrent: row.isCurrent, waiting: waiting))
                    .help(waiting ? "等待后台确认切换到 \(row.name)" : row.isCurrent ? "此分组已经选中该成员" : "将此分组切换到 \(row.name)，相关连接可能中断")
                    .accessibilityIdentifier("live.routes.compare.select.\(row.id)")
                    .frame(width: width, alignment: .leading)
                }
            }
        }
        .font(TezType.body)
    }

    private func canTest(_ candidates: [LiveRouteMember]) -> Bool {
        store.state == .connected && store.supports("native_test_latency") && !store.workspaceBusy
            && !latency.busy && !switching && !testable(candidates).isEmpty
    }

    private func detailRail(compact: Bool) -> some View {
      ScrollView {
        VStack(spacing: 0) {
            routeDetails(compact: compact)
                .padding(.horizontal, TezStyle.pageInset)
                .frame(height: compact ? 56 : 88)
            if switchMessage != nil || latency.error != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let switchMessage {
                        LiveCommandFeedback(message: switchMessage, details: switchDetails, tone: switchTone)
                    }
                    if let error = latency.error {
                        TezOperationFeedback(message: error, tone: .error)
                    }
                }
                .padding(.horizontal, TezStyle.pageInset).padding(.bottom, 12)
                .transition(.opacity)
            }
        }
      }
      .background { TezContentMaterial(material: .contentBackground) }
    }

    private var routeFooter: some View {
        HStack(spacing: 16) {
                Text(search.isEmpty ? "\(rows.count) 个成员" : "\(visibleRows.count) / \(rows.count) 个成员")
                Spacer()
                if latency.total > 0 {
                    Text("测速 \(latency.completed) / \(latency.total)\(latency.stopped ? " · 已停止" : "")")
                        .monospacedDigit()
                }
                if !supportsSelection { Label("只读", systemImage: "eye") }
            }
            .font(TezType.metadata).foregroundStyle(.secondary)
            .padding(.horizontal, TezStyle.pageInset)
            .frame(height: 28)
    }

    private var sideInspector: some View {
      VStack(spacing: 0) {
        ScrollView {
            if let row = selected {
                VStack(alignment: .leading, spacing: 24) {
                  VStack(alignment: .leading, spacing: 6) {
                    TezInspectorHeader(title: row.name, titleFont: TezType.itemTitle) { selectedID = nil }
                    TezStatusLabel(title: row.isCurrent ? (store.state == .connected ? "此组已选" : "上次选择") : "仅查看，尚未切换",
                                   tone: row.isCurrent && store.state == .connected ? .success : .neutral, motion: motion)
                  }
                  VStack(alignment: .leading, spacing: 8) {
                    TezDetailField(title: "协议 / 类型", value: row.type)
                    TezDetailField(title: "来源", value: row.source)
                  }
                    sampler(row)
                    DisclosureGroup("线路详情") {
                        TezDetailField(title: "UDP", value: row.udp.map { $0 ? "支持" : "不支持" } ?? "未提供")
                            .padding(.top, 8)
                        TezDetailField(title: row.measurement.originLabel, value: row.measurement.exactTime)
                            .padding(.top, 8)
                    }
                    .font(TezType.metadata)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            routeActions(showsSample: false)
            Text("更改此分组的选择可能中断相关连接。")
                .font(TezType.metadata).foregroundStyle(.secondary)
            if let switchMessage { LiveCommandFeedback(message: switchMessage, details: switchDetails, tone: switchTone) }
            if let error = latency.error { TezOperationFeedback(message: error, tone: .error) }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("live.routes.actionRail")
      }
        .background { TezContentMaterial(material: .contentBackground) }
        .accessibilityIdentifier("live.routes.sideInspector")
    }

    private func routeDetails(compact: Bool) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                if !compact {
                    HStack(spacing: 8) {
                        Text(selected == nil ? "未选择线路" : "查看中")
                            .font(TezType.metadata).foregroundStyle(.secondary)
                        if selected?.isCurrent == true {
                            TezStatusLabel(title: store.state == .connected ? "此组已选" : "上次选择",
                                           tone: store.state == .connected ? .success : .neutral, motion: motion)
                        }
                    }
                }
                if let row = selected {
                    Text(row.name).font(TezType.itemTitle)
                        .lineLimit(compact ? 1 : 2).help(row.name).textSelection(.enabled)
                    Text(compact ? "\(row.isCurrent ? (store.state == .connected ? "此组已选" : "上次选择") : "仅查看") · \(row.type) · \(row.source)"
                         : "\(row.type) · \(row.source) · UDP \(row.udp.map { $0 ? "支持" : "不支持" } ?? "未提供")")
                        .font(TezType.body).foregroundStyle(.secondary).lineLimit(1)
                        .help("\(row.source)\n\(row.measurement.originLabel)：\(row.measurement.exactTime)")
                } else {
                    Text(supportsSelection ? "选择线路以查看详情" : "当前后台未开放线路切换")
                        .font(TezType.body).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("live.routes.preview")
            routeActions(showsSample: selected != nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func routeActions(showsSample: Bool) -> some View {
        HStack(spacing: 8) {
                if let selected {
                    if showsSample {
                        Button("延迟采样", systemImage: "waveform.path") { showsSampler.toggle() }
                            .labelStyle(.iconOnly).help("查看真实延迟采样与保持读数")
                            .accessibilityIdentifier("live.routes.sample.open")
                            .popover(isPresented: $showsSampler, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(selected.name).font(TezType.itemTitle).lineLimit(2).help(selected.name)
                                    sampler(selected, compact: true)
                                }
                                .padding(16).frame(width: 300)
                            }
                    }
                    Button(comparison.contains(selected.id) ? "移出对比" : "加入对比",
                           systemImage: comparison.contains(selected.id) ? "pin.fill" : "pin") {
                        toggleComparison(selected)
                    }
                    .labelStyle(.iconOnly)
                    .help(comparison.contains(selected.id) ? "移出对比" : comparison.isFull ? "最多对比 3 条线路" : "加入对比（\(comparison.ids.count)/3）")
                    .disabled(!comparison.contains(selected.id) && comparison.isFull)
                    .accessibilityIdentifier("live.routes.pin")
                }
                Button { switchRoute() } label: {
                    routeSelectionLabel(isCurrent: selected?.isCurrent == true, waiting: switching)
                        .opacity(switching ? 0 : 1)
                }
                    .modifier(TezPrimaryActionStyle())
                    .disabled(!canSwitch)
                    .overlay { routeSelectionProgress(waiting: switching) }
                    .accessibilityLabel(routeSelectionTitle(isCurrent: selected?.isCurrent == true, waiting: switching))
                    .help(switchHelp)
                    .accessibilityIdentifier("live.routes.select")
            }
            .fixedSize()
    }

    private func routeSelectionLabel(isCurrent: Bool, waiting: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if waiting { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: isCurrent ? (store.state == .connected ? "checkmark.circle" : "clock") : "arrow.right")
                        .contentTransition(motion.symbol)
                }
            }.frame(width: 14, height: 14)
            Text(routeSelectionTitle(isCurrent: isCurrent, waiting: waiting))
                .font(TezType.body).frame(width: 78)
        }
        .animation(motion.feedback, value: isCurrent)
        .animation(motion.feedback, value: waiting)
    }

    private func routeSelectionTitle(isCurrent: Bool, waiting: Bool) -> String {
        waiting ? "等待确认" : isCurrent ? (store.state == .connected ? "此组已选" : "上次选择") : "切换此分组"
    }

    private func routeSelectionProgress(waiting: Bool) -> some View {
        // Pending status stays outside the disabled control to retain readable contrast.
        Group {
            if waiting {
                routeSelectionLabel(isCurrent: false, waiting: true)
                    .foregroundStyle(.primary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .animation(motion.feedback, value: waiting)
    }

    private func sampler(_ row: LiveRouteMember, compact: Bool = false) -> some View {
        let session = latency.samples[row.member.name] ?? []
        return NativeRouteSampler(state: samplerState, samples: session.isEmpty ? row.samples : session,
                                  origin: session.isEmpty ? row.measurement.originLabel : "本次会话",
                                  testing: latency.testing.contains(row.member.name), canSample: canTest([row]),
                                  testURL: latencyURL, motion: motion, compact: compact) { testLatency([row]) }
            .id(row.id)
    }

    private var switchHelp: String {
        if store.state != .connected { return "后台未连接，无法切换线路" }
        if !supportsSelection { return "当前后台仅支持只读访问" }
        if switching { return "等待后台确认切换结果" }
        if store.workspaceBusy || latency.busy { return "当前操作完成后可以切换线路" }
        guard let selected else { return "尚未选择线路" }
        if selected.isCurrent { return "此分组已经选中该成员" }
        if !canSwitch { return "此分组或成员不支持手动切换" }
        return "将「\(NativeRoutePresentation.title(group?.name ?? ""))」切换到「\(selected.name)」，相关连接可能中断"
    }

    private func switchRoute() {
        guard canSwitch, let group, let selected else { return }
        switchRoute(selected, in: group)
    }

    private func switchRoute(_ selected: LiveRouteMember, in group: NativeProxyGroup) {
        guard canSwitch(to: selected) else { return }
        let profileID = snapshot.profiles.current
        switching = true
        switchChange = NativeRouteSwitchChange(group: group.name, target: selected.member.name)
        switchTone = .neutral
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
                switchChange?.outcome = applied ? .applied : .notApplied
                let cleanupIncomplete: Bool
                if case .object(let cleanup) = value["connectionCleanup"] {
                    cleanupIncomplete = cleanup["requested"] == .bool(true) && cleanup["completed"] != .bool(true)
                } else {
                    cleanupIncomplete = false
                }
                if applied && cleanupIncomplete {
                    switchTone = .warning
                    switchMessage = persisted
                        ? "「\(NativeRoutePresentation.title(group.name))」已切换并保存，但部分旧连接未能关闭。请检查详情。"
                        : "「\(NativeRoutePresentation.title(group.name))」已切换，但选择保存和旧连接清理未完成。请检查详情。"
                } else if applied && persisted {
                    switchTone = .success
                    switchMessage = "「\(NativeRoutePresentation.title(group.name))」已选择 \(selected.name)，选择已保存。"
                } else if applied {
                    switchTone = .warning
                    switchMessage = "「\(NativeRoutePresentation.title(group.name))」已切换，但选择未保存；重新启动后可能丢失。"
                } else {
                    switchTone = .error
                    switchMessage = "「\(NativeRoutePresentation.title(group.name))」未切换，保留原选择。请检查详情与后台状态。"
                }
                if applied {
                    preferences.recordRoute(profileID: profileID, group: group.name, name: selected.member.name)
                }
                switchDetails = LiveCommandFeedback.render(result)
            } catch {
                switchChange?.outcome = .unconfirmed
                switchTone = .error
                switchMessage = "「\(NativeRoutePresentation.title(group.name))」切换请求失败。请核对后台选择；不会自动重试。"
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
        guard canTest(candidates) else { return }
        Task { @MainActor in
            await latency.test(names: names, url: latencyURL, timeout: latencyTimeout) { command, params in
                try await store.request(command, params: params, timeout: .seconds(150), serialWorkspace: true)
            }
            store.refresh()
        }
    }

}

struct LiveRouteMember: Identifiable {
    let member: NativeProxyMember
    let index: Int
    let view: NativeProxyView
    let isCurrent: Bool
    var measuredLatency: NativeLatencyPayload.Result? = nil
    var sessionMeasuredAt: Date? = nil
    var id: String { "\(index):\(member.kind):\(member.recordId ?? member.name)" }
    var name: String { NativeRoutePresentation.title(LiveText.name(member.name, fallback: member.kind == "group" ? "未命名分组" : "未命名线路")) }
    private var node: NativeProxyNode? {
        guard member.kind == "node", let id = member.recordId else { return nil }
        return view.records[id]
    }
    private var group: NativeProxyGroup? {
        guard member.kind == "group" else { return nil }
        return view.groups.first { $0.name == member.name } ?? (view.global?.name == member.name ? view.global : nil)
    }
    var isResolved: Bool { node != nil || group != nil }
    var type: String { node?.type ?? group.map { "分组 · \(LiveText.groupType($0.type))" } ?? "未解析" }
    var udp: Bool? { node?.udp ?? group?.udp }
    private var history: [NativeDelayHistory] { node?.history ?? group?.history ?? [] }
    private var latest: NativeDelayHistory? { history.last }
    var samples: [NativeLatencySample] {
        history.suffix(20).map {
            NativeLatencySample(date: NativeRouteMeasurement(sessionDate: nil, snapshotTime: $0.time).date,
                                delay: $0.delay > 0 ? $0.delay : nil)
        }
    }
    var sortDelay: UInt64? {
        if let measuredLatency {
            guard measuredLatency.error == nil, let delay = measuredLatency.delay, delay > 0 else { return nil }
            return UInt64(delay)
        }
        return latest.flatMap { $0.delay > 0 ? $0.delay : nil }
    }
    var latency: String { latest.map { $0.delay == 0 ? "超时" : "\($0.delay) ms" } ?? "未测速" }
    var measuredAt: String? { latest?.time }
    var measurement: NativeRouteMeasurement {
        NativeRouteMeasurement(sessionDate: sessionMeasuredAt, snapshotTime: measuredAt,
                               hasSessionResult: measuredLatency != nil)
    }
    var source: String {
        if let node {
            return node.source.providerName ?? (node.source.kind == "core" ? "内核" : node.source.kind)
        }
        return member.kind == "group" ? "分组" : "未提供"
    }
    var status: String {
        if isResolved && isCurrent { return "此组已选" }
        if isResolved { return member.kind == "group" ? "子分组" : "线路" }
        switch member.reason {
        case "provider-unavailable": return "提供方不可用"
        case "ambiguous": return "同名，未解析"
        case "missing": return "记录缺失"
        default: return "未解析"
        }
    }
}

struct LiveRouteLatencyComparator: SortComparator {
    var order: SortOrder = .forward

    func compare(_ lhs: LiveRouteMember, _ rhs: LiveRouteMember) -> ComparisonResult {
        switch (lhs.sortDelay, rhs.sortDelay) {
        case (.some(let left), .some(let right)) where left != right:
            return (left < right) == (order == .forward) ? .orderedAscending : .orderedDescending
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        default:
            if lhs.index == rhs.index { return .orderedSame }
            return lhs.index < rhs.index ? .orderedAscending : .orderedDescending
        }
    }
}

private enum LiveText {
    static func groupType(_ value: String) -> String {
        switch value.lowercased().replacingOccurrences(of: "-", with: "") {
        case "selector": "手动选择"
        case "urltest": "自动测速"
        case "fallback": "故障切换"
        case "loadbalance": "负载均衡"
        case "relay": "链式代理"
        default: value
        }
    }

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
