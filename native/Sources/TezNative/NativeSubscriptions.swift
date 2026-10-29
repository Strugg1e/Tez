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

struct NativeSubscriptionSheet: View {
    let store: NativeBackendStore
    let profile: NativeProfileItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var operation = NativeFeatureOperation()
    @State private var name = ""
    @State private var url = ""
    @State private var localContent = "proxies: []\nproxy-groups: []\nrules: []\n"
    @State private var kind = "remote"
    @State private var interval = 1440
    @State private var autoUpdate = true
    @State private var withProxy = false
    @State private var revealsURL = false
    @State private var showsImporter = false
    @State private var confirmsDelete = false
    @State private var confirmsActivation = false
    @State private var details: NativeSubscriptionDetails?
    private var isCurrent: Bool { profile?.uid == store.snapshot?.profiles.current }
    private var isRemote: Bool { (profile?.type ?? kind) == "remote" }
    private var motion: TezMotion { TezMotion(reduced: preferences.reduceMotion || systemReduceMotion) }
    private var canSave: Bool {
        !operation.busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isRemote || (!url.isEmpty && (1440...525600).contains(interval)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: profile == nil ? "doc.badge.plus" : "slider.horizontal.3").foregroundStyle(TezStyle.accent)
                Text(profile == nil ? "添加配置" : "配置管理").font(.system(size: 15, weight: .semibold))
                Spacer()
                if operation.busy { ProgressView().controlSize(.small) }
                TezToolButton(title: "关闭配置管理", symbol: "xmark", enabled: !operation.busy) { dismiss() }
            }.padding(20)
            Divider()
            Form {
                if profile == nil {
                    Picker("来源", selection: $kind) { Text("订阅").tag("remote"); Text("本地 YAML").tag("local") }.pickerStyle(.segmented)
                }
                TextField("名称", text: $name)
                if isRemote {
                    Section("订阅") {
                        HStack {
                            if revealsURL { TextField("订阅地址", text: $url) }
                            else { SecureField("订阅地址", text: $url) }
                            Button(revealsURL ? "隐藏地址" : "显示地址", systemImage: revealsURL ? "eye.slash" : "eye") { revealsURL.toggle() }
                                .labelStyle(.iconOnly).help(revealsURL ? "隐藏订阅地址" : "显示订阅地址")
                        }.privacySensitive()
                        Toggle("自动更新", isOn: $autoUpdate)
                        TextField("更新间隔（分钟）", value: $interval, format: .number.grouping(.never))
                        Toggle("使用代理下载", isOn: $withProxy)
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
                        TextEditor(text: $localContent).font(.system(size: 12, design: .monospaced)).frame(minHeight: 200)
                    }
                }
                if profile != nil {
                    Section("操作") {
                        HStack {
                            Button("启用配置", systemImage: "checkmark.circle") { confirmsActivation = true }
                                .disabled(isCurrent || !store.supports("native_activate_profile"))
                            if isRemote {
                                Button("更新订阅", systemImage: "arrow.clockwise") { Task { await update() } }
                                    .disabled(!store.supports("native_update_subscription"))
                            }
                            Spacer()
                            Button("删除配置…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                                .disabled(!store.supports("native_delete_profile"))
                        }
                        reorderControls
                    }
                }
            }.formStyle(.grouped).disabled(operation.busy)
            Divider()
            HStack {
                if let error = operation.error {
                    ScrollView { TezOperationFeedback(message: error, tone: .error) }.frame(maxHeight: 74)
                } else if let message = operation.message {
                    TezOperationFeedback(message: message, tone: .success)
                }
                Spacer()
                Button(profile == nil ? "添加" : "保存", systemImage: "square.and.arrow.down") { Task { await save() } }
                    .modifier(TezPrimaryActionStyle()).disabled(!canSave || !canWrite)
            }.padding(16)
        }
        .frame(width: 600, height: 560)
        .interactiveDismissDisabled(operation.busy)
        .task { name = profile?.name ?? ""; if profile != nil { await load() } }
        .alert("删除此配置？", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await delete() } }
        } message: { Text(isCurrent ? "此配置正在使用。删除会改变运行配置，并可能中断连接。" : "将删除此配置及其关联文件。") }
        .confirmationDialog("启用此配置？", isPresented: $confirmsActivation, titleVisibility: .visible) {
            Button("启用") { Task { await activate() } }
            Button("取消", role: .cancel) {}
        } message: { Text("将重新验证并应用配置，当前连接可能中断。") }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let file = try result.get()
                let access = file.startAccessingSecurityScopedResource()
                defer { if access { file.stopAccessingSecurityScopedResource() } }
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2 * 1024 * 1024 else {
                    throw NativeBackendError.unavailable("文件超过 2 MiB")
                }
                localContent = try String(contentsOf: file, encoding: .utf8)
                if name.isEmpty { name = file.deletingPathExtension().lastPathComponent }
            } catch { operation.error = NativeFeatureError.message(error) }
        }
    }

    private var canWrite: Bool {
        store.supports(profile == nil ? (isRemote ? "native_import_subscription" : "native_create_local_profile") : "native_patch_subscription")
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
        guard let profile, let result = await operation.request(store, "native_subscription_details", ["uid": .string(profile.uid)]) else { return }
        do {
            let result = try result.decoded(NativeSubscriptionDetails.self)
            details = result; name = result.name ?? ""; url = result.url ?? ""
            interval = Int(result.interval); autoUpdate = result.autoUpdate; withProxy = result.withProxy
        } catch { operation.error = NativeFeatureError.message(error) }
    }
    private func save() async {
        let params: [String: BackendJSON]
        let command: String
        if let profile {
            command = "native_patch_subscription"
            var patch: [String: BackendJSON] = ["uid": .string(profile.uid), "name": .string(name), "interval": .integer(Int64(interval)),
                "auto_update": .bool(autoUpdate), "with_proxy": .bool(withProxy)]
            if isRemote { patch["url"] = .string(url) }
            params = patch
        } else if isRemote {
            command = "native_import_subscription"; params = ["url": .string(url), "name": .string(name),
                "interval": .integer(Int64(interval)), "auto_update": .bool(autoUpdate), "with_proxy": .bool(withProxy)]
        } else {
            command = "native_create_local_profile"; params = ["name": .string(name), "content": .string(localContent)]
        }
        guard await operation.request(store, command, params, refresh: true) != nil else { return }
        if profile == nil { dismiss() } else { await load(); operation.message = "配置已保存" }
    }
    private func update() async {
        guard let profile, await operation.request(store, "native_update_subscription", ["uid": .string(profile.uid)], refresh: true) != nil else { return }
        await load(); operation.message = "订阅已更新"
    }
    private func activate() async {
        guard let profile, await operation.request(store, "native_activate_profile", ["uid": .string(profile.uid)], refresh: true) != nil else { return }
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
