import Foundation

struct NativeSnapshot: Codable, Equatable, Sendable {
    let revision: String
    let profiles: NativeProfilesSnapshot
    let proxyView: NativeProxyView?
    let core: NativeCoreSnapshot
    var network: NativeNetworkSnapshot? = nil

    static func decode(_ value: BackendJSON) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
        guard let revision = UInt64(result.revision), String(revision) == result.revision else {
            throw BackendWireError.invalid("Invalid snapshot revision")
        }
        guard result.proxyView == nil || result.proxyView?.schemaVersion == 1 else {
            throw BackendWireError.invalid("Unsupported proxy view schema version")
        }
        return result
    }
}

struct NativeNetworkSnapshot: Codable, Equatable, Sendable {
    let systemProxy: NativeObservedSwitch
    let pac: NativeObservedSwitch
    let tun: NativeObservedSwitch
    let mode: NativeObservedMode

    var systemProxyControl: NativeObservedSwitch {
        let system = systemProxy.state == "ready" ? systemProxy.enabled : nil
        let automatic = pac.state == "ready" ? pac.enabled : nil
        if system == true || automatic == true { return NativeObservedSwitch(state: "ready", enabled: true) }
        if system == false && automatic == false { return NativeObservedSwitch(state: "ready", enabled: false) }
        return NativeObservedSwitch(state: "unavailable", enabled: nil)
    }
}

struct NativeObservedSwitch: Codable, Equatable, Sendable {
    let state: String
    let enabled: Bool?
    var label: String {
        guard state == "ready", let enabled else { return "未确认" }
        return enabled ? "开启" : "关闭"
    }
}

struct NativeObservedMode: Codable, Equatable, Sendable {
    let state: String
    let value: String?
    var label: String {
        guard state == "ready" else { return "未确认" }
        return switch value { case "rule": "规则"; case "global": "全局"; case "direct": "直连"; default: "未确认" }
    }
}

struct NativeProfilesSnapshot: Codable, Equatable, Sendable {
    let state: String
    let current: String?
    let items: [NativeProfileItem]
    let message: String?
}

struct NativeProfileItem: Codable, Equatable, Sendable, Identifiable {
    let uid: String
    let name: String
    let type: String
    let updated: Double?
    var id: String { uid }
}

struct NativeCoreSnapshot: Codable, Equatable, Sendable {
    let state: String
    let message: String?
    var source: String? = nil
    var lifecycle: NativeCoreInspection? = nil
}

struct NativeProxyView: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let orderSource: String
    let providerState: String
    let global: NativeProxyGroup?
    let direct: String?
    let groups: [NativeProxyGroup]
    let records: [String: NativeProxyNode]
    let standalone: [String]
    let providers: [BackendJSON]
}

struct NativeProxyGroup: Codable, Equatable, Sendable, Identifiable {
    let name: String
    let type: String
    let now: String?
    let fixed: String?
    let hidden: Bool?
    let icon: String?
    let testUrl: String?
    let history: [NativeDelayHistory]
    let udp: Bool
    let xudp: Bool
    let tfo: Bool
    let mptcp: Bool
    let smux: Bool
    let members: [NativeProxyMember]
    var id: String { name }
}

struct NativeProxyMember: Codable, Equatable, Sendable {
    let kind: String
    let name: String
    let recordId: String?
    let reason: String?
}

struct NativeProxyNode: Codable, Equatable, Sendable, Identifiable {
    let recordId: String
    let name: String
    let type: String
    let history: [NativeDelayHistory]
    let id: String?
    let hidden: Bool?
    let icon: String?
    let testUrl: String?
    let udp: Bool
    let xudp: Bool
    let tfo: Bool
    let mptcp: Bool
    let smux: Bool
    let source: NativeProxySource
}

struct NativeProxySource: Codable, Equatable, Sendable {
    let kind: String
    let proxyName: String
    let providerName: String?
}

struct NativeDelayHistory: Codable, Equatable, Sendable {
    let time: String
    let delay: UInt64
}
