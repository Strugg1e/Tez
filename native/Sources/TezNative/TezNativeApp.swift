import AppKit
import SwiftUI

@main
struct TezNativeApp: App {
    private static let interfaceOnly = Bundle.main.object(forInfoDictionaryKey: "TezInterfaceOnly") as? Bool == true
    @NSApplicationDelegateAdaptor(PreviewAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var selection: WorkspaceSection? = .connection
    @State private var preferences = TezPreviewPreferences()
    @State private var backend = NativeBackendStore(mode: TezNativeApp.interfaceOnly ? .attach : .automatic)
    @State private var startupAttempted = false
    @State private var coreOperationInProgress = false
    @State private var operationError: String?

    var body: some Scene {
        Window(Self.interfaceOnly ? "Tez 界面检查" : "Tez", id: "workspace") {
            LiveWorkspaceView(store: backend, selection: $selection)
                .environment(preferences)
                .tint(TezStyle.accent)
                .preferredColorScheme(preferences.appearance.colorScheme)
                .frame(minWidth: 800, minHeight: 560)
                .onAppear { appDelegate.backend = backend }
                .task {
                    guard !Self.interfaceOnly, !startupAttempted, !ProcessInfo.processInfo.arguments.contains("--capture-preview") else { return }
                    startupAttempted = true
                    await connectAndStart()
                }
                .alert("后台操作未完成", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
                    Button("好") { operationError = nil }
                } message: { Text(operationError ?? "") }
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            TezRouteCommands()
            CommandGroup(after: .windowArrangement) {
                Button("紧凑窗口") {
                    NSApplication.shared.windows.first { $0.identifier?.rawValue == "workspace" }?
                        .setContentSize(NSSize(width: 800, height: 560))
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                Button("标准窗口") {
                    NSApplication.shared.windows.first { $0.identifier?.rawValue == "workspace" }?
                        .setContentSize(NSSize(width: 1040, height: 700))
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
            }
            CommandMenu("导航") {
                ForEach(WorkspaceSection.allCases) { section in
                    Button(section.title) { selection = section }
                        .keyboardShortcut(section.shortcut, modifiers: .command)
                }
            }
        }

        MenuBarExtra(Self.interfaceOnly ? "Tez 界面检查" : "Tez", systemImage: "network") {
            Label(backend.state == .connected && backend.snapshot?.core.state == "ready" ? "内核运行中" : backend.statusText,
                  systemImage: backend.state == .connected ? "checkmark.circle" : "exclamationmark.circle")
            Button("显示 Tez", systemImage: "macwindow") { showWorkspace() }
            Divider()
            if backend.state == .connected {
                Button("启动内核", systemImage: "play.fill") { performCoreCommand("native_core_start") }
                    .disabled(coreOperationInProgress || backend.workspaceBusy || !backend.supports("native_core_start") || backend.snapshot?.core.state == "ready")
                Button("重启内核", systemImage: "arrow.clockwise") { performCoreCommand("native_core_restart") }
                    .disabled(coreOperationInProgress || backend.workspaceBusy || !backend.supports("native_core_restart"))
                Button("停止内核", systemImage: "stop.fill") { performCoreCommand("native_core_stop") }
                    .disabled(coreOperationInProgress || backend.workspaceBusy || !backend.supports("native_core_stop"))
            } else if backend.state == .shutdownFailed {
                Button("重试安全退出", systemImage: "arrow.clockwise") { backend.disconnect() }
            } else {
                Button("连接后台", systemImage: "link") { Task { await connectAndStart() } }
                    .disabled(Self.interfaceOnly || coreOperationInProgress || backend.requiresManagedShutdown)
            }
            Divider()
            SettingsLink { Label("设置…", systemImage: "gearshape") }
            Button("退出 Tez", systemImage: "power") {
                appDelegate.backend = backend
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            TezSettingsView(allowsBackendExamples: false, store: Self.interfaceOnly ? nil : backend)
                .environment(preferences)
                .tint(TezStyle.accent)
                .preferredColorScheme(preferences.appearance.colorScheme)
        }
    }

    @MainActor
    private func connectAndStart() async {
        guard !coreOperationInProgress, !backend.requiresManagedShutdown else { return }
        coreOperationInProgress = true
        defer { coreOperationInProgress = false }
        appDelegate.backend = backend
        backend.connect()
        let deadline = ContinuousClock.now + .seconds(35)
        while backend.state == .connecting && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard backend.state == .connected else {
            operationError = backend.errorMessage ?? "后台尚未连接。请检查连接页面。"
            return
        }
        guard backend.supports("native_core_start") else { return }
        await executeCoreCommand("native_core_start")
    }

    @MainActor
    private func performCoreCommand(_ command: String) {
        guard !coreOperationInProgress, !backend.workspaceBusy, backend.supports(command) else { return }
        coreOperationInProgress = true
        Task { @MainActor in
            defer { coreOperationInProgress = false }
            await executeCoreCommand(command)
        }
    }

    @MainActor
    private func executeCoreCommand(_ command: String) async {
        do {
            _ = try await backend.request(command, serialWorkspace: true)
            let runtime = try await backend.request("native_get_runtime")
            let expectedModes = command == "native_core_stop" ? ["NotRunning"] : ["Service", "Sidecar"]
            guard case .object(let fields) = runtime, let value = fields["mode"], case .string(let mode) = value, expectedModes.contains(mode) else {
                throw NativeBackendError.unavailable("后台请求已返回，但内核运行状态未达到预期。")
            }
        } catch {
            let details: String
            if case NativeBackendError.remote(let remote) = error {
                let code: String
                if let value = remote.code, case .string(let text) = value { code = text } else { code = "UNKNOWN" }
                details = "错误代码：\(code)\n\(remote.detail)"
            } else {
                details = String(describing: error)
            }
            operationError = String(details.prefix(4000))
            showWorkspace()
        }
        backend.refresh()
    }

    @MainActor
    private func showWorkspace() {
        openWindow(id: "workspace")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    var backend: NativeBackendStore?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let backend, backend.blocksTermination else {
            backend?.disconnect()
            return .terminateNow
        }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { @MainActor in
            let safe = await backend.shutdownForTermination()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: safe)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--capture-preview"),
              arguments.indices.contains(flag + 1) else { return }
        let path = arguments[flag + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.capturePreview(to: path)
        }
    }

    private func capturePreview(to path: String) {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.resizable)
        }),
              let content = window.contentView else {
            reportCaptureError("Workspace window is unavailable.")
            exit(EXIT_FAILURE)
        }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            reportCaptureError("Bitmap allocation failed.")
            exit(EXIT_FAILURE)
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            reportCaptureError("PNG encoding failed.")
            exit(EXIT_FAILURE)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("Tez preview captured: \(path)")
            NSApplication.shared.terminate(nil)
        } catch {
            reportCaptureError(error.localizedDescription)
            exit(EXIT_FAILURE)
        }
    }

    private func reportCaptureError(_ message: String) {
        FileHandle.standardError.write(Data("Tez preview capture failed: \(message)\n".utf8))
    }
}
