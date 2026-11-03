import SwiftUI
import UniformTypeIdentifiers

struct NativeSubscriptionDetails: Decodable {
    struct Usage: Decodable { var upload: UInt64; var download: UInt64; var total: UInt64; var expire: UInt64 }
    var uid: String
    var name: String?
    var url: String?
    var interval: UInt64
    var autoUpdate: Bool
    var withProxy: Bool
    var usage: Usage?
    var nextUpdate: Int64?
}

struct NativeSubscriptionDraft: Equatable {
    var name = ""
    var url = ""
    var localContent = "proxies: []\nproxy-groups: []\nrules: []\n"
    var kind = "remote"
    var intervalText = "1440"
    var autoUpdate = true
    var withProxy = false

    var normalizedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    var urlError: String? {
        guard !normalizedURL.isEmpty else { return "请输入完整的 HTTP 或 HTTPS 订阅地址。" }
        guard !normalizedURL.contains(where: { $0.isWhitespace }),
              let address = URLComponents(string: normalizedURL),
              ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
              !(address.host ?? "").isEmpty, address.url != nil else {
            return "订阅地址必须包含 HTTP 或 HTTPS 协议和服务器名称。"
        }
        return nil
    }

    var interval: Int64? {
        let text = intervalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(text)
    }
    var intervalError: String? {
        guard autoUpdate else { return nil }
        guard let interval else { return "请输入整数分钟，不支持小数或其他字符。" }
        return (1440...525600).contains(interval) ? nil : "更新间隔必须为 1440–525600 分钟。"
    }
    var intervalForRequest: Int64 {
        guard let interval, (1440...525600).contains(interval) else { return 1440 }
        return interval
    }
}

struct NativeSubscriptionSheet: View {
    let store: NativeBackendStore
    let profile: NativeProfileItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var draft: NativeSubscriptionDraft
    @State private var baseline: NativeSubscriptionDraft?
    @State private var revealsURL = false
    @State private var showsImporter = false
    @State private var confirmsDelete = false
    @State private var confirmsActivation = false
    @State private var confirmsClose = false
    @State private var details: NativeSubscriptionDetails?
    private var isCurrent: Bool { profile?.uid == store.snapshot?.profiles.current }
    private var isRemote: Bool { draft.kind == "remote" }
    private var dirty: Bool { baseline.map { draft != $0 } ?? false }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var canSave: Bool {
        !operation.busy && baseline != nil && canWrite && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isRemote || (draft.urlError == nil && draft.intervalError == nil))
    }

    init(store: NativeBackendStore, profile: NativeProfileItem?) {
        self.store = store
        self.profile = profile
        var initial = NativeSubscriptionDraft()
        initial.name = profile?.name ?? ""
        initial.kind = profile?.type ?? "remote"
        _draft = State(initialValue: initial)
        _baseline = State(initialValue: profile == nil ? initial : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: profile == nil ? "doc.badge.plus" : "slider.horizontal.3").foregroundStyle(TezStyle.accent)
                Text(profile == nil ? "添加配置" : "配置管理").font(TezType.itemTitle)
                    .accessibilityAddTraits(.isHeader)
                if dirty {
                    Text("未保存").font(TezType.metadata).foregroundStyle(.secondary)
                        .accessibilityIdentifier("subscription.dirty")
                }
                Spacer()
                if operation.busy { ProgressView().controlSize(.small) }
                TezToolButton(title: "关闭配置管理", symbol: "xmark", enabled: !operation.busy) { close() }
                    .accessibilityIdentifier("subscription.close")
            }.padding(20)
            Divider()
            Form {
                if profile == nil {
                    Picker("来源", selection: $draft.kind) { Text("订阅").tag("remote"); Text("本地 YAML").tag("local") }.pickerStyle(.segmented)
                }
                TextField("名称", text: $draft.name, prompt: Text("例如：日常上网"))
                    .textFieldStyle(.roundedBorder).disabled(!canWrite)
                    .accessibilityIdentifier("subscription.name")
                if isRemote {
                    Section("订阅") {
                        HStack {
                            Group {
                                if revealsURL { TextField("订阅地址", text: $draft.url, prompt: Text("https://example.com/sub")) }
                                else { SecureField("订阅地址", text: $draft.url, prompt: Text("https://example.com/sub")) }
                            }.textFieldStyle(.roundedBorder).disabled(!canWrite).accessibilityIdentifier("subscription.url")
                            Button(revealsURL ? "隐藏地址" : "显示地址", systemImage: revealsURL ? "eye.slash" : "eye") { revealsURL.toggle() }
                                .labelStyle(.iconOnly).help(revealsURL ? "隐藏订阅地址" : "显示订阅地址")
                        }.privacySensitive()
                        Text("完整的 HTTP 或 HTTPS 地址，例如 https://example.com/sub。")
                            .font(TezType.metadata).foregroundStyle(.secondary)
                        if !draft.url.isEmpty, let error = draft.urlError {
                            TezStatusLabel(title: error, tone: .warning)
                                .accessibilityIdentifier("subscription.url.error")
                        }
                        Toggle("自动更新", isOn: $draft.autoUpdate).disabled(!canWrite)
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("更新间隔（分钟）") {
                                TextField("更新间隔（分钟）", text: $draft.intervalText, prompt: Text("1440"))
                                    .labelsHidden().accessibilityLabel("更新间隔（分钟）")
                                    .textFieldStyle(.roundedBorder).frame(width: 110)
                                    .disabled(!canWrite || !draft.autoUpdate)
                                    .accessibilityIdentifier("subscription.interval")
                            }
                            Text("允许范围：1440–525600 分钟（1–365 天）")
                                .font(TezType.metadata).foregroundStyle(.secondary)
                            if let error = draft.intervalError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(TezType.metadata).foregroundStyle(.red)
                                    .accessibilityIdentifier("subscription.interval.error")
                            }
                        }
                        Toggle("使用代理下载", isOn: $draft.withProxy).disabled(!canWrite)
                        if let next = details?.nextUpdate { LabeledContent("下次更新", value: Date(timeIntervalSince1970: TimeInterval(next)).formatted()) }
                    }
                    if let usage = details?.usage {
                        Section("用量") {
                            TezUsageMeter(used: usage.upload.addingReportingOverflow(usage.download).overflow ? UInt64.max : usage.upload + usage.download,
                                          total: usage.total, motion: motion)
                            if usage.expire > 0 { LabeledContent("到期", value: Date(timeIntervalSince1970: TimeInterval(usage.expire)).formatted()) }
                        }
                    }
                } else if profile == nil {
                    Section("配置内容") {
                        Button("选择 YAML 文件…", systemImage: "doc.badge.plus") { showsImporter = true }
                        TextEditor(text: $draft.localContent).font(TezType.code).frame(minHeight: 200)
                            .accessibilityLabel("配置内容").accessibilityIdentifier("subscription.content")
                    }.disabled(!canWrite)
                }
                if profile != nil {
                    Section("操作") {
                        HStack {
                            Button("启用配置", systemImage: "checkmark.circle") { confirmsActivation = true }
                                .disabled(dirty || isCurrent || !store.supports("native_activate_profile"))
                                .help(dirty ? "请先保存修改，再启用配置。" : "启用此配置的已保存版本")
                                .accessibilityIdentifier("subscription.activate")
                            if isRemote {
                                Button("更新订阅", systemImage: "arrow.clockwise") { Task { await update() } }
                                    .disabled(dirty || !store.supports("native_update_subscription"))
                                    .help(dirty ? "请先保存修改，或关闭并放弃更改后再更新订阅。" : "下载最新订阅")
                            }
                            Spacer()
                            Button("删除配置…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                                .disabled(!store.supports("native_delete_profile"))
                        }
                        if dirty {
                            Text(isRemote ? "启用配置或更新订阅前，请先保存修改；或关闭并放弃更改。" : "启用配置前，请先保存修改；或关闭并放弃更改。")
                                .font(TezType.metadata).foregroundStyle(.secondary)
                                .accessibilityIdentifier("subscription.activation.draftHint")
                        }
                        reorderControls
                    }
                }
            }.formStyle(.grouped).disabled(operation.busy || baseline == nil)
            Divider()
            HStack {
                if let error = operation.error {
                    ScrollView { TezOperationFeedback(message: error, tone: .error) }.frame(maxHeight: 74)
                } else if let message = operation.message {
                    TezOperationFeedback(message: message, tone: .success)
                }
                Spacer()
                if baseline == nil {
                    Button("重试读取") { Task { await load() } }
                        .disabled(operation.busy || !store.supports("native_subscription_details"))
                }
                Button(profile == nil ? "添加" : "保存", systemImage: "square.and.arrow.down") { Task { await save() } }
                    .modifier(TezPrimaryActionStyle()).disabled(!canSave)
                    .accessibilityIdentifier("subscription.save")
            }.padding(16)
        }
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(dirty || operation.busy)
        .onExitCommand { close() }
        .task { if profile != nil && baseline == nil { await load() } }
        .onChange(of: draft) { _, _ in if dirty { operation.message = nil } }
        .confirmationDialog("保存此配置的修改？", isPresented: $confirmsClose, titleVisibility: .visible) {
            Button("保存并关闭") { Task { await save(closeAfterSaving: true) } }.disabled(!canSave)
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text(operation.error.map { "修改仍保留。\n\(String($0.prefix(240)))" } ?? "关闭后，未保存的修改会丢失。")
        }
        .alert("删除此配置？", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await delete() } }
        } message: { Text(isCurrent ? "此配置正在使用。删除会改变运行配置，并可能中断连接。" : "将删除此配置及其关联文件。") }
        .confirmationDialog("启用此配置？", isPresented: $confirmsActivation, titleVisibility: .visible) {
            Button("启用") { Task { await activate() } }
            Button("取消", role: .cancel) {}
        } message: { Text("将启用「\(baseline?.name ?? profile?.name ?? "此配置")」的已保存版本。当前连接可能中断。") }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let file = try result.get()
                let access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2 * 1024 * 1024 else {
                    throw NativeBackendError.unavailable("文件超过 2 MiB")
                }
                draft.localContent = try String(contentsOf: file, encoding: .utf8)
                if draft.name.isEmpty { draft.name = file.deletingPathExtension().lastPathComponent }
            } catch { operation.error = NativeFeatureError.message(error) }
        }
    }

    private var canWrite: Bool {
        store.supports(profile == nil ? (isRemote ? "native_import_subscription" : "native_create_local_profile") : "native_patch_subscription")
    }
    private func close() {
        guard !operation.busy else { return }
        if dirty { confirmsClose = true } else { dismiss() }
    }
    private var orderedProfiles: [NativeProfileItem] { store.snapshot?.profiles.items.filter { $0.type == "remote" || $0.type == "local" } ?? [] }
    private var selectedIndex: Int? { orderedProfiles.firstIndex { $0.uid == profile?.uid } }
    private var reorderControls: some View {
        HStack {
            Button("上移", systemImage: "arrow.up") { Task { await reorder(-1) } }
                .disabled(selectedIndex == nil || selectedIndex == 0 || !store.supports("native_reorder_profile"))
            Button("下移", systemImage: "arrow.down") { Task { await reorder(1) } }
                .disabled(selectedIndex == nil || selectedIndex == orderedProfiles.count - 1 || !store.supports("native_reorder_profile"))
        }
    }
    private func load() async {
        guard !dirty, let profile, let result = await operation.request(store, "native_subscription_details", ["uid": .string(profile.uid)]) else { return }
        do {
            let result = try result.decoded(NativeSubscriptionDetails.self)
            details = result; draft.name = result.name ?? ""; draft.url = result.url ?? ""
            draft.intervalText = String(result.interval); draft.autoUpdate = result.autoUpdate; draft.withProxy = result.withProxy
            baseline = draft
        } catch { operation.error = NativeFeatureError.message(error) }
    }
    private func save(closeAfterSaving: Bool = false) async {
        guard canSave else { return }
        let submitted = draft
        let params: [String: BackendJSON]
        let command: String
        if let profile {
            command = "native_patch_subscription"
            var patch: [String: BackendJSON] = ["uid": .string(profile.uid), "name": .string(submitted.name), "interval": .integer(submitted.intervalForRequest),
                "auto_update": .bool(submitted.autoUpdate), "with_proxy": .bool(submitted.withProxy)]
            if isRemote { patch["url"] = .string(submitted.normalizedURL) }
            params = patch
        } else if isRemote {
            command = "native_import_subscription"; params = ["url": .string(submitted.normalizedURL), "name": .string(submitted.name),
                "interval": .integer(submitted.intervalForRequest), "auto_update": .bool(submitted.autoUpdate), "with_proxy": .bool(submitted.withProxy)]
        } else {
            command = "native_create_local_profile"; params = ["name": .string(submitted.name), "content": .string(submitted.localContent)]
        }
        guard await operation.request(store, command, params, refresh: true) != nil else {
            if closeAfterSaving { confirmsClose = true }
            return
        }
        baseline = submitted
        if profile == nil || closeAfterSaving { dismiss() }
        else { await load(); if operation.error == nil { operation.message = "配置已保存" } }
    }
    private func update() async {
        guard !dirty, let profile, await operation.request(store, "native_update_subscription", ["uid": .string(profile.uid)], refresh: true) != nil else { return }
        await load(); if operation.error == nil { operation.message = "订阅已更新" }
    }
    private func activate() async {
        guard baseline != nil, !dirty, !isCurrent, let profile,
              await operation.request(store, "native_activate_profile", ["uid": .string(profile.uid)], refresh: true) != nil else { return }
        operation.message = "配置已启用"
    }
    private func delete() async {
        guard let profile, await operation.request(store, "native_delete_profile", ["uid": .string(profile.uid)], refresh: true) != nil else { return }
        dismiss()
    }
    private func reorder(_ direction: Int) async {
        guard let index = selectedIndex, let profile, orderedProfiles.indices.contains(index + direction) else { return }
        let over = orderedProfiles[index + direction].uid
        guard await operation.request(store, "native_reorder_profile", ["uid": .string(profile.uid), "over": .string(over)], refresh: true) != nil else { return }
        operation.message = "排序已保存"
    }
}
