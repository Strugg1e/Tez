import AppKit
import SwiftUI

enum TezTone {
    case neutral, success, warning, error

    var color: Color {
        switch self {
        case .neutral: .secondary
        case .success: TezStyle.success
        case .warning: TezStyle.warning
        case .error: Color(nsColor: .systemRed)
        }
    }

    var symbol: String {
        switch self {
        case .neutral: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

struct TezMotion {
    let reduced: Bool
    var feedback: Animation? { reduced ? nil : .easeOut(duration: 0.16) }
    var layout: Animation? { reduced ? nil : .easeOut(duration: 0.20) }
    var mechanism: Animation? {
        reduced ? nil : .interpolatingSpring(mass: 1, stiffness: 280, damping: 2 * sqrt(280), initialVelocity: 0)
    }
    var symbol: ContentTransition { reduced ? .identity : .symbolEffect(.replace) }
}

struct TezInspectorLayout<Content: View, Inspector: View>: View {
    let isPresented: Bool
    let selectionID: String?
    var reservesBottomSpace = false
    var bottomHeight: CGFloat = 180
    var motion = TezMotion(reduced: true)
    @ViewBuilder let content: Content
    @ViewBuilder let inspector: (Bool) -> Inspector

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width >= 960
            let layout = side ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if isPresented || (!side && reservesBottomSpace) {
                    Rectangle().fill(Color(nsColor: .separatorColor))
                        .frame(width: side ? 1 : nil, height: side ? nil : 1)
                        .accessibilityHidden(true)
                    revealedInspector(side: side)
                        .frame(width: side ? 320 : nil,
                               height: side ? nil : min(bottomHeight, max(112, geometry.size.height * 0.45)))
                }
            }
            .accessibilityIdentifier(side ? "workspace.inspector.side" : "workspace.inspector.bottom")
        }
    }

    private func revealedInspector(side: Bool) -> some View {
        TezInspectorReveal(motion: selectionID == nil ? TezMotion(reduced: true) : motion) { inspector(side) }.id(selectionID)
    }
}

private struct TezInspectorReveal<Content: View>: View {
    let motion: TezMotion
    @ViewBuilder let content: Content
    @State private var visible = false

    var body: some View {
        content
            .opacity(visible || motion.reduced ? 1 : 0)
            .onAppear { withAnimation(motion.feedback) { visible = true } }
    }
}

struct TezFieldAnchor: ViewModifier {
    let key: String
    let highlighted: Bool
    let motion: TezMotion

    func body(content: Content) -> some View {
        content
            .id(key)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(TezStyle.accent.opacity(highlighted ? 1 : 0), lineWidth: 2)
                    .padding(-6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(motion.feedback, value: highlighted)
            .accessibilityIdentifier("network.field.\(key)")
    }
}

struct TezSettingsPage<Content: View>: View {
    let title: String
    let summary: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(TezType.page)
                    Text(summary).font(TezType.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(TezStyle.pageInset)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct TezSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(TezType.section)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TezSettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(TezType.body)
                if let detail {
                    Text(detail).font(TezType.metadata).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .frame(minHeight: 34)
    }
}

struct TezSettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        TezSettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }
}

struct TezSettingsDisclosure<Content: View>: View {
    let title: String
    let summary: String
    @Binding var isExpanded: Bool
    var motion = TezMotion(reduced: true)
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 22) { content }.padding(.top, 18)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(TezType.section)
                Text(summary).font(TezType.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(motion.layout, value: isExpanded)
    }
}

struct TezMultilineField: View {
    let title: String
    @Binding var text: String
    var height: CGFloat = 88
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(TezType.code)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(8).frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? TezStyle.accent : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
            }
            .accessibilityLabel(title)
    }
}

struct TezSearchField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String
    var surface = Color(nsColor: .controlBackgroundColor)
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Button { focused = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut("f", modifiers: .command)
                .help(prompt).accessibilityLabel(prompt)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).focused($focused)
                .accessibilityLabel(prompt).accessibilityIdentifier(identifier)
            Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("清除搜索").accessibilityLabel("清除搜索")
                .opacity(text.isEmpty ? 0 : 1).disabled(text.isEmpty)
                .accessibilityHidden(text.isEmpty)
        }
        .font(TezType.body)
        .padding(.horizontal, 10).frame(height: 30)
        .background(surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? TezStyle.accent : .clear, lineWidth: 2)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct TezToolButton: View {
    let title: String
    let symbol: String
    var enabled = true
    var motion = TezMotion(reduced: true)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 14, height: 14)
                .contentTransition(motion.symbol)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help(title).accessibilityLabel(title).disabled(!enabled)
        .animation(motion.feedback, value: symbol)
    }
}

struct TezMetric: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .secondary
    var motion = TezMotion(reduced: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
            }.font(TezType.metadata)
            Text(value).font(TezType.page).monospacedDigit()
                .lineLimit(1).contentTransition(motion.reduced ? .identity : .numericText())
                .animation(motion.feedback, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TezUsageMeter: View {
    let used: UInt64
    let total: UInt64
    var motion = TezMotion(reduced: true)

    private var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(NativeActivityFormat.bytes(used)).font(TezType.page).monospacedDigit()
                Spacer()
                Text("共 \(NativeActivityFormat.bytes(total))").font(TezType.metadata).foregroundStyle(.secondary)
            }
            if total > 0 {
                ProgressView(value: fraction)
                    .tint(fraction >= 0.9 ? TezStyle.warning : TezStyle.accent)
                    .animation(motion.feedback, value: fraction)
                    .accessibilityLabel("订阅流量用量")
                    .accessibilityValue("\(NativeActivityFormat.bytes(used)) / \(NativeActivityFormat.bytes(total))")
            }
        }.padding(.vertical, 4)
    }
}

struct TezDetailField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(TezType.metadata).foregroundStyle(.secondary)
            Text(value).font(TezType.body).lineLimit(2)
                .textSelection(.enabled).help(value).contentTransition(.opacity)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TezInspectorHeader: View {
    let title: String
    var titleFont = TezType.section
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(titleFont)
                .lineLimit(2).textSelection(.enabled).help(title).contentTransition(.opacity)
            Spacer(minLength: 0)
            TezToolButton(title: "收起详情", symbol: "xmark", action: close)
        }
    }
}

struct TezEmptyState: View {
    let title: String
    let symbol: String
    var detail: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let detail { Text(detail) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TezProfileRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let current: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TezType.body.weight(.medium))
                    .lineLimit(2, reservesSpace: true).help(title)
                Text(subtitle).font(TezType.metadata)
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "checkmark.circle.fill").accessibilityLabel("当前配置")
            }
        }
        .frame(height: 60)
    }
}

// Native table cell hosts do not inherit the workspace's observable preferences.
struct TezStatusLabel: View {
    let title: String
    var tone: TezTone = .neutral
    var symbol: String? = nil
    var motion = TezMotion(reduced: true)
    var inheritsForeground = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            let icon = Image(systemName: symbol ?? tone.symbol).contentTransition(motion.symbol)
            if inheritsForeground { icon } else { icon.foregroundStyle(tone.color) }
        }
        .font(TezType.body)
        .animation(motion.feedback, value: title)
        .accessibilityElement(children: .combine)
    }
}

struct TezOperationFeedback: View {
    let message: String
    var details: String? = nil
    var tone: TezTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).foregroundStyle(.primary).textSelection(.enabled)
            } icon: {
                Image(systemName: tone.symbol).foregroundStyle(tone.color)
            }
            .font(TezType.body)
            .fixedSize(horizontal: false, vertical: true)
            if let details {
                DisclosureGroup("技术详情") {
                    ScrollView {
                        Text(details).font(TezType.code)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
                .font(TezType.metadata)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TezLatencyValue: View {
    let label: String
    var testing = false
    var failed = false
    var motion = TezMotion(reduced: true)
    var inheritsForeground = false

    var body: some View {
        HStack(spacing: 5) {
            if testing { ProgressView().controlSize(.mini) }
            if inheritsForeground {
                value
            } else {
                value.foregroundStyle(failed ? TezTone.warning.color : Color.secondary)
            }
        }
        .font(TezType.body)
        .lineLimit(1)
        .animation(motion.feedback, value: label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("延迟：\(label)")
    }

    private var value: some View {
        Text(label).monospacedDigit()
            .contentTransition(motion.reduced ? .identity : .numericText())
    }
}

struct TezConnectionPresentation {
    let state: NativeBackendState
    let hasSnapshot: Bool
    let coreState: String?
    let writable: Bool

    var busy: Bool { state == .connecting || state == .renewing || state == .stopping }
    var title: String {
        switch state {
        case .disconnected: "后台未连接"
        case .connecting: "正在连接后台"
        case .connected: "后台已连接"
        case .renewing: "正在恢复只读连接"
        case .failed: "后台连接失败"
        case .stopping: "正在安全退出后台"
        case .shutdownFailed: "后台退出未确认"
        }
    }
    var tone: TezTone {
        switch state {
        case .connected: .success
        case .failed, .shutdownFailed: .error
        case .renewing: .warning
        default: .neutral
        }
    }
    var context: String {
        if state == .stopping { return "等待内核停止，暂不可重新连接" }
        if state == .shutdownFailed { return "请重试安全退出" }
        if state == .connected { return writable ? "管理访问" : "只读访问" }
        return hasSnapshot ? "离线快照 · 数据不再同步" : "内核与系统代理状态未读取"
    }
    var coreTitle: String {
        guard state == .connected else { return "内核状态未确认" }
        switch coreState {
        case "ready": return "内核运行中"
        case "unavailable": return "内核不可用"
        case "error": return "内核读取失败"
        default: return "内核状态未确认"
        }
    }
    var coreTone: TezTone { state == .connected && coreState == "ready" ? .success : .neutral }
}

struct TezConnectionBar: View {
    let presentation: TezConnectionPresentation
    let error: String?
    let reconnect: () -> Void
    let retryShutdown: () -> Void
    var motion = TezMotion(reduced: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    status
                    Spacer(minLength: 8)
                    context
                    action
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { status; Spacer(minLength: 8); action }
                    context
                }
            }
            if let error {
                DisclosureGroup("查看错误详情") {
                    Text(error).font(TezType.metadata).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(TezType.metadata)
            }
        }
        .padding(.horizontal, TezStyle.pageInset)
        .padding(.vertical, presentation.state == .connected && error == nil ? 6 : 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("live.connection.status")
    }

    private var status: some View {
        HStack(spacing: 8) {
            if presentation.busy { ProgressView().controlSize(.small) }
            TezStatusLabel(title: presentation.title, tone: presentation.tone, motion: motion)
                .fontWeight(.medium).fixedSize()
        }
    }

    private var context: some View {
        HStack(spacing: 12) {
            if presentation.state == .connected {
                TezStatusLabel(title: presentation.coreTitle, tone: presentation.coreTone, symbol: "cpu")
            }
            Text(presentation.context).font(TezType.metadata).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        switch presentation.state {
        case .disconnected, .failed:
            Button(presentation.state == .failed ? "重新连接" : "连接后台", systemImage: "link", action: reconnect)
                .accessibilityIdentifier("live.connect")
        case .shutdownFailed:
            Button("重试安全退出", systemImage: "arrow.clockwise", action: retryShutdown)
        default: EmptyView()
        }
    }
}

struct TezTableSelectionVisibility: NSViewRepresentable {
    let selectionID: String?
    var selectionIndex: Int? = nil

    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) {
        if view.selectionID != selectionID || view.selectionIndex != selectionIndex {
            view.selectionID = selectionID
            view.selectionIndex = selectionIndex
            view.scheduleScroll()
        }
    }

    final class SelectionView: NSView {
        var selectionID: String?
        var selectionIndex: Int?
        private var previousSize = NSSize.zero
        private var scrollScheduled = false
        private weak var observedClip: NSClipView?
        private weak var observedTable: NSTableView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            if bounds.size != previousSize {
                previousSize = bounds.size
                scheduleScroll()
            }
        }

        func scheduleScroll() {
            guard !scrollScheduled else { return }
            scrollScheduled = true
            // Scroll after AppKit finishes resizing the table, never during its row layout.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollScheduled = false
                guard self.selectionID != nil else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let table = self.table(in: view) {
                        self.observe(table)
                        // A recreated SwiftUI table can lose its native highlight while the binding remains selected.
                        if table.selectedRow < 0, let index = self.selectionIndex, (0..<table.numberOfRows).contains(index) {
                            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                        }
                        guard table.selectedRow >= 0 else { return }
                        let row = table.rect(ofRow: table.selectedRow)
                        let visible = table.visibleRect
                        let delta = row.minY < visible.minY ? row.minY - visible.minY
                            : row.maxY > visible.maxY ? row.maxY - visible.maxY : 0
                        if delta != 0, let scroll = table.enclosingScrollView {
                            var origin = scroll.contentView.bounds.origin
                            origin.y += delta
                            scroll.contentView.scroll(to: origin)
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }

        private func observe(_ table: NSTableView) {
            let clip = table.enclosingScrollView?.contentView
            guard observedTable !== table || observedClip !== clip else { return }
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedTable)
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedClip)
            observedTable = table
            observedClip = clip
            table.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(tableResized),
                                                   name: NSView.frameDidChangeNotification, object: table)
            clip?.postsFrameChangedNotifications = true
            if let clip {
                NotificationCenter.default.addObserver(self, selector: #selector(tableResized),
                                                       name: NSView.frameDidChangeNotification, object: clip)
            }
        }

        @objc private func tableResized() { scheduleScroll() }

        private func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let table = table(in: child) { return table }
            }
            return nil
        }
    }
}
