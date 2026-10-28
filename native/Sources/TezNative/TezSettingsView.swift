import SwiftUI

struct TezSettingsView: View {
    var allowsBackendExamples = true
    var store: NativeBackendStore? = nil
    @Environment(TezPreviewPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @State private var selectedTab = TezSettingsTab.general
    @State private var routingMode = TezSettingsRoutingMode.rule
    @State private var captureMode = TezSettingsCaptureMode.systemProxy
    @State private var redactAddresses = true
    @State private var diagnosticDetail = TezSettingsDiagnosticDetail.standard
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                generalSettings
                    .tabItem { Label("通用", systemImage: "gearshape") }
                    .tag(TezSettingsTab.general)

                if let store {
                    NativeNetworkSettingsView(store: store)
                        .tabItem { Label("网络", systemImage: "network") }.tag(TezSettingsTab.connection)
                    NativeDNSSettingsView(store: store)
                        .tabItem { Label("DNS", systemImage: "server.rack") }.tag(TezSettingsTab.dns)
                    NativeLocalBackupsView(store: store)
                        .tabItem { Label("备份", systemImage: "archivebox") }.tag(TezSettingsTab.backups)
                }

                if allowsBackendExamples {
                    connectionSettings
                        .tabItem { Label("连接", systemImage: "network") }
                        .tag(TezSettingsTab.connection)

                    advancedSettings
                        .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
                        .tag(TezSettingsTab.advanced)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Label(allowsBackendExamples ? "示例设置" : "Tez 设置", systemImage: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("恢复默认值…") {
                    confirmsReset = true
                }
                .disabled(isDefault)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 620)
        .onChange(of: allowsBackendExamples) { _, _ in selectedTab = .general }
        .alert(allowsBackendExamples ? "恢复示例设置？" : "恢复界面设置？", isPresented: $confirmsReset) {
            Button("取消", role: .cancel) {}
            Button("恢复默认值", role: .destructive, action: reset)
        } message: {
            Text(allowsBackendExamples
                 ? "恢复示例的外观和设置，不会修改 Tez 配置或系统网络。"
                 : "恢复外观与界面设置，不会修改配置或系统网络。")
        }
    }

    private var generalSettings: some View {
        @Bindable var preferences = preferences
        return Form {
            Section("外观") {
                Picker("外观", selection: $preferences.appearance) {
                    ForEach(TezAppearance.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("界面") {
                Toggle("显示线路协议", isOn: $preferences.showProtocol)
                Toggle("减少动态效果", isOn: $preferences.reduceMotion)
                Toggle("减少透明度", isOn: $preferences.reduceTransparency)
                Toggle("增加对比度", isOn: $preferences.increaseContrast)
                LabeledContent("系统透明度", value: systemReduceTransparency ? "已降低" : "标准")
                    .foregroundStyle(.secondary)

                if systemReduceMotion {
                    LabeledContent("系统偏好", value: "减少动态效果已开启")
                        .foregroundStyle(.secondary)
                }
            }

            if allowsBackendExamples {
                Section("示例线路") {
                    HStack(spacing: 10) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("东京 01")
                        Spacer()
                        if preferences.showProtocol {
                            Text("Hysteria 2")
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                        Text("52 ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .animation(reducesMotion ? nil : .easeInOut(duration: 0.16), value: preferences.showProtocol)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var connectionSettings: some View {
        Form {
            Section("分流") {
                Picker("分流模式", selection: $routingMode) {
                    ForEach(TezSettingsRoutingMode.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("示例请求", value: "example.com")
                LabeledContent("请求去向", value: routingMode.destination)
            }

            Section {
                Picker("接管方式", selection: $captureMode) {
                    ForEach(TezSettingsCaptureMode.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("系统网络", value: "未更改")
                    .foregroundStyle(.secondary)
            } header: {
                Text("网络")
            } footer: {
                Text(captureMode == .tun
                     ? "TUN 仅为示例选择。此预览不会安装服务或请求网络权限。"
                     : "系统代理仅为示例选择。此预览不会更改系统代理。")
            }
        }
        .formStyle(.grouped)
    }

    private var advancedSettings: some View {
        Form {
            Section("诊断") {
                Picker("记录级别", selection: $diagnosticDetail) {
                    ForEach(TezSettingsDiagnosticDetail.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)

                Toggle("隐藏日志中的 IP 地址", isOn: $redactAddresses)
            }

            Section("示例日志") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("[INFO] example.com → \(redactAddresses ? "•••.•••.•••.•••" : "192.0.2.10")")
                    if diagnosticDetail == .detailed {
                        Text("[DEBUG] rule=DOMAIN · route=东京 01 · protocol=TCP")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("数据来源", value: "内置示例")
                LabeledContent("代理核心", value: "未接入")
            }
        }
        .formStyle(.grouped)
    }

    private var reducesMotion: Bool {
        preferences.reduceMotion || systemReduceMotion
    }

    private var isDefault: Bool {
        preferences.appearance == .system && !preferences.reduceMotion && preferences.showProtocol
            && !preferences.reduceTransparency && !preferences.increaseContrast
            && routingMode == .rule && captureMode == .systemProxy
            && redactAddresses && diagnosticDetail == .standard
    }

    private func reset() {
        preferences.appearance = .system
        preferences.reduceMotion = false
        preferences.reduceTransparency = false
        preferences.increaseContrast = false
        preferences.showProtocol = true
        routingMode = .rule
        captureMode = .systemProxy
        redactAddresses = true
        diagnosticDetail = .standard
    }
}

private enum TezSettingsTab: Hashable {
    case general, connection, advanced, dns, backups
}

private enum TezSettingsRoutingMode: String, CaseIterable, Identifiable {
    case rule = "规则"
    case global = "全局"
    case direct = "直连"

    var id: Self { self }

    var destination: String {
        switch self {
        case .rule: "东京 01 · 匹配域名规则"
        case .global: "东京 01 · 全部请求使用代理"
        case .direct: "直接连接 · 不使用代理"
        }
    }
}

private enum TezSettingsCaptureMode: String, CaseIterable, Identifiable {
    case systemProxy = "系统代理"
    case tun = "TUN"

    var id: Self { self }
}

private enum TezSettingsDiagnosticDetail: String, CaseIterable, Identifiable {
    case standard = "标准"
    case detailed = "详细"

    var id: Self { self }
}
