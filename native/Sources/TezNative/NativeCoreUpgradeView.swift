import AppKit
import SwiftUI

struct NativeCoreUpgradeView: View {
    @Bindable var store: NativeBackendStore
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var version = ""
    @State private var prepared: PreparedCore?
    @State private var identity: CoreControlIdentity?
    @State private var busy = false
    @State private var confirmation = false
    @State private var feedback: String?
    @State private var details: String?

    private struct PreparedCore: Decodable {
        let path: String
        let sha256: String
        let version: String
    }
    private struct CoreControlIdentity: Decodable {
        let generation: Int64
        let pid: Int64
        let started_at: Int64
        var params: BackendJSON { .object(["generation": .integer(generation), "pid": .integer(pid), "started_at": .integer(started_at)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("更新内核").font(.title2.weight(.semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            Form {
                LabeledContent("当前进程", value: identity.map { "PID \($0.pid)" } ?? "读取中")
                HStack {
                    Text("内核文件")
                    Spacer()
                    Text(source?.lastPathComponent ?? "未选择").foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("选择…", systemImage: "folder") { chooseFile() }.disabled(busy)
                        .accessibilityIdentifier("core.upgrade.choose")
                }
                .accessibilityElement(children: .contain)
                TextField("目标版本", text: $version, prompt: Text("v1.19.34"))
                    .disabled(busy).onChange(of: version) { _, _ in prepared = nil }
                if let prepared {
                    LabeledContent("SHA-256") {
                        Text(prepared.sha256).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let feedback {
                Text(feedback).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let details {
                DisclosureGroup("详情") {
                    ScrollView { Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 100)
                }
            }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if prepared == nil {
                    Button("检查文件", systemImage: "checkmark.shield") { prepare() }
                        .disabled(busy || source == nil || version.trimmingCharacters(in: .whitespaces).isEmpty || identity == nil)
                } else {
                    Button("升级并保留回退版本", systemImage: "arrow.up.circle") { confirmation = true }
                        .disabled(busy || identity == nil).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 540).frame(minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(busy)
        .task { await loadIdentity() }
        .confirmationDialog("确认更新内核？", isPresented: $confirmation) {
            Button("授权并升级", role: .destructive) { upgrade() }
            Button("取消", role: .cancel) {}
        } message: { Text("只使用可信的 Mihomo 文件。管理员授权后会短暂中断代理。新版本启动失败时，Tez 会尝试恢复上一版本。") }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择内核"
        if panel.runModal() == .OK, let url = panel.url {
            source = url.resolvingSymlinksInPath()
            prepared = nil; feedback = nil; details = nil
        }
    }

    private func loadIdentity() async {
        do { identity = try await store.request("native_get_core_control").decoded(CoreControlIdentity.self) }
        catch { feedback = "当前控制会话未确认，升级保持关闭。"; details = NativeFeatureError.message(error) }
    }

    private func prepare() {
        guard let source, !busy else { return }
        busy = true; feedback = nil; details = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                prepared = try await store.request("native_prepare_core_upgrade", params: ["sourcePath": .string(source.path), "version": .string(version)], timeout: .seconds(20), serialWorkspace: true).decoded(PreparedCore.self)
                feedback = "文件架构和签名检查通过。当前内核保持运行。"
            } catch { feedback = "文件检查未通过。"; details = NativeFeatureError.message(error) }
        }
    }

    private func upgrade() {
        guard let prepared, let identity, !busy else { return }
        busy = true; feedback = "等待管理员授权与升级结果。"; details = nil
        Task { @MainActor in
            defer { busy = false; store.refresh() }
            do {
                let result = try await store.request("native_upgrade_core", params: ["confirmed": .bool(true), "expected": identity.params,
                    "approvedCorePath": .string(prepared.path), "sha256": .string(prepared.sha256), "version": .string(prepared.version)], timeout: .seconds(180), serialWorkspace: true)
                guard case .object(let fields) = result, case .string(let outcome) = fields["outcome"],
                      ["upgraded", "rolled_back"].contains(outcome) else { throw NativeBackendError.unavailable("后台未返回可确认的升级状态") }
                feedback = outcome == "upgraded" ? "新版本内核运行中。" : "新版本启动失败，上一版本内核运行中。"
                if fields["versionSelectionSaved"] != .bool(true) { feedback = (feedback ?? "") + " 版本选择未保存，重启应用前请检查。" }
                if let data = try? JSONEncoder().encode(result) { details = String(data: data, encoding: .utf8) }
                self.prepared = nil
                await loadIdentity()
            } catch {
                self.prepared = nil; self.identity = nil
                feedback = "升级或回退结果未确认。请关闭此窗口后重新检查内核状态。"
                details = NativeFeatureError.message(error)
            }
        }
    }
}
