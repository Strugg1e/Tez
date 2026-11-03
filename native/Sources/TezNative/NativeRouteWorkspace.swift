import SwiftUI
import Observation

enum NativeRoutePresentation {
    static func title(_ name: String) -> String { TezProxyName.title(name) }

    static func groups(in view: NativeProxyView, mode: String?) -> [NativeProxyGroup] {
        guard let global = view.global else { return view.groups }
        let configured = view.groups.filter { $0.name != global.name }
        return mode == "global" ? [global] + configured : configured + [global]
    }
}

struct NativeRouteSwitchChange: Equatable {
    enum Outcome: Equatable { case applied, notApplied, unconfirmed }
    let group: String
    let target: String
    var outcome: Outcome?

    func isConfirmed(by current: NativeProxyGroup?) -> Bool {
        outcome == .applied && current?.name == group && current?.now == target
    }
}

struct NativeRouteContextHeader: View {
    let groups: [NativeProxyGroup]
    let group: NativeProxyGroup?
    @Binding var groupName: String?
    let mode: String?
    let groupType: String
    let currentName: String
    let previewName: String?
    let change: NativeRouteSwitchChange?
    let changeTone: TezTone
    let connected: Bool
    let switching: Bool
    let compact: Bool
    let motion: TezMotion

    private var confirmed: Bool { connected && change?.isConfirmed(by: group) == true }
    private var targetName: String? { change.map { NativeRoutePresentation.title($0.target) } ?? previewName }
    private var modeTitle: String {
        switch mode { case "rule": "规则"; case "global": "全局"; case "direct": "直连"; default: "未确认" }
    }
    private var context: String {
        guard connected else { return "离线快照；分组选择与实际出口状态未确认。" }
        switch mode {
        case "rule": return "连接按命中规则使用分组或直连，此组选择不代表所有连接的出口。"
        case "global": return group?.name == "GLOBAL"
            ? "接入 Tez 的连接按全局代理组的选择处理。"
            : "全局模式的默认去向由「全局代理」决定。"
        case "direct": return "当前使用直连；以下为配置中的分组选择。"
        default: return "分流模式尚未确认，分组选择不代表实际出口。"
        }
    }
    private var stageTitle: String {
        guard change != nil else { return "仅查看，尚未切换" }
        guard connected else { return "离线，结果未确认" }
        if switching { return "等待后台确认" }
        switch change?.outcome {
        case .applied: return confirmed ? "此组选择已更新" : "后台已应用切换请求"
        case .notApplied: return "未切换，保留原选择"
        case .unconfirmed: return "切换结果未确认"
        case nil: return "等待后台确认"
        }
    }
    private var stageTone: TezTone { !connected ? .warning : change == nil || switching ? .neutral : changeTone }
    private var compactStageTitle: String {
        if !connected { return "离线快照" }
        if switching { return "等待确认" }
        switch change?.outcome {
        case .applied: return confirmed ? "已确认" : "请求已应用"
        case .notApplied: return "未切换"
        case .unconfirmed: return "结果未确认"
        case nil: return change == nil ? "仅查看" : "等待确认"
        }
    }

    @ViewBuilder private var transferMark: some View {
        if connected {
            NativeRouteTransferMark(confirmed: confirmed, motion: motion)
        } else {
            Image(systemName: "clock").font(TezType.body).foregroundStyle(.secondary)
        }
    }

    private var progressSlot: some View {
        Group {
            if switching { ProgressView().controlSize(.mini) }
            else { Color.clear }
        }.frame(width: 12, height: 12).accessibilityHidden(!switching)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: compact ? 16 : 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connected ? "分流模式" : "上次模式").font(TezType.metadata).foregroundStyle(.secondary)
                    Text(modeTitle).font(TezType.body.weight(.medium)).frame(height: 20, alignment: .leading)
                }.frame(width: compact ? 64 : 86, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("查看分组").font(TezType.metadata).foregroundStyle(.secondary)
                    if groups.isEmpty {
                        Text("独立线路").font(TezType.body).frame(height: 20)
                    } else {
                        Picker("查看分组", selection: Binding(get: { group?.name ?? "" }, set: { groupName = $0 })) {
                            ForEach(groups) { item in
                                Text(NativeRoutePresentation.title(item.name)).tag(item.name)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small)
                        .frame(height: 20).disabled(switching)
                        .help(group?.name == "GLOBAL" ? "全局代理（GLOBAL），内核内置分组；这里只改变查看对象。" : "查看配置中的分组，不更改分流模式或节点选择。")
                        .accessibilityLabel("查看分组：\(NativeRoutePresentation.title(group?.name ?? ""))")
                        .accessibilityIdentifier("live.routes.group")
                    }
                }.frame(width: compact ? 164 : 210, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(connected ? "此分组当前选择" : "上次同步的选择").foregroundStyle(.secondary)
                        if compact {
                            Spacer(minLength: 4)
                            progressSlot
                            Text(compactStageTitle).foregroundStyle(stageTone == .neutral ? Color.secondary : stageTone.color)
                                .frame(width: 66, alignment: .trailing)
                                .opacity(targetName == nil ? 0 : 1)
                                .accessibilityHidden(targetName == nil)
                        }
                    }.font(TezType.metadata)
                    HStack(spacing: 8) {
                        Text(currentName).font(TezType.itemTitle).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading).help(currentName)
                            .contentTransition(motion.reduced ? .identity : .opacity)
                            .animation(motion.mechanism, value: currentName)
                            .accessibilityIdentifier("live.routes.current")
                        if compact {
                            Group {
                                if targetName != nil { transferMark }
                                else { Color.clear }
                            }.frame(width: 36, height: 20).accessibilityHidden(true)
                        }
                    }.frame(height: 20)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 38, alignment: .top)
            if !compact {
                Text(context).font(TezType.metadata).foregroundStyle(.secondary).lineLimit(1).help(context)
                    .frame(height: 14, alignment: .leading)
            }
            if !compact {
             HStack(spacing: 10) {
                if let targetName {
                    transferMark
                        .frame(width: 48, height: 22).accessibilityHidden(true)
                    progressSlot
                    ZStack(alignment: .leading) {
                        TezStatusLabel(title: stageTitle, tone: stageTone)
                            .fixedSize().id(stageTitle)
                            .transition(motion.reduced ? .identity : .opacity)
                    }.frame(width: 144, alignment: .leading)
                        .animation(motion.feedback, value: stageTitle)
                    Text(targetName).font(TezType.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading).help(targetName)
                        .contentTransition(motion.reduced ? .identity : .opacity)
                        .animation(motion.feedback, value: targetName)
                } else {
                    Text(groupType).font(TezType.metadata).foregroundStyle(.secondary)
                    if group?.name == "GLOBAL" {
                        Text("内置分组 · GLOBAL").font(TezType.metadata).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(connected ? "选择来自后台" : "上次同步的快照").font(TezType.metadata).foregroundStyle(.secondary)
                }
             }.frame(height: 26)
                .accessibilityIdentifier("live.routes.transition")
            }
        }
        .padding(.horizontal, TezStyle.pageInset).padding(.vertical, compact ? 8 : 12)
        .background { TezContentMaterial(material: .headerView) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.routes.context")
        .help(context)
    }
}

private struct NativeRouteTransferMark: View {
    let confirmed: Bool
    let motion: TezMotion

    var body: some View {
        ZStack {
            NativeRouteTransferPath(target: 0).stroke(.secondary.opacity(0.45), lineWidth: 1)
            NativeRouteTransferPath(target: 1).stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            NativeRouteTransferPath(target: confirmed ? 1 : 0)
                .stroke(TezStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .animation(motion.mechanism, value: confirmed)
        }
    }
}

private struct NativeRouteTransferPath: Shape {
    var target: CGFloat
    var animatableData: CGFloat {
        get { target }
        set { target = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = rect.midY
        let end = rect.minY + 3 + (rect.height - 6) * target
        path.move(to: CGPoint(x: rect.minX, y: center))
        path.addLine(to: CGPoint(x: rect.width * 0.2, y: center))
        path.addCurve(to: CGPoint(x: rect.width * 0.8, y: end),
                      control1: CGPoint(x: rect.width * 0.51, y: center),
                      control2: CGPoint(x: rect.width * 0.51, y: end))
        path.addLine(to: CGPoint(x: rect.maxX, y: end))
        return path
    }
}

@Observable @MainActor
final class NativeRouteSamplerState {
    struct Reading: Equatable {
        let samples: [NativeLatencySample]
        let testing: Bool
        let origin: String
    }

    var held: Reading?
    var captureNext = false

    func accept(_ reading: Reading) {
        guard captureNext, !reading.testing else { return }
        if held != nil { held = reading }
        captureNext = false
    }

    func reset() {
        held = nil
        captureNext = false
    }
}

struct NativeRouteSampler: View {
    let state: NativeRouteSamplerState
    let samples: [NativeLatencySample]
    let origin: String
    let testing: Bool
    let canSample: Bool
    let testURL: String
    let motion: TezMotion
    var compact = false
    let sample: () -> Void
    private var held: NativeRouteSamplerState.Reading? { state.held }
    private var input: NativeRouteSamplerState.Reading { .init(samples: samples, testing: testing, origin: origin) }
    private var shown: NativeRouteSamplerState.Reading { held ?? input }
    private var latest: NativeLatencySample? { shown.samples.last }
    private var hasNewReading: Bool { held.map { $0.samples != samples } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("延迟采样").font(TezType.section)
                Spacer()
                Text(held != nil ? (hasNewReading ? "有新读数 · 已保持" : "读数已保持") : testing ? "测量中" : "最近读数")
                    .font(TezType.metadata).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(motion.feedback, value: hasNewReading)
                    .accessibilityIdentifier("live.routes.sample.status")
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(latest.map { $0.delay.map(String.init) ?? "超时 / 失败" } ?? "未测速")
                    .font(.system(size: latest?.delay != nil ? 24 : 18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(latest != nil && latest?.delay == nil ? TezStyle.warning : .primary)
                    .contentTransition(motion.reduced ? .identity : latest?.delay == nil ? .opacity : .numericText(value: Double(latest?.delay ?? 0)))
                    .animation(motion.mechanism, value: latest)
                if latest?.delay != nil { Text("ms").font(TezType.body).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if let date = latest?.date {
                    Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
                        .font(TezType.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help("记录时间：\(date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone()))")
                }
            }
            NativeRouteSamplePlot(samples: shown.samples, motion: motion)
                .frame(height: compact ? 72 : 92)
            HStack(spacing: 8) {
                Button(held == nil ? "保持读数" : "显示最新", systemImage: held == nil ? "pause" : "play") {
                    state.held = held == nil ? input : nil
                    state.captureNext = false
                }
                .disabled(samples.isEmpty && held == nil)
                .help(held == nil ? "固定当前读数，后台仍然同步；不停止测速" : "显示最近收到的真实测速记录")
                .accessibilityIdentifier("live.routes.sample.hold")
                Spacer(minLength: 0)
                Button("测试此线路", systemImage: "scope") {
                    state.captureNext = held != nil
                    sample()
                }
                .labelStyle(.iconOnly)
                .disabled(!canSample)
                .help("测试此线路；保持读数时也会更新一次，不切换线路")
                .accessibilityIdentifier("live.routes.sample.once")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(shown.origin)
                Spacer()
                Text("\(shown.samples.count) 次记录").monospacedDigit()
            }
            .font(TezType.metadata).foregroundStyle(.secondary)
            Text(held != nil ? "仅保持显示，后台仍同步。延迟不代表端到端连接状态。" : "延迟不代表端到端连接状态。")
                .font(TezType.metadata).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: input, initial: true) { _, value in state.accept(value) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.routes.sampler")
        .help("测速地址：\(testURL)")
    }
}

private struct NativeRouteSamplePlot: View {
    let samples: [NativeLatencySample]
    let motion: TezMotion
    @State private var cursor: NativeLatencySample?
    @State private var highlighted: NativeLatencySample?
    @FocusState private var focused: Bool
    private var high: Double { max(100, ceil(Double(samples.compactMap(\.delay).max() ?? 0) / 50) * 50) }
    private var usesTime: Bool {
        samples.count > 1 && samples.allSatisfy { $0.date != nil }
            && samples.last!.date! > samples.first!.date!
    }

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        let fraction: CGFloat
        if usesTime {
            fraction = CGFloat(samples[index].date!.timeIntervalSince(samples.first!.date!)
                / samples.last!.date!.timeIntervalSince(samples.first!.date!))
        } else { fraction = samples.count <= 1 ? 1 : CGFloat(index) / CGFloat(samples.count - 1) }
        return CGPoint(x: 28 + fraction * max(0, size.width - 33),
                       y: size.height - 21 - CGFloat(Double(samples[index].delay ?? 0) / high) * (size.height - 28))
    }

    private func moveCursor(_ step: Int) {
        guard !samples.isEmpty else { return }
        let index = cursor.flatMap { samples.firstIndex(of: $0) } ?? samples.count - 1
        cursor = samples[max(0, min(samples.count - 1, index + step))]
    }

    private var cursorLabel: String {
        guard let cursor else { return usesTime ? "记录时间" : "采样顺序" }
        let time = cursor.date?.formatted(.dateTime.hour().minute().second()) ?? "时间未提供"
        return time + " · " + (cursor.delay.map { "\($0) ms" } ?? "超时 / 失败")
    }

    var body: some View {
      GeometryReader { geometry in
        ZStack {
            Canvas { context, size in
                let left: CGFloat = 28, right = max(left, size.width - 5), top: CGFloat = 7, bottom = size.height - 21
                for amount in [0.0, high / 2, high] {
                    let y = bottom - CGFloat(amount / high) * (bottom - top)
                    var line = Path()
                    line.move(to: CGPoint(x: left, y: y))
                    line.addLine(to: CGPoint(x: right, y: y))
                    context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                    context.draw(Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0))))
                        .font(TezType.metadata).foregroundColor(.secondary), at: CGPoint(x: left - 6, y: y), anchor: .trailing)
                }
                for (index, sample) in samples.enumerated() {
                    let x = point(index, in: size).x
                    if let delay = sample.delay {
                        guard index != samples.count - 1 else { continue }
                        let y = bottom - CGFloat(Double(delay) / high) * (bottom - top)
                        var stem = Path()
                        stem.move(to: CGPoint(x: x, y: bottom))
                        stem.addLine(to: CGPoint(x: x, y: y))
                        context.stroke(stem, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
                        context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(TezStyle.accent))
                    } else {
                        var cross = Path()
                        cross.move(to: CGPoint(x: x - 3, y: bottom - 3)); cross.addLine(to: CGPoint(x: x + 3, y: bottom + 3))
                        cross.move(to: CGPoint(x: x + 3, y: bottom - 3)); cross.addLine(to: CGPoint(x: x - 3, y: bottom + 3))
                        context.stroke(cross, with: .color(TezStyle.warning), lineWidth: 1.5)
                    }
                }
                if !samples.isEmpty {
                    context.draw(Text(cursorLabel).font(TezType.metadata).foregroundColor(.secondary),
                                 at: CGPoint(x: left, y: size.height), anchor: .bottomLeading)
                    if cursor == nil && samples.contains(where: { $0.delay == nil }) {
                        context.draw(Text("含超时 / 失败").font(TezType.metadata).foregroundColor(TezStyle.warning),
                                     at: CGPoint(x: right, y: size.height), anchor: .bottomTrailing)
                    }
                }
            }
            if let latest = samples.last, latest.delay != nil {
                let position = point(samples.count - 1, in: geometry.size)
                Path { path in
                    path.move(to: CGPoint(x: position.x, y: geometry.size.height - 21))
                    path.addLine(to: position)
                }
                .stroke(.secondary.opacity(0.45), lineWidth: 1)
                .id(latest.date).transition(.opacity)
                Circle().fill(TezStyle.accent).frame(width: 5, height: 5)
                    .id(latest.date)
                    .transition(motion.reduced ? .identity : .scale(scale: 0.35).combined(with: .opacity))
                    .position(position)
                    .allowsHitTesting(false)
            }
            if let cursor, let index = samples.firstIndex(of: cursor) {
                let position = point(index, in: geometry.size)
                Rectangle().fill(TezStyle.accent.opacity(0.55))
                    .frame(width: 1, height: max(0, geometry.size.height - 28))
                    .position(x: position.x, y: (geometry.size.height - 14) / 2)
                    .animation(motion.mechanism, value: position.x)
                    .allowsHitTesting(false)
                Circle().stroke(TezStyle.accent, lineWidth: 1.5)
                    .frame(width: 11, height: 11).position(position)
                    .allowsHitTesting(false)
            }
            if let latest = samples.last, latest.delay != nil {
                Circle().stroke(TezStyle.accent, lineWidth: 1.5)
                    .frame(width: 13, height: 13).position(point(samples.count - 1, in: geometry.size))
                    .opacity(highlighted == latest && !motion.reduced ? 1 : 0)
                    .animation(motion.feedback, value: highlighted)
                    .allowsHitTesting(false)
            }
            if samples.isEmpty {
                Text("暂无测速记录").font(TezType.metadata).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .animation(motion.mechanism, value: samples.last)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard !samples.isEmpty else { return }
                let index = samples.indices.min { abs(point($0, in: geometry.size).x - location.x) < abs(point($1, in: geometry.size).x - location.x) }
                cursor = index.map { samples[$0] }
            case .ended: if !focused { cursor = nil }
            }
        }
        .onTapGesture { focused = !samples.isEmpty }
      }
        .focusable(!samples.isEmpty)
        .focused($focused)
        .onKeyPress(.leftArrow) { moveCursor(-1); return .handled }
        .onKeyPress(.rightArrow) { moveCursor(1); return .handled }
        .onChange(of: focused) { _, value in
            if value && cursor == nil { cursor = samples.last }
            else if !value { cursor = nil }
        }
        .onChange(of: samples) { old, new in
            if let cursor, !new.contains(cursor) { self.cursor = nil }
            if old.last != new.last { highlighted = new.last }
        }
        .task(id: highlighted) {
            guard highlighted != nil else { return }
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            highlighted = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("真实延迟采样，\(samples.count) 次记录")
        .accessibilityValue(cursor == nil ? samples.map { $0.delay.map { "\($0) 毫秒" } ?? "超时或失败" }.joined(separator: "，") : cursorLabel)
        .accessibilityAdjustableAction { direction in
            switch direction { case .increment: moveCursor(1); case .decrement: moveCursor(-1); @unknown default: break }
        }
        .accessibilityIdentifier("live.routes.sample.plot")
        .help("查看真实采样点的时间和延迟；聚焦后用左右方向键切换记录")
    }
}
