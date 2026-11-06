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
                    .tabItem { Label("外观与显示", systemImage: "paintpalette") }
                    .tag(TezSettingsTab.general)

                if let store {
                    NativeNetworkSettingsView(store: store)
                        .tabItem { Label("网络代理", systemImage: "network") }.tag(TezSettingsTab.connection)
                    NativeDNSSettingsView(store: store)
                        .tabItem { Label("DNS", systemImage: "server.rack") }.tag(TezSettingsTab.dns)
                    NativeLocalBackupsView(store: store)
                        .tabItem { Label("备份与恢复", systemImage: "archivebox") }.tag(TezSettingsTab.backups)
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

        }
        .frame(width: 740, height: 660)
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
        return VStack(spacing: 0) {
            TezSettingsPage(title: "外观与显示", summary: "界面偏好即时生效，不改变代理或配置。") {
                TezSettingsSection(title: "外观") {
                    TezSettingRow(title: "主题") {
                        Picker("主题", selection: $preferences.appearance) {
                            ForEach(TezAppearance.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                    }
                }
                TezSettingsSection(title: "线路显示") {
                    TezSettingToggle(title: "显示线路协议", detail: "在线路名称旁显示协议类型。", isOn: $preferences.showProtocol)
                }
                TezSettingsSection(title: "辅助显示") {
                    TezSettingToggle(title: "减少动态效果", detail: "减少界面过渡与状态动画。", isOn: $preferences.reduceMotion)
                    TezSettingToggle(title: "减少透明度", detail: "使用不透明背景，提高内容辨识度。", isOn: $preferences.reduceTransparency)
                    TezSettingToggle(title: "增加对比度", detail: "加深内容与背景的区分，同时减少透明效果。", isOn: $preferences.increaseContrast)
                    if systemReduceMotion || systemReduceTransparency {
                        TezStatusLabel(title: systemReduceMotion && systemReduceTransparency ? "macOS 已开启减少动态效果与透明度"
                                       : systemReduceMotion ? "macOS 已开启减少动态效果" : "macOS 已开启减少透明度", symbol: "accessibility")
                    }
                }
                if allowsBackendExamples {
                    TezSettingsSection(title: "示例线路") {
                        HStack(spacing: 10) {
                            Image(systemName: "network").foregroundStyle(.secondary)
                            Text("东京 01")
                            Spacer()
                            if preferences.showProtocol {
                                Text("Hysteria 2").foregroundStyle(.secondary).transition(.opacity)
                            }
                            Text("52 ms").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(TezType.body)
                        .animation(TezMotion(reduced: reducesMotion).feedback, value: preferences.showProtocol)
                    }
                }
            }
            Divider()
            HStack {
                TezStatusLabel(title: allowsBackendExamples ? "仅修改示例界面" : "界面偏好即时生效", symbol: "checkmark.circle")
                Spacer()
                Button("恢复界面默认值…", systemImage: "arrow.counterclockwise") { confirmsReset = true }
                    .disabled(isDefault)
            }.padding(16)
                .tezWindowDragBackground("tez.window.drag.footer")
        }
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
