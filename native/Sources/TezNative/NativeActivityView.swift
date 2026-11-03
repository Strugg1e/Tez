import SwiftUI

struct NativeActivityView: View {
    @Bindable var store: NativeBackendStore
    @Bindable var session: NativeActivitySession
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isVisible = false
    @State private var pendingClose: NativeActivityConnection?

    private var tab: ActivityTab { session.tab }
    private var model: NativeActivityModel { session.model(for: tab) }
    private var paused: Bool { session.paused }
    private var canRead: Bool { store.supports("native_get_activity") }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var connections: [NativeActivityConnection] { model.snapshot?.connections.items ?? [] }
    private var rules: [NativeActivityRule] { model.snapshot?.rules.items ?? [] }
    private var providers: [NativeActivityProvider] { model.snapshot?.providers.items ?? [] }
    private var requestQuery: NativeActivityQuery { session.context.request(for: tab) }
    private var query: String { requestQuery.query }
    private var offset: UInt64 { requestQuery.offset }
    private var queryBinding: Binding<String> {
        Binding(get: { query }, set: { session.context.search($0, in: tab) })
    }
    private var pollKey: ActivityPollKey { ActivityPollKey(query: requestQuery, canRead: canRead) }
    private var showingRequestedPage: Bool { model.snapshotQuery == requestQuery }
    private var selectedConnection: NativeActivityConnection? { connections.first { $0.id == session.context.connectionID } }
    private var canClose: Bool {
        showingRequestedPage && store.supports("native_close_connection") && !store.workspaceBusy && model.closingID == nil && !model.isLoading
    }
    private var hasSelectedDetails: Bool {
        guard showingRequestedPage else { return false }
        return switch tab {
        case .connections: connections.contains { $0.id == session.context.connectionID }
        case .rules: rules.contains { $0.index == session.context.ruleID }
        case .providers: providers.contains { $0.name == session.context.providerID }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
                if tab == .connections {
                    summary
                    Divider()
                }
                controls
                Divider()
                if let error = model.errorMessage {
                    TezOperationFeedback(message: error, tone: .error)
                        .padding(.horizontal, TezStyle.pageInset).padding(.vertical, 10)
                }
                if let message = model.closeMessage {
                    TezOperationFeedback(message: message, tone: model.closeError ? .error : .success)
                        .padding(.horizontal, TezStyle.pageInset).padding(.vertical, 8)
                }
                TezInspectorLayout(isPresented: hasSelectedDetails, selectionID: selectedDetailKey,
                                   bottomHeight: tab == .connections ? 220 : 112, motion: motion) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(TezTableSelectionVisibility(selectionID: selectedDetailKey, selectionIndex: selectedDetailIndex))
                } inspector: { side in
                    details(side: side)
                }
                Divider()
                footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: pollKey) {
            let activeModel = model
            guard canRead else { activeModel.stop(); return }
            let requested = requestQuery
            activeModel.select(requested)
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            if !paused || activeModel.snapshotQuery != requested { await refresh(requested) }
            while !Task.isCancelled && canRead {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if !paused { await refresh(requested) }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; model.stop(preservingRates: paused) }
        .onChange(of: requestQuery) { _, requested in
            model.select(requested)
            pendingClose = nil
        }
        .onChange(of: tab) { previous, _ in
            session.model(for: previous).stop(preservingRates: paused)
        }
        .onChange(of: paused) { _, paused in model.stop(preservingRates: paused) }
        .alert(item: $pendingClose) { row in
            Alert(title: Text("关闭这条连接？"),
                  message: Text("\(row.title)\n\(display(row.process))\n仅关闭选中的连接。应用可能自动重新连接。"),
                  primaryButton: .destructive(Text("关闭连接")) { close(row) },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            TezMetric(title: "活跃连接", value: model.snapshot?.connections.state == "ready" ? model.snapshot?.connections.total.formatted() ?? "—" : "—", symbol: "point.3.connected.trianglepath.dotted", motion: motion)
            Divider().frame(height: 28)
            TezMetric(title: "上传速率", value: NativeConnectionRate.label(model.rates.total.upload), symbol: "arrow.up", tint: TezStyle.accent, motion: motion)
                .help("累计上传 \(NativeActivityFormat.bytes(model.snapshot?.connections.uploadTotal))")
            TezMetric(title: "下载速率", value: NativeConnectionRate.label(model.rates.total.download), symbol: "arrow.down", tint: TezStyle.success, motion: motion)
                .help("累计下载 \(NativeActivityFormat.bytes(model.snapshot?.connections.downloadTotal))")
            TezMetric(title: "内存", value: NativeActivityFormat.bytes(model.snapshot?.connections.memory), symbol: "memorychip", motion: motion)
        }
        .padding(.horizontal, TezStyle.pageInset).frame(height: 68)
        .background { TezContentMaterial(material: .headerView) }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TezSearchField(prompt: tab == .connections ? "搜索应用、目标、规则或出口" : tab.searchPrompt, text: queryBinding, identifier: "live.activity.search",
                           surface: Color(nsColor: .textBackgroundColor))
            TezStatusLabel(title: !canRead ? "未同步" : paused ? "自动刷新已暂停" : model.errorMessage != nil ? "读取失败" : "每秒更新", symbol: !canRead ? "clock" : paused ? "pause.circle" : "arrow.triangle.2.circlepath", motion: motion)
                .fixedSize()
                .help(paused ? "暂停定时读取；搜索、翻页与手动刷新仍读取最新数据。连接不受影响。" : "每秒读取一次活动")
            TezToolButton(title: paused ? "继续自动刷新活动" : "暂停自动刷新活动", symbol: paused ? "play.fill" : "pause.fill",
                          enabled: canRead, motion: motion) { session.paused.toggle() }
                .accessibilityIdentifier("live.activity.pause")
            TezToolButton(title: "刷新活动", symbol: "arrow.clockwise", enabled: canRead && !model.isLoading) {
                let requested = requestQuery; Task { await refresh(requested) }
            }.accessibilityIdentifier("live.activity.refresh")
            if tab == .connections {
                TezToolButton(title: store.supports("native_close_connection") ? "关闭选中的连接" : "只读连接：不能关闭连接", symbol: "xmark.circle",
                              enabled: canClose && selectedConnection?.closeable == true) {
                    pendingClose = selectedConnection
                }.accessibilityIdentifier("live.activity.close")
            }
        }
        .padding(.horizontal, TezStyle.pageInset).frame(height: 48)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if !canRead && !showingRequestedPage {
            TezEmptyState(title: "活动查询不可用", symbol: "waveform.path", detail: "当前后台未开放活动查询。")
        } else if model.snapshot == nil || !showingRequestedPage {
            if canRead && model.errorMessage == nil {
                VStack(spacing: 10) { ProgressView(); Text("正在读取活动").font(TezType.body).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TezEmptyState(title: "活动读取失败", symbol: "exclamationmark.triangle")
            }
        } else if sectionState != "ready" {
            TezEmptyState(title: tab.unavailableTitle, symbol: "network.slash", detail: NativeActivityFormat.issue(sectionCode))
        } else if visibleCount == 0 {
            TezEmptyState(title: query.isEmpty ? tab.emptyTitle : "没有匹配结果", symbol: query.isEmpty ? tab.symbol : "magnifyingglass")
        } else {
            switch tab {
            case .connections: connectionTable
            case .rules: ruleTable
            case .providers: providerTable
            }
        }
    }

    private var connectionTable: some View {
      GeometryReader { geometry in
        let compact = geometry.size.width < 880
        // Reserve native column padding, dividers, and a visible vertical scrollbar.
        let available = max(0, geometry.size.width - (compact ? 96 : 160))
        let rateWidth = min(82, max(48, geometry.size.width * 0.1))
        let remaining = max(0, available - rateWidth * 2)
        Group {
          if compact {
           Table(connections, selection: $session.context.connectionID) {
            TableColumn("目标 / 应用") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).lineLimit(2, reservesSpace: true)
                    Label(row.applicationLabel, systemImage: "app")
                        .font(TezType.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 3)
                    .help("\(row.title)\n\(row.applicationLabel)\n进程：\(display(row.process))")
            }.width(max(0, available - 92) * 0.52)
            TableColumn("出口 / 规则") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(TezProxyName.title(row.outboundLabel)).lineLimit(2, reservesSpace: true)
                        .truncationMode(.middle)
                    Text("\(row.ruleLabel) · \(row.rulePayloadLabel)")
                        .font(TezType.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 3)
                    .help("\(TezProxyName.title(row.outboundLabel))\n\(row.ruleLabel)：\(row.rulePayloadLabel)\n\(row.chains.joined(separator: " · "))")
            }.width(max(0, available - 92) * 0.48)
            TableColumn("上传 / 下载") { row in
                VStack(alignment: .trailing, spacing: 5) {
                    Label(NativeConnectionRate.label(model.rates.connections[row.id]?.upload), systemImage: "arrow.up")
                    Label(NativeConnectionRate.label(model.rates.connections[row.id]?.download), systemImage: "arrow.down")
                }.font(TezType.caption).monospacedDigit()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("上传 \(NativeConnectionRate.label(model.rates.connections[row.id]?.upload))，下载 \(NativeConnectionRate.label(model.rates.connections[row.id]?.download))")
                    .help("累计上传 \(NativeActivityFormat.bytes(row.upload))\n累计下载 \(NativeActivityFormat.bytes(row.download))")
            }.width(92).alignment(.trailing)
           }
          } else {
           Table(connections, selection: $session.context.connectionID) {
            TableColumn("目标") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).lineLimit(1)
                    Text([row.network?.uppercased(), !canRead || model.errorMessage != nil ? "未确认" : model.rates.connections[row.id]?.status ?? "活跃"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(TezType.metadata).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 3)
                    .help([row.title, row.destinationLabel, paused ? "最后一次观测；自动刷新已暂停" : nil].compactMap { $0 }.joined(separator: "\n"))
            }.width(remaining * 0.34)
            TableColumn("应用 / 进程") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Label(row.applicationLabel, systemImage: "app").lineLimit(1)
                    if let process = row.process, process != row.applicationLabel, !process.isEmpty {
                        Text(process).font(TezType.metadata).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.help("\(row.applicationLabel)\n进程：\(display(row.process))")
            }.width(remaining * 0.21)
            TableColumn("实际出口") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Label(TezProxyName.title(row.outboundLabel), systemImage: row.outboundSymbol).lineLimit(1).truncationMode(.middle)
                    if let group = row.orderedChain?.first, row.chains.count > 1 {
                        Text(TezProxyName.title(group)).font(TezType.metadata).foregroundStyle(.secondary).lineLimit(1)
                    } else if row.actualOutbound == "DIRECT" {
                        Text("DIRECT").font(TezType.metadata).foregroundStyle(.secondary)
                    }
                }.help("内核观测出口：\(row.outboundLabel)\n\(row.orderedChain?.joined(separator: " → ") ?? row.chains.joined(separator: " · "))")
            }.width(remaining * 0.24)
            TableColumn("命中规则") { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.ruleLabel).lineLimit(1)
                    Text(row.rulePayloadLabel).font(TezType.metadata).foregroundStyle(.secondary).lineLimit(1)
                }.help("\(display(row.rule))\n\(row.rulePayloadLabel)")
            }.width(remaining * 0.21)
            TableColumn("上传") { row in transferCell(rate: model.rates.connections[row.id]?.upload, total: row.upload) }.width(rateWidth).alignment(.trailing)
            TableColumn("下载") { row in transferCell(rate: model.rates.connections[row.id]?.download, total: row.download) }.width(rateWidth).alignment(.trailing)
           }
          }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let row = connections.first(where: { ids.contains($0.id) }) {
                Button("关闭连接", systemImage: "xmark.circle", role: .destructive) { pendingClose = row }
                    .disabled(!canClose || row.closeable != true)
            }
        }
        .accessibilityIdentifier("live.activity.connections")
      }
    }

    private func transferCell(rate: Double?, total: UInt64) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(NativeConnectionRate.label(rate)).font(TezType.metadata)
            Text(NativeActivityFormat.bytes(total)).font(TezType.metadata).foregroundStyle(.secondary)
        }.monospacedDigit().padding(.vertical, 3)
    }

    private var ruleTable: some View {
        Table(rules, selection: $session.context.ruleID) {
            TableColumn("序号") { row in Text(row.index.formatted()).monospacedDigit() }.width(46)
            TableColumn("类型") { row in Text(display(row.type)).lineLimit(1) }.width(min: 90, ideal: 110)
            TableColumn("匹配内容") { row in Text(display(row.payload)).lineLimit(1) }.width(min: 160, ideal: 250)
            TableColumn("策略") { row in Text(TezProxyName.title(display(row.proxy))).lineLimit(1).help(display(row.proxy)) }.width(min: 100, ideal: 130)
        }
        .accessibilityIdentifier("live.activity.rules")
    }

    private var providerTable: some View {
        Table(providers, selection: $session.context.providerID) {
            TableColumn("规则源") { row in Text(row.name).lineLimit(1) }.width(min: 160, ideal: 220)
            TableColumn("行为") { row in Text(display(row.behavior)).lineLimit(1) }.width(min: 80, ideal: 100)
            TableColumn("格式") { row in Text(display(row.format)).lineLimit(1) }.width(70)
            TableColumn("规则数") { row in Text(row.ruleCount?.formatted() ?? "—").monospacedDigit() }.width(70)
        }
        .accessibilityIdentifier("live.activity.providers")
    }

    private func details(side: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch tab {
                case .connections:
                    if let row = connections.first(where: { $0.id == session.context.connectionID }) {
                        detailLayout(side: side) {
                            TezInspectorHeader(title: row.title, close: clearSelection)
                            Button("关闭连接", systemImage: "xmark.circle", role: .destructive) { pendingClose = row }
                                .disabled(!canClose || row.closeable != true)
                                .accessibilityIdentifier("live.activity.detail.close")
                        }
                        connectionExplanation(row, side: side)
                    }
                case .rules:
                    if let row = rules.first(where: { $0.index == session.context.ruleID }) {
                        TezInspectorHeader(title: display(row.payload), close: clearSelection)
                        detailLayout(side: side) {
                            detail("类型", display(row.type))
                            detail("策略", TezProxyName.title(display(row.proxy)))
                            detail("条目数", row.size?.formatted() ?? "—")
                        }
                    }
                case .providers:
                    if let row = providers.first(where: { $0.name == session.context.providerID }) {
                        TezInspectorHeader(title: row.name, close: clearSelection)
                        detailLayout(side: side) {
                            detail("类型", display(row.type))
                            detail("来源", display(row.vehicleType))
                            detail("更新时间", display(row.updatedAt))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TezStyle.pageInset).padding(.vertical, 12)
        }
        .background { TezContentMaterial(material: .contentBackground) }
        .accessibilityIdentifier("live.activity.detail")
    }

    private func detail(_ title: String, _ value: String) -> some View {
        TezDetailField(title: title, value: value)
    }

    private func detailLayout<Content: View>(side: Bool, @ViewBuilder content: () -> Content) -> some View {
        let layout = side ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                          : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        return layout { content() }
    }

    private func connectionExplanation(_ row: NativeActivityConnection, side: Bool) -> some View {
        let protocolLabel = [row.network, row.type].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        return VStack(alignment: .leading, spacing: 16) {
            detailLayout(side: side) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("来源应用 / 进程").font(TezType.metadata).foregroundStyle(.secondary)
                    Label(row.applicationLabel, systemImage: "app").font(TezType.section)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let process = row.process, !process.isEmpty, process != row.applicationLabel {
                        Text(process).font(TezType.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("命中规则").font(TezType.metadata).foregroundStyle(.secondary)
                    Text(row.ruleLabel).font(TezType.section)
                    Text(row.rulePayloadLabel).font(TezType.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(!canRead || model.errorMessage != nil || paused ? "最后观测出口" : "实际出口")
                        .font(TezType.metadata).foregroundStyle(.secondary)
                    Label(TezProxyName.title(row.outboundLabel), systemImage: row.outboundSymbol).font(TezType.section)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !row.chains.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.orderedChain == nil ? "返回的策略链（顺序未提供）" : "返回的策略链（策略组到出口）")
                        .font(TezType.metadata).foregroundStyle(.secondary)
                    Text((row.orderedChain ?? row.chains).map(TezProxyName.title).joined(separator: row.orderedChain == nil ? " · " : " → "))
                        .font(TezType.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            DisclosureGroup("连接详情") {
                VStack(alignment: .leading, spacing: 8) {
                    detail("目标地址", row.destinationLabel ?? "未提供")
                    detail("协议 / 类型", protocolLabel.isEmpty ? "未提供" : protocolLabel)
                    detail("规则类型", display(row.rule))
                    if row.chains.contains("GLOBAL") {
                        detail("原始策略链", (row.orderedChain ?? row.chains).joined(separator: row.orderedChain == nil ? " · " : " → "))
                    }
                    detail("开始时间", display(row.start))
                    detail("应用来源", row.application == nil ? "内核返回的进程名" : "内核返回的应用包名称")
                    detail("窗口归属", "内核未提供，无法区分同一进程的窗口")
                }.padding(.top, 8)
            }.font(TezType.body)
            detailLayout(side: side) {
                Button("搜索相关规则", systemImage: "line.3.horizontal.decrease") { session.showRules(for: row) }
                    .disabled(row.ruleQuery == nil)
                    .help("按内核返回的匹配内容或规则类型搜索，不推断规则序号")
                    .accessibilityIdentifier("live.activity.detail.rules")
                Button("查看相关日志", systemImage: "text.alignleft") { session.showLogs(for: row) }
                    .disabled(row.logQuery == nil)
                    .help("按目标关键词搜索，不代表同一连接的追踪记录")
                    .accessibilityIdentifier("live.activity.detail.logs")
            }.controlSize(.small)
        }
    }

    private var selectedDetailKey: String? {
        switch tab {
        case .connections: session.context.connectionID
        case .rules: session.context.ruleID.map(String.init)
        case .providers: session.context.providerID
        }
    }

    private var selectedDetailIndex: Int? {
        guard showingRequestedPage else { return nil }
        return switch tab {
        case .connections: connections.firstIndex { $0.id == session.context.connectionID }
        case .rules: rules.firstIndex { $0.index == session.context.ruleID }
        case .providers: providers.firstIndex { $0.name == session.context.providerID }
        }
    }

    private func clearSelection() {
        session.context.clearSelection(in: tab)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerCount)
            Spacer(minLength: 0)
            if let updatedAt = model.updatedAt {
                Text(updatedAt.formatted(date: .omitted, time: .standard)).monospacedDigit()
                    .help("最近读取活动数据的时间")
            }
            if model.isLoading { ProgressView().controlSize(.mini) }
            HStack(spacing: 4) {
                Button { session.context.move(to: offset >= tab.pageSize ? offset - tab.pageSize : 0, in: tab) } label: {
                    Image(systemName: "chevron.left").frame(width: 16, height: 16)
                }
                .help("上一页").accessibilityLabel("上一页").accessibilityIdentifier("live.activity.previous")
                .disabled(!canRead || !showingRequestedPage || model.isLoading || !hasPaging || offset == 0)
                Button { if let nextOffset { session.context.move(to: nextOffset, in: tab) } } label: {
                    Image(systemName: "chevron.right").frame(width: 16, height: 16)
                }
                .help("下一页").accessibilityLabel("下一页").accessibilityIdentifier("live.activity.next")
                .disabled(!canRead || !showingRequestedPage || model.isLoading || nextOffset == nil)
            }.controlSize(.mini)
        }
        .font(TezType.metadata).foregroundStyle(.secondary)
        .padding(.horizontal, TezStyle.pageInset).frame(height: 28)
    }

    private var visibleCount: Int { switch tab { case .connections: connections.count; case .rules: rules.count; case .providers: providers.count } }
    private var total: UInt64 { switch tab { case .connections: model.snapshot?.connections.total ?? 0; case .rules: model.snapshot?.rules.total ?? 0; case .providers: model.snapshot?.providers.total ?? 0 } }
    private var sectionState: String { switch tab { case .connections: model.snapshot?.connections.state ?? "unavailable"; case .rules: model.snapshot?.rules.state ?? "unavailable"; case .providers: model.snapshot?.providers.state ?? "unavailable" } }
    private var sectionCode: String? { switch tab { case .connections: model.snapshot?.connections.code; case .rules: model.snapshot?.rules.code; case .providers: model.snapshot?.providers.code } }
    private var truncated: Bool { switch tab { case .connections: model.snapshot?.connections.truncated ?? false; case .rules: model.snapshot?.rules.truncated ?? false; case .providers: model.snapshot?.providers.truncated ?? false } }
    private var matched: UInt64? { switch tab { case .connections: model.snapshot?.connections.matched; case .rules: model.snapshot?.rules.matched; case .providers: model.snapshot?.providers.matched } }
    private var responseOffset: UInt64? { switch tab { case .connections: model.snapshot?.connections.offset; case .rules: model.snapshot?.rules.offset; case .providers: model.snapshot?.providers.offset } }
    private var pageOffset: UInt64 { responseOffset ?? 0 }
    private var nextOffset: UInt64? { switch tab { case .connections: model.snapshot?.connections.nextOffset; case .rules: model.snapshot?.rules.nextOffset; case .providers: model.snapshot?.providers.nextOffset } }
    private var hasPaging: Bool { matched != nil && responseOffset != nil }
    private var footerCount: String {
        guard showingRequestedPage else {
            if !canRead { return "数据不可用" }
            return model.errorMessage == nil ? "正在查询" : "查询失败"
        }
        guard sectionState == "ready" else { return "数据不可用" }
        guard let matched, hasPaging else { return "\(visibleCount) / \(total.formatted()) 项\(truncated ? " · 后台未提供分页" : "")" }
        let range = visibleCount == 0 ? "0" : "\((pageOffset + 1).formatted())–\((pageOffset + UInt64(visibleCount)).formatted())"
        return matched == total ? "\(range) / \(total.formatted()) 项" : "\(range) / \(matched.formatted()) 匹配 · 共 \(total.formatted()) 项"
    }

    private func display(_ value: String?) -> String { value.flatMap { $0.isEmpty ? nil : $0 } ?? "—" }

    private func refresh(_ requested: NativeActivityQuery) async {
        guard isVisible, canRead, !store.workspaceBusy, model.closingID == nil, requested == requestQuery, !Task.isCancelled else { return }
        let activeModel = model
        await activeModel.refresh(query: requested) { try await store.request("native_get_activity", params: requested.params, timeout: .seconds(15)) }
        guard requested == requestQuery, activeModel.snapshotQuery == requested, let snapshot = activeModel.snapshot else { return }
        session.context.reconcileSelection(in: snapshot, for: tab)
    }

    private func close(_ row: NativeActivityConnection) {
        guard tab == .connections, canClose, row.closeable == true else { return }
        let activeModel = model
        Task { @MainActor in
            _ = await activeModel.close(id: row.id) {
                try await store.request("native_close_connection", params: ["id": .string(row.id)], serialWorkspace: true)
            }
            await refresh(requestQuery)
        }
    }
}

private struct ActivityPollKey: Hashable {
    let query: NativeActivityQuery
    let canRead: Bool
}
