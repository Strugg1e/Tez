import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class NativeProfileEditorModel {
    typealias Request = @MainActor (String, [String: BackendJSON]) async throws -> BackendJSON

    var content = ""
    private(set) var originalContent = ""
    private(set) var revision: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var message: String?
    private(set) var details: String?
    private(set) var saved = false
    private let uid: String
    private let request: Request

    var isDirty: Bool { content != originalContent }
    var isBusy: Bool { isLoading || isSaving }
    var canSave: Bool { revision != nil && isDirty && !isBusy }

    init(uid: String, request: @escaping Request) {
        self.uid = uid
        self.request = request
    }

    func load() async {
        guard !isBusy else { return }
        isLoading = true
        message = nil
        details = nil
        saved = false
        defer { isLoading = false }
        do {
            let result = try await request("native_read_profile", ["uid": .string(uid)])
            guard case .object(let value) = result,
                  value["uid"] == .string(uid),
                  case .string(let text) = value["content"],
                  case .string(let nextRevision) = value["revision"], !nextRevision.isEmpty else {
                throw BackendWireError.invalid("Invalid native_read_profile response")
            }
            content = text
            originalContent = text
            revision = nextRevision
        } catch {
            show(error, message: "读取失败。请检查后台连接后重试。")
        }
    }

    func save() async {
        guard canSave, let revision else { return }
        let submitted = content
        isSaving = true
        message = nil
        details = nil
        saved = false
        defer { isSaving = false }
        do {
            let result = try await request("native_save_profile", [
                "uid": .string(uid), "content": .string(submitted), "expectedRevision": .string(revision)
            ])
            guard case .object(let value) = result, case .bool(let didSave) = value["saved"] else {
                throw BackendWireError.invalid("Invalid native_save_profile response")
            }
            guard didSave else {
                message = "未保存。请检查返回详情并修改内容；文件冲突时请重新载入。"
                details = Self.render(result)
                return
            }
            guard case .string(let nextRevision) = value["revision"], !nextRevision.isEmpty else {
                // A write may have happened. Do not reuse an unconfirmed revision.
                self.revision = nil
                throw BackendWireError.invalid("Save returned no revision; reload before saving again")
            }
            originalContent = submitted
            self.revision = nextRevision
            saved = true
            if let validation = value["validation"], validation != .null {
                details = Self.render(validation)
            }
        } catch {
            show(error, message: "保存失败。修改仍保留；请检查详情，或重新载入文件。")
        }
    }

    private func show(_ error: Error, message: String) {
        self.message = message
        if case NativeBackendError.remote(let remote) = error {
            var fields: [String: BackendJSON] = ["detail": .string(remote.detail)]
            fields["code"] = remote.code
            fields["operation"] = remote.operation
            details = Self.render(.object(fields))
        } else {
            details = String(describing: error)
        }
    }

    private static func render(_ value: BackendJSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}

struct NativeProfileEditor: View {
    let profile: NativeProfileItem
    let store: NativeBackendStore
    @Environment(\.dismiss) private var dismiss
    @State private var model: NativeProfileEditorModel
    @State private var pendingDiscard: DiscardAction?

    private enum DiscardAction: String, Identifiable {
        case close, reload
        var id: String { rawValue }
    }

    init(profile: NativeProfileItem, store: NativeBackendStore) {
        self.profile = profile
        self.store = store
        _model = State(initialValue: NativeProfileEditorModel(uid: profile.uid) { command, params in
            guard store.supports(command) else {
                throw NativeBackendError.unavailable("当前后台未开放此操作。修改仍保留。")
            }
            return try await store.request(command, params: params)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(TezStyle.accent)
                Text(profile.name.isEmpty ? profile.uid : profile.name)
                    .font(.headline).lineLimit(1).textSelection(.enabled)
                if model.isDirty {
                    Text("未保存").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("profile.editor.dirty")
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button { attempt(.reload) } label: {
                    Label("重新载入", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || !store.supports("native_read_profile")).help("重新载入配置")
                .accessibilityIdentifier("profile.editor.reload")
            }
            .padding(20)
            Divider()
            if model.isLoading && model.revision == nil {
                ProgressView("读取配置…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.revision == nil && !model.isDirty {
                ContentUnavailableView("配置尚未载入", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $model.content)
                    .font(.system(size: 13, design: .monospaced))
                    .disabled(model.isBusy)
                    .padding(8)
                    .accessibilityLabel("配置内容")
                    .accessibilityIdentifier("profile.editor.content")
            }
            if let message = model.message {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                    if model.revision == nil && !model.isDirty {
                        Button("重试读取") { Task { await model.load() } }
                            .disabled(model.isBusy || !store.supports("native_read_profile"))
                    }
                    detailView
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .accessibilityIdentifier("profile.editor.error")
            } else if model.details != nil {
                Divider()
                VStack(alignment: .leading) { detailView }.padding(16)
            }
            Divider()
            HStack {
                if model.saved && !model.isDirty { Label("已保存", systemImage: "checkmark").foregroundStyle(TezStyle.success) }
                Spacer()
                Button("关闭") { attempt(.close) }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
                    .accessibilityIdentifier("profile.editor.close")
                Button("保存") { Task { await model.save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .modifier(TezPrimaryActionStyle())
                    .disabled(!model.canSave || !store.supports("native_save_profile"))
                    .accessibilityIdentifier("profile.editor.save")
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 780, minHeight: 440, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.isDirty || model.isBusy)
        .task { await model.load() }
        .alert(item: $pendingDiscard) { action in
            Alert(title: Text("丢弃未保存的修改？"),
                  message: Text(action == .close ? "关闭后，未保存的修改会丢失。" : "重新载入会替换当前修改。"),
                  primaryButton: .destructive(Text("丢弃修改")) { perform(action) },
                  secondaryButton: .cancel(Text("继续编辑")))
        }
    }

    @ViewBuilder private var detailView: some View {
        if let details = model.details {
            ScrollView {
                Text(details).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 100)
        }
    }

    private func attempt(_ action: DiscardAction) {
        guard !model.isBusy else { return }
        if model.isDirty { pendingDiscard = action } else { perform(action) }
    }

    private func perform(_ action: DiscardAction) {
        switch action {
        case .close: dismiss()
        case .reload: Task { await model.load() }
        }
    }
}
