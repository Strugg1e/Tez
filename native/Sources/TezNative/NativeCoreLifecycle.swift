import Foundation

struct NativeCoreInspection: Codable, Equatable, Sendable {
    let state: String
    let source: String
    let canStart: Bool
    let reason: String
    let corePid: UInt32?
    let serviceGeneration: UInt64?
    var serviceStartedAt: UInt64? = nil
    let processes: [NativeCoreProcess]
    var serviceProtocol: String? = nil
    var serviceControlAvailable: Bool? = nil

    var explanation: String {
        switch reason {
        case "service-upgrade-required": "当前后台服务不支持新版内核控制。更新后台服务后才能启动、停止或重启内核。"
        case "idle-service": "没有运行中的内核，可以启动 Tez 内核。"
        case "service-session-unavailable": "内核仍在服务中运行。当前缺少控制会话，先只读连接，不停止或重复启动内核。"
        case "external-core": "检测到其他内核进程。当前只读连接，不自动终止进程。"
        case "multiple-core-processes": "检测到多个内核，未自动接管。请检查下方进程来源。"
        case "service-transition-unresolved": "服务状态尚未稳定。保持观察，不重复启动内核。"
        case "process-discovery-failed": "进程检查未完成，未自动启动或接管内核。"
        case "client-already-running": "另一个 Tez 后台仍在运行。当前只读观察，不启动第二个管理后台。"
        case "managed-start-unavailable": "内核未运行，但启动条件未通过。当前保持只读，请检查服务和应用包。"
        default: "核心服务不可用或状态未确认，未自动启动另一个内核。"
        }
    }

    var stateLabel: String {
        switch state {
        case "stopped": "未运行"
        case "runningReadOnly": "检测到运行内核 · 只读"
        case "recovering": "服务恢复中"
        case "conflict": "多个内核待确认"
        default: "状态待确认"
        }
    }
}

struct NativeCoreProcess: Codable, Equatable, Sendable, Identifiable {
    let pid: UInt32
    let uid: Int64
    let executable: String
    let startedAt: String
    var id: UInt32 { pid }
    var name: String { URL(fileURLWithPath: executable).lastPathComponent }
}
