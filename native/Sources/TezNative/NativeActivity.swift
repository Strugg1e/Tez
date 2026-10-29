import Foundation
import Observation

struct NativeActivity: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let source: String?
    let connections: NativeActivityConnections
    let rules: NativeActivitySection<NativeActivityRule>
    let providers: NativeActivitySection<NativeActivityProvider>

    static func decode(_ value: BackendJSON) throws -> Self {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 5 * 1024 * 1024 else { throw BackendWireError.invalid("Activity exceeds size limit") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 1,
              [nil, "service", "sidecar"].contains(result.source),
              result.connections.items.count <= 128,
              result.rules.items.count <= 256,
              result.providers.items.count <= 64,
              result.connections.total >= UInt64(result.connections.items.count),
              result.rules.total >= UInt64(result.rules.items.count),
              result.providers.total >= UInt64(result.providers.items.count),
              Set(result.connections.items.map(\.id)).count == result.connections.items.count,
              Set(result.rules.items.map(\.index)).count == result.rules.items.count,
              Set(result.providers.items.map(\.name)).count == result.providers.items.count else {
            throw BackendWireError.invalid("Invalid activity projection")
        }
        for state in [result.connections.state, result.rules.state, result.providers.state] {
            guard ["ready", "error", "unavailable"].contains(state) else {
                throw BackendWireError.invalid("Invalid activity state")
            }
        }
        try NativeActivityPage.validate(total: result.connections.total, count: result.connections.items.count,
            matched: result.connections.matched, offset: result.connections.offset, nextOffset: result.connections.nextOffset)
        try NativeActivityPage.validate(total: result.rules.total, count: result.rules.items.count,
            matched: result.rules.matched, offset: result.rules.offset, nextOffset: result.rules.nextOffset)
        try NativeActivityPage.validate(total: result.providers.total, count: result.providers.items.count,
            matched: result.providers.matched, offset: result.providers.offset, nextOffset: result.providers.nextOffset)
        guard result.connections.items.allSatisfy({ row in
            !row.id.isEmpty && row.chains.count <= 8
                && ([row.id, row.host, row.destination, row.network, row.type, row.process, row.rule, row.start].compactMap { $0 } + row.chains)
                    .allSatisfy { $0.count <= 512 }
        }), result.rules.items.allSatisfy({ row in
            [row.type, row.payload, row.proxy].compactMap { $0 }.allSatisfy { $0.count <= 512 }
        }), result.providers.items.allSatisfy({ row in
            !row.name.isEmpty && [row.name, row.behavior, row.format, row.type, row.updatedAt, row.vehicleType]
                .compactMap { $0 }.allSatisfy { $0.count <= 512 }
        }) else { throw BackendWireError.invalid("Activity text exceeds projection limits") }
        return result
    }

    func validate(query: NativeActivityQuery) throws {
        let state: String
        let offset: UInt64?
        let matched: UInt64?
        let count: Int
        switch query.section {
        case "connections": (state, offset, matched, count) = (connections.state, connections.offset, connections.matched, connections.items.count)
        case "rules": (state, offset, matched, count) = (rules.state, rules.offset, rules.matched, rules.items.count)
        case "providers": (state, offset, matched, count) = (providers.state, providers.offset, providers.matched, providers.items.count)
        default: throw BackendWireError.invalid("Unsupported activity query")
        }
        guard state != "ready" || (matched != nil && offset == query.offset && UInt64(count) <= query.limit) else {
            throw BackendWireError.invalid("Activity response does not match requested page")
        }
    }
}

struct NativeActivityConnections: Codable, Equatable, Sendable {
    let state: String
    let code: String?
    let items: [NativeActivityConnection]
    let total: UInt64
    let matched: UInt64?
    let offset: UInt64?
    let nextOffset: UInt64?
    let truncated: Bool
    let uploadTotal: UInt64?
    let downloadTotal: UInt64?
    let memory: UInt64?
    let message: String?
}

struct NativeActivitySection<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let state: String
    let code: String?
    let items: [Item]
    let total: UInt64
    let matched: UInt64?
    let offset: UInt64?
    let nextOffset: UInt64?
    let truncated: Bool
    let message: String?
}

struct NativeActivityConnection: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let host: String?
    let destination: String?
    let network: String?
    let type: String?
    let process: String?
    let rule: String?
    let chains: [String]
    let upload: UInt64
    let download: UInt64
    let start: String?
    var closeable: Bool? = nil

    var title: String { nonempty(host) ?? destination.flatMap { $0.hasPrefix(":") ? nil : nonempty($0) } ?? "未知目标" }
    var destinationLabel: String? {
        nonempty(destination).map { $0.hasPrefix(":") ? "端口 \($0.dropFirst())" : $0 }
    }
    var ruleQuery: String? { nonempty(rule) }
    var logQuery: String? {
        nonempty(host) ?? nonempty(destination).flatMap { $0.hasPrefix(":") ? nil : $0 }
    }
    func matches(_ query: String) -> Bool {
        query.isEmpty || [host, destination, network, type, process, rule]
            .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

struct NativeConnectionRate: Equatable, Sendable {
    let upload: Double?
    let download: Double?
    var status: String {
        guard let upload, let download else { return "活跃" }
        return upload > 0 || download > 0 ? "传输中" : "空闲"
    }
    static func label(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        return NativeActivityFormat.bytes(UInt64(min(bytes, Double(UInt64.max / 2)))) + "/s"
    }
}

struct NativeActivityRates {
    private var sampledAt: TimeInterval?
    private var previous: NativeActivityConnections?
    private(set) var connections: [String: NativeConnectionRate] = [:]
    private(set) var total = NativeConnectionRate(upload: nil, download: nil)

    mutating func reset() { self = Self() }

    mutating func sample(_ current: NativeActivityConnections, at now: TimeInterval) {
        guard current.state == "ready" else { reset(); return }
        let elapsed = sampledAt.map { now - $0 } ?? 0
        func rate(_ current: UInt64?, _ previous: UInt64?) -> Double? {
            guard elapsed > 0, let current, let previous, current >= previous else { return nil }
            return Double(current - previous) / elapsed
        }
        let oldRows = Dictionary(uniqueKeysWithValues: (previous?.items ?? []).map { ($0.id, $0) })
        connections = Dictionary(uniqueKeysWithValues: current.items.map { row in
            (row.id, NativeConnectionRate(upload: rate(row.upload, oldRows[row.id]?.upload),
                                         download: rate(row.download, oldRows[row.id]?.download)))
        })
        total = NativeConnectionRate(upload: rate(current.uploadTotal, previous?.uploadTotal),
                                     download: rate(current.downloadTotal, previous?.downloadTotal))
        sampledAt = now
        previous = current
    }
}

struct NativeActivityRule: Codable, Equatable, Sendable, Identifiable {
    let index: UInt64
    let type: String?
    let payload: String?
    let proxy: String?
    let size: UInt64?
    var id: UInt64 { index }
    func matches(_ query: String) -> Bool {
        query.isEmpty || [type, payload, proxy].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

struct NativeActivityProvider: Codable, Equatable, Sendable, Identifiable {
    let name: String
    let behavior: String?
    let format: String?
    let type: String?
    let ruleCount: UInt64?
    let updatedAt: String?
    let vehicleType: String?
    var id: String { name }
    func matches(_ query: String) -> Bool {
        query.isEmpty || [name, behavior, format, type, vehicleType].compactMap { $0 }
            .joined(separator: " ").localizedCaseInsensitiveContains(query)
    }
}

private func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }

enum NativeActivityPage {
    static func validate(total: UInt64, count: Int, matched: UInt64?, offset: UInt64?, nextOffset: UInt64?) throws {
        guard let matched, let offset else {
            guard matched == nil, offset == nil, nextOffset == nil else {
                throw BackendWireError.invalid("Incomplete activity page")
            }
            return
        }
        let count = UInt64(count)
        guard matched <= total, offset <= 1_000_000, count <= matched,
              count == 0 || (offset <= matched && count <= matched - offset) else {
            throw BackendWireError.invalid("Invalid activity page bounds")
        }
        if let nextOffset {
            guard count > 0, nextOffset == offset + count, nextOffset < matched, nextOffset <= 1_000_000 else {
                throw BackendWireError.invalid("Invalid activity next page")
            }
        }
    }
}

struct NativeActivityQuery: Equatable, Hashable, Sendable {
    var section: String
    var query = ""
    var offset: UInt64 = 0
    var limit: UInt64

    var params: [String: BackendJSON] {
        ["section": .string(section), "query": .string(query), "offset": .unsigned(offset), "limit": .unsigned(limit)]
    }

    var isValid: Bool {
        let maximum: UInt64 = switch section { case "connections": 128; case "rules": 256; case "providers": 64; default: 0 }
        return maximum > 0 && limit > 0 && limit <= maximum && offset <= 1_000_000 && query.utf8.count <= 256
    }
}

enum ActivityTab: String, CaseIterable, Identifiable {
    case connections, rules, providers
    var id: Self { self }
    var pageSize: UInt64 { switch self { case .connections: 128; case .rules: 256; case .providers: 64 } }
    var title: String { switch self { case .connections: "连接"; case .rules: "规则"; case .providers: "规则源" } }
    var symbol: String { switch self { case .connections: "network"; case .rules: "line.3.horizontal.decrease"; case .providers: "shippingbox" } }
    var searchPrompt: String { switch self { case .connections: "搜索连接"; case .rules: "搜索规则"; case .providers: "搜索规则源" } }
    var emptyTitle: String { switch self { case .connections: "暂无活动连接"; case .rules: "暂无规则"; case .providers: "暂无规则源" } }
    var unavailableTitle: String { switch self { case .connections: "连接数据不可用"; case .rules: "规则数据不可用"; case .providers: "规则源数据不可用" } }
}

struct NativeActivityContext {
    private var queries: [ActivityTab: NativeActivityQuery] = [:]
    var connectionID: String?
    var ruleID: UInt64?
    var providerID: String?

    func request(for tab: ActivityTab) -> NativeActivityQuery {
        queries[tab] ?? NativeActivityQuery(section: tab.rawValue, limit: tab.pageSize)
    }

    mutating func search(_ query: String, in tab: ActivityTab) {
        guard request(for: tab).query != query else { return }
        queries[tab] = NativeActivityQuery(section: tab.rawValue, query: query, limit: tab.pageSize)
        clearSelection(in: tab)
    }

    mutating func move(to offset: UInt64, in tab: ActivityTab) {
        var query = request(for: tab)
        guard query.offset != offset else { return }
        query.offset = offset
        queries[tab] = query
        clearSelection(in: tab)
    }

    mutating func clearSelection(in tab: ActivityTab) {
        switch tab {
        case .connections: connectionID = nil
        case .rules: ruleID = nil
        case .providers: providerID = nil
        }
    }

    mutating func reconcileSelection(in snapshot: NativeActivity, for tab: ActivityTab) {
        switch tab {
        case .connections:
            if !snapshot.connections.items.contains(where: { $0.id == connectionID }) { connectionID = nil }
        case .rules:
            if !snapshot.rules.items.contains(where: { $0.index == ruleID }) { ruleID = nil }
        case .providers:
            if !snapshot.providers.items.contains(where: { $0.name == providerID }) { providerID = nil }
        }
    }
}

@MainActor @Observable
final class NativeActivitySession {
    var tab = ActivityTab.connections
    var showsLogs = false
    var context = NativeActivityContext()
    var paused = false
    let logs = NativeLogSession()
    private let models: [ActivityTab: NativeActivityModel] = Dictionary(
        uniqueKeysWithValues: ActivityTab.allCases.map { ($0, NativeActivityModel()) })

    func model(for tab: ActivityTab) -> NativeActivityModel { models[tab]! }

    func showRules(for connection: NativeActivityConnection) {
        guard let query = connection.ruleQuery else { return }
        context.search(query, in: .rules)
        context.move(to: 0, in: .rules)
        context.clearSelection(in: .rules)
        tab = .rules
        showsLogs = false
    }

    func showLogs(for connection: NativeActivityConnection) {
        guard let query = connection.logQuery else { return }
        logs.query = query
        logs.level = "all"
        logs.relatedTarget = query
        showsLogs = true
    }
}

struct NativeLogPayload: Decodable {
    var lines: [String]
    var gap: Bool?
    var truncated: Bool?
    var streaming: Bool?
}

struct NativeLogEntry: Equatable {
    let text: String
    let level: String?

    init(_ text: String) {
        self.text = text
        let lower = text.lowercased()
        let header = lower.components(separatedBy: " msg=")[0]
        let tokens = header.split(whereSeparator: \.isWhitespace)
        func normalized(_ token: Substring) -> String? {
            switch token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]:")) {
            case "warning", "warn": "warn"
            case "error", "fatal": "error"
            case "info": "info"
            case "debug": "debug"
            case "trace": "trace"
            default: nil
            }
        }
        if let token = tokens.first(where: { $0.hasPrefix("level=") }) {
            level = normalized(token.dropFirst(6))
        } else {
            level = tokens.filter { $0.hasPrefix("[") }.compactMap(normalized).first
                ?? lower.split(whereSeparator: \.isWhitespace).first.flatMap(normalized)
        }
    }

    func matches(query: String, level: String) -> Bool {
        (level == "all" || self.level == level) && (query.isEmpty || text.lowercased().contains(query.lowercased()))
    }
}

struct NativeLogSnapshot {
    let entries: [NativeLogEntry]
    let gap: Bool
    let truncated: Bool
    let streaming: Bool
    let acquiredAt: Date

    init(_ payload: NativeLogPayload, acquiredAt: Date = Date()) {
        entries = payload.lines.map(NativeLogEntry.init)
        gap = payload.gap ?? false
        truncated = payload.truncated ?? false
        streaming = payload.streaming ?? false
        self.acquiredAt = acquiredAt
    }
}

@MainActor @Observable
final class NativeLogSession {
    static let limit = 1000
    var query = "" {
        didSet { if query != relatedTarget { relatedTarget = nil } }
    }
    var level = "all"
    var paused = false {
        didSet { if paused { stop() } }
    }
    var followsTail = true
    var relatedTarget: String?
    private(set) var snapshot: NativeLogSnapshot?
    @ObservationIgnored private(set) var generation = UUID()

    var lines: [String] {
        snapshot?.entries.filter { $0.matches(query: query, level: level) }.map(\.text) ?? []
    }

    func stop() { generation = UUID() }

    func accept(_ payload: NativeLogPayload, generation token: UUID) {
        guard token == generation else { return }
        snapshot = NativeLogSnapshot(payload)
    }
}

enum NativeActivityFormat {
    static func issue(_ code: String?) -> String {
        switch code {
        case "controller_request": "内核请求失败。"
        case "controller_payload": "内核返回的数据格式无效。"
        case "response_too_large": "活动数据超过读取上限。"
        case "controller_timeout": "内核响应超时，请稍后刷新。"
        case "socket_unavailable": "本地控制器不可用。"
        case "controller_discovery": "未找到可用的本地控制器。"
        default: "活动数据暂不可用。"
        }
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var number = Double(value)
        var index = 0
        while number >= 1024 && index < units.count - 1 { number /= 1024; index += 1 }
        return number.formatted(.number.precision(.fractionLength(index == 0 ? 0 : 1))) + " " + units[index]
    }
}

@MainActor @Observable
final class NativeActivityModel {
    private(set) var snapshot: NativeActivity?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var updatedAt: Date?
    private(set) var snapshotQuery: NativeActivityQuery?
    private(set) var rates = NativeActivityRates()
    private(set) var closingID: String?
    private(set) var closeMessage: String?
    private(set) var closeError = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var desiredQuery: NativeActivityQuery?
    @ObservationIgnored private var activeGeneration: UUID?

    func stop(preservingRates: Bool = false) {
        generation = UUID()
        if !preservingRates { rates.reset() }
    }

    func select(_ query: NativeActivityQuery?) {
        guard desiredQuery != query else { return }
        generation = UUID()
        desiredQuery = query
        errorMessage = nil
        rates.reset()
    }

    func refresh(query: NativeActivityQuery? = nil, request: @MainActor () async throws -> BackendJSON) async {
        select(query)
        guard query?.isValid != false else { errorMessage = "搜索内容不能超过 256 字节。"; return }
        let token = generation
        if isLoading && activeGeneration == token { return }
        while isLoading {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            guard !Task.isCancelled, token == generation else { return }
        }
        guard !Task.isCancelled, token == generation else { return }
        isLoading = true
        activeGeneration = token
        defer { isLoading = false; activeGeneration = nil }
        do {
            let value = try await request()
            guard !Task.isCancelled, token == generation else { return }
            let decoded = try NativeActivity.decode(value)
            if let query { try decoded.validate(query: query) }
            snapshot = decoded
            rates.sample(decoded.connections, at: ProcessInfo.processInfo.systemUptime)
            snapshotQuery = query
            errorMessage = nil
            updatedAt = Date()
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            errorMessage = "活动数据读取失败。"
            rates.reset()
        }
    }

    func close(id: String, request: @MainActor () async throws -> BackendJSON) async -> Bool {
        guard closingID == nil, snapshotQuery == desiredQuery else { return false }
        guard snapshot?.connections.items.contains(where: { $0.id == id && $0.closeable == true }) == true else {
            closeError = false
            closeMessage = "连接已结束或不能关闭，请刷新确认。"
            return false
        }
        closingID = id
        closeMessage = nil
        closeError = false
        defer { closingID = nil }
        do {
            struct Result: Decodable { let closed: Bool; let id: String }
            let value = try await request()
            let result = try JSONDecoder().decode(Result.self, from: JSONEncoder().encode(value))
            guard result.closed, result.id == id else { throw BackendWireError.invalid("Unexpected close result") }
            closeMessage = "已关闭选中的连接"
            return true
        } catch {
            closeError = true
            closeMessage = "关闭连接失败。连接可能已结束，请刷新后确认。"
            return false
        }
    }
}
