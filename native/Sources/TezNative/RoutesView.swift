import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class TezRoutesSession {
    var group = TezRouteGroup.everyday
    var scope = TezRouteScope.all
    var sort = TezRouteSort.recommended
    var search = ""
    var selectedID: String? = "jp-01"
    var favorites: Set<String> = ["hk-01", "jp-01"]
    var activeRoutes: [TezRouteGroup: String] = [
        .everyday: "hk-01", .streaming: "jp-01", .development: "sg-01",
    ]
    var hasPresentedRoutes = false

    private var activeRoute: TezRouteFixture? {
        TezRouteFixture.samples.first { $0.id == activeRoutes[group] }
    }

    var activeRouteName: String { activeRoute?.name ?? "未选择" }
    var activeRouteLocation: String { activeRoute?.location ?? "—" }
    var activeRouteLatency: Int? { activeRoute?.latency }
}

struct RoutesView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(TezPreviewPreferences.self) private var preferences
    @Bindable private var session: TezRoutesSession
    @State private var pendingID: String?
    @State private var applyTask: Task<Void, Never>?
    @State private var feedback: String?
    @State private var isVisible = false
    @FocusState private var focusedField: TezRouteFocus?

    init(session: TezRoutesSession = TezRoutesSession()) {
        self.session = session
    }

    private var reduceMotion: Bool { systemReduceMotion || preferences.reduceMotion }
    private var selectedRoute: TezRouteFixture? { route(withID: session.selectedID) }
    private var targetRoute: TezRouteFixture? { route(withID: pendingID) ?? selectedRoute }
    private var transitionAnimation: Animation? { reduceMotion ? nil : .spring(duration: 0.22, bounce: 0) }

    private var visibleRoutes: [TezRouteFixture] {
        let routes = TezRouteFixture.samples.filter {
            $0.groups.contains(session.group)
                && (session.scope == .all || session.favorites.contains($0.id))
                && (session.search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(session.search))
        }
        switch session.sort {
        case .recommended: return routes
        case .latency: return routes.sorted { ($0.latency ?? Int.max) < ($1.latency ?? Int.max) }
        case .name: return routes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = TezRouteColumns(width: geometry.size.width, showProtocol: preferences.showProtocol)
            VStack(spacing: 0) {
                switchbar(compact: geometry.size.width < 730)
                Divider()
                filterBar
                Divider()
                tableHeader(columns)
                routeList(columns)
                Divider()
                detailRail(compact: geometry.size.width < 730)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 4)
        }
        .navigationTitle("线路")
        .focusedSceneValue(\.tezRouteNavigation, TezRouteNavigation(
            enabled: focusedField != .search && !visibleRoutes.isEmpty,
            move: moveSelection
        ))
        .tint(TezStyle.accent)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack {
                Menu {
                    Picker("策略组", selection: $session.group) {
                        ForEach(TezRouteGroup.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Text(session.group.rawValue)
                }
                .frame(width: 125)
                .help("策略组")
                .accessibilityLabel("策略组：\(session.group.rawValue)")
                .menuStyle(.borderlessButton)
                .fixedSize()
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { focusedField = .search } label: {
                    Label("搜索线路", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("搜索线路")
            }
        }
        .onAppear {
            if session.hasPresentedRoutes {
                isVisible = true
            } else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { isVisible = true }
                session.hasPresentedRoutes = true
            }
        }
        .onChange(of: session.group) { _, _ in
            cancelApply()
            feedback = nil
            session.selectedID = session.activeRoutes[session.group]
            reconcileSelection()
        }
        .onChange(of: session.search) { _, _ in cancelApply(); reconcileSelection() }
        .onChange(of: session.scope) { _, _ in cancelApply(); reconcileSelection() }
        .onChange(of: session.favorites) { _, _ in reconcileSelection() }
        .onChange(of: session.selectedID) { _, selectedID in
            if let pendingID, pendingID != selectedID { cancelApply() }
        }
        .onDisappear { cancelApply() }
    }

    private func switchbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 16 : 28) {
            endpoint(title: "正在使用", name: session.activeRouteName, latency: session.activeRouteLatency, isActive: true, compact: compact)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: compact ? 16 : 20, weight: .light))
                .foregroundStyle(.tertiary)
                .opacity(showsTarget ? 1 : 0)
                .accessibilityHidden(true)
            endpoint(title: pendingID != nil ? "正在切换" : selectedState, name: targetRoute?.name ?? "选择线路", latency: targetRoute?.latency, isActive: false, compact: compact)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(showsTarget ? 1 : 0)
                .accessibilityHidden(!showsTarget)
            Group {
                if pendingID != nil {
                    Button("取消切换", role: .cancel) { cancelApply() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        if let route = selectedRoute { apply(route) }
                    } label: {
                        HStack(spacing: 8) {
                            Text(applyTitle)
                            if selectedRoute != nil && selectedRoute?.id != session.activeRoutes[session.group] {
                                Image(systemName: "arrow.right").font(.caption)
                            }
                        }
                    }
                    .modifier(TezPrimaryActionStyle())
                    .disabled(!canApply)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .frame(width: compact ? 145 : 170)
        }
        .padding(.horizontal, compact ? 20 : 28)
        .frame(height: compact ? 98 : 110)
        .background { TezContentMaterial(material: .headerView) }
        .animation(transitionAnimation, value: pendingID)
        .animation(transitionAnimation, value: showsTarget)
    }

    private var showsTarget: Bool {
        pendingID != nil || selectedRoute?.id != session.activeRoutes[session.group]
    }

    private var selectedState: String {
        guard let selectedRoute else { return "待选择" }
        if selectedRoute.id == session.activeRoutes[session.group] { return "当前线路" }
        return selectedRoute.latency == nil ? "不可用" : "待应用"
    }

    private var applyTitle: String {
        guard let selectedRoute else { return "选择线路" }
        if selectedRoute.latency == nil { return "线路不可用" }
        return selectedRoute.id == session.activeRoutes[session.group] ? "正在使用" : "切换到 \(selectedRoute.name)"
    }

    private var canApply: Bool {
        guard let selectedRoute else { return false }
        return selectedRoute.latency != nil && pendingID == nil && selectedRoute.id != session.activeRoutes[session.group]
    }

    private func endpoint(title: String, name: String, latency: Int?, isActive: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if isActive {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                } else if pendingID != nil {
                    ProgressView().controlSize(.mini)
                }
                Text(title).font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.secondary : Color.primary.opacity(0.65))
            }
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(name)
                    .font(.system(size: compact ? 19 : 22, weight: .semibold))
                    .foregroundStyle(isActive ? TezStyle.success : Color.primary)
                    .lineLimit(1)
                if !compact, let latency {
                    Text("\(latency) ms").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .contentTransition(.opacity)
            .animation(transitionAnimation, value: name)
        }
        .accessibilityElement(children: .combine)
    }

    private var filterBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索线路、地区或协议", text: $session.search)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .search)
                    .onExitCommand {
                        session.search = ""
                        focusedField = .list
                    }
                Button {
                    session.search = ""
                    focusedField = .search
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(session.search.isEmpty)
                .opacity(session.search.isEmpty ? 0 : 1)
                .help("清除搜索")
                .accessibilityLabel("清除搜索")
            }
            .padding(.horizontal, 9)
            .frame(height: 29)
            .frame(minWidth: 180, maxWidth: 300)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focusedField == .search ? TezStyle.accent : Color.primary.opacity(0.12))
            }
            Picker("显示线路", selection: $session.scope) {
                ForEach(TezRouteScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 112)
            Spacer(minLength: 0)
            Menu {
                Picker("排序", selection: $session.sort) {
                    ForEach(TezRouteSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("排序线路")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tableHeader(_ columns: TezRouteColumns) -> some View {
        HStack(spacing: 16) {
            Text("线路名称").frame(maxWidth: .infinity, alignment: .leading)
            if columns.region { Text("地区").frame(width: 100, alignment: .leading) }
            if columns.protocolName { Text("协议").frame(width: 106, alignment: .leading) }
            Text("延迟").frame(width: 74, alignment: .trailing)
            Text("状态").frame(width: 74, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 64)
        .padding(.trailing, 52)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func routeList(_ columns: TezRouteColumns) -> some View {
        ScrollViewReader { reader in
            List(selection: Binding(
                get: { session.selectedID },
                set: { session.selectedID = $0; focusedField = .list }
            )) {
                ForEach(visibleRoutes) { route in
                        TezRouteTableRow(route: route, columns: columns,
                            isActive: session.activeRoutes[session.group] == route.id,
                            isSelected: session.selectedID == route.id,
                            isFavorite: session.favorites.contains(route.id), isPending: pendingID == route.id)
                    .tag(route.id)
                    .id(route.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .contextMenu { contextMenu(route) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .focusable()
            .focusEffectDisabled()
            .focused($focusedField, equals: .list)
            .onExitCommand { if pendingID != nil { cancelApply() } }
            .simultaneousGesture(TapGesture().onEnded { focusedField = .list })
            .onChange(of: session.selectedID) { _, selection in
                if let selection, focusedField == .list { reader.scrollTo(selection) }
            }
            .overlay {
                if visibleRoutes.isEmpty {
                    ContentUnavailableView {
                        Label(session.search.isEmpty ? "没有收藏的线路" : "没有匹配的线路", systemImage: session.search.isEmpty ? "star" : "magnifyingglass")
                    } actions: {
                        Button(session.search.isEmpty ? "显示全部线路" : "清除搜索") {
                            if session.search.isEmpty { session.scope = .all } else { session.search = "" }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ route: TezRouteFixture) -> some View {
        Button("查看详情", systemImage: "info.circle") { session.selectedID = route.id }
        Button(session.favorites.contains(route.id) ? "取消收藏" : "收藏线路", systemImage: "star") {
            toggleFavorite(route.id)
        }
        Divider()
        Button("切换到 \(route.name)", systemImage: "arrow.triangle.branch") {
            session.selectedID = route.id
            apply(route)
        }
        .disabled(route.latency == nil || pendingID != nil || session.activeRoutes[session.group] == route.id)
        Button("复制线路名称", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(route.name, forType: .string)
        }
    }

    private func detailRail(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let route = selectedRoute {
                HStack(alignment: .top, spacing: compact ? 20 : 30) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(route.name).font(.system(size: 14, weight: .semibold))
                            Button { toggleFavorite(route.id) } label: {
                                Image(systemName: session.favorites.contains(route.id) ? "star.fill" : "star")
                                    .font(.system(size: 11))
                                    .foregroundStyle(session.favorites.contains(route.id) ? TezStyle.accent : Color.secondary)
                                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .help(session.favorites.contains(route.id) ? "取消收藏" : "收藏线路")
                            .accessibilityLabel(session.favorites.contains(route.id) ? "取消收藏" : "收藏线路")
                        }
                        Text("已选中线路").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: compact ? 116 : 140, alignment: .leading)
                    if preferences.showProtocol { detailPair("协议", value: route.transport) }
                    if !compact { detailPair("UDP", value: route.udp ? "支持" : "不支持") }
                    detailPair("服务器", value: route.host, monospaced: true)
                    Spacer(minLength: 0)
                }
                .id(route.id)
                .transition(.opacity)
            } else {
                Text("选择线路以查看详情")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(height: 38, alignment: .leading)
            }
            HStack {
                Text(feedback ?? "延迟为样例值")
                    .accessibilityAddTraits(.updatesFrequently)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(visibleRoutes.count) 条线路")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, compact ? 20 : 28)
        .frame(height: compact ? 98 : 108)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { TezContentMaterial(material: .contentBackground) }
        .animation(transitionAnimation, value: session.selectedID)
        .animation(transitionAnimation, value: feedback)
    }

    private func detailPair(_ title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private func route(withID id: String?) -> TezRouteFixture? {
        TezRouteFixture.samples.first { $0.id == id }
    }

    private func toggleFavorite(_ id: String) {
        withAnimation(transitionAnimation) {
            if session.favorites.contains(id) { session.favorites.remove(id) } else { session.favorites.insert(id) }
        }
    }

    private func reconcileSelection() {
        if !visibleRoutes.contains(where: { $0.id == session.selectedID }) {
            session.selectedID = visibleRoutes.first?.id
        }
    }

    private func moveSelection(by offset: Int) {
        let routes = visibleRoutes
        guard !routes.isEmpty else { return }
        let index = routes.firstIndex { $0.id == session.selectedID }
        let next = index.map { min(max($0 + offset, 0), routes.count - 1) } ?? (offset > 0 ? 0 : routes.count - 1)
        session.selectedID = routes[next].id
    }

    private func apply(_ route: TezRouteFixture) {
        guard route.latency != nil, pendingID == nil, session.activeRoutes[session.group] != route.id else { return }
        let targetGroup = session.group
        withAnimation(transitionAnimation) {
            pendingID = route.id
            feedback = nil
        }
        applyTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(1100)) } catch { return }
            guard !Task.isCancelled, session.group == targetGroup, session.selectedID == route.id else { return }
            withAnimation(transitionAnimation) {
                session.activeRoutes[targetGroup] = route.id
                pendingID = nil
                feedback = "预览已切换，系统网络未更改。"
            }
            applyTask = nil
        }
    }

    private func cancelApply() {
        applyTask?.cancel()
        applyTask = nil
        if pendingID != nil {
            withAnimation(transitionAnimation) {
                pendingID = nil
                feedback = "切换已取消"
            }
        }
    }
}

private enum TezRouteFocus: Hashable { case search, list }

private struct TezRouteColumns {
    let region: Bool
    let protocolName: Bool

    init(width: CGFloat, showProtocol: Bool) {
        region = width >= 770
        protocolName = showProtocol && width >= 700
    }
}

private struct TezRouteTableRow: View {
    let route: TezRouteFixture
    let columns: TezRouteColumns
    let isActive: Bool
    let isSelected: Bool
    let isFavorite: Bool
    let isPending: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: route.latency == nil ? "network.slash" : "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(isActive ? TezStyle.success : isSelected ? TezStyle.accent : Color.secondary)
                    .frame(width: 17)
                Text(route.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? TezStyle.accent : Color.primary)
                    .lineLimit(1)
                if isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                        .accessibilityLabel("收藏")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if columns.region { Text(route.region).foregroundStyle(.secondary).frame(width: 100, alignment: .leading) }
            if columns.protocolName { Text(route.transport).foregroundStyle(.secondary).frame(width: 106, alignment: .leading) }
            Text(route.latency.map { "\($0) ms" } ?? "超时")
                .monospacedDigit()
                .foregroundStyle(route.latency == nil ? Color.secondary : Color.primary.opacity(0.75))
                .frame(width: 74, alignment: .trailing)
            HStack(spacing: 5) {
                if isPending {
                    ProgressView().controlSize(.mini)
                    Text("切换中")
                } else if isActive {
                    Image(systemName: "checkmark")
                    Text("使用中")
                } else if route.latency == nil {
                    Text("不可用")
                } else if isSelected {
                    Text("待应用")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(isActive ? TezStyle.success : isSelected ? TezStyle.accent : Color.secondary)
            .frame(width: 74, alignment: .trailing)
        }
        .font(.system(size: 13))
        .frame(height: 43)
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) { Divider().opacity(isSelected ? 0 : 0.45) }
        .contentShape(Rectangle())
        .help("\(route.name) · \(route.location) · 延迟为样例值")
        .accessibilityElement(children: .combine)
    }
}

enum TezRouteGroup: String, CaseIterable, Identifiable, Sendable {
    case everyday = "日常网络"
    case streaming = "流媒体"
    case development = "开发工具"
    var id: Self { self }
}

enum TezRouteScope: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case favorites = "收藏"
    var id: Self { self }
}

enum TezRouteSort: String, CaseIterable, Identifiable, Sendable {
    case recommended = "订阅顺序"
    case latency = "样例延迟"
    case name = "名称"
    var id: Self { self }
}

private struct TezRouteFixture: Identifiable, Sendable {
    let id: String
    let name: String
    let location: String
    let region: String
    let transport: String
    let latency: Int?
    let udp: Bool
    let groups: Set<TezRouteGroup>
    var host: String { "\(id).example.invalid" }
    var searchText: String { "\(name) \(location) \(region) \(transport)" }

    static let samples: [Self] = [
        .init(id: "hk-01", name: "香港 01", location: "Hong Kong", region: "香港", transport: "Shadowsocks", latency: 28, udp: true, groups: [.everyday, .streaming, .development]),
        .init(id: "hk-02", name: "香港 02", location: "Hong Kong", region: "香港", transport: "Trojan", latency: 34, udp: true, groups: [.everyday, .streaming]),
        .init(id: "jp-01", name: "东京 01", location: "Tokyo, Japan", region: "日本", transport: "Hysteria 2", latency: 52, udp: true, groups: [.everyday, .streaming, .development]),
        .init(id: "jp-02", name: "大阪 01", location: "Osaka, Japan", region: "日本", transport: "Shadowsocks", latency: 61, udp: true, groups: [.everyday, .streaming]),
        .init(id: "sg-01", name: "新加坡 01", location: "Singapore", region: "新加坡", transport: "VLESS", latency: 76, udp: true, groups: [.everyday, .streaming, .development]),
        .init(id: "us-01", name: "洛杉矶 01", location: "Los Angeles, US", region: "美国", transport: "Trojan", latency: 148, udp: true, groups: [.everyday, .development]),
        .init(id: "de-01", name: "法兰克福 01", location: "Frankfurt, Germany", region: "德国", transport: "Shadowsocks", latency: 192, udp: false, groups: [.everyday, .development]),
        .init(id: "us-02", name: "圣何塞 02", location: "San Jose, US", region: "美国", transport: "VLESS", latency: nil, udp: true, groups: [.everyday, .development]),
    ]
}
