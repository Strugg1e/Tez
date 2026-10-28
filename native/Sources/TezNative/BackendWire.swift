import Foundation

enum BackendWireError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let detail): return detail
        }
    }
}

indirect enum BackendJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([BackendJSON])
    case object([String: BackendJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(UInt64.self) { self = .unsigned(item) }
        else if let item = try? value.decode(Double.self), item.isFinite { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([BackendJSON].self) { self = .array(item) }
        else { self = .object(try value.decode([String: BackendJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .unsigned(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}

struct BackendRemoteError: Equatable, Sendable {
    let detail: String
    let code: BackendJSON?
    let operation: BackendJSON?
}

enum BackendResponse: Equatable, Sendable {
    case result(BackendJSON)
    case error(BackendRemoteError)
}

enum BackendMessage: Equatable, Sendable {
    case request(id: String, command: String, params: [String: BackendJSON])
    case response(id: String, outcome: BackendResponse)
    case event(sequence: String, name: String, payload: BackendJSON)
    case hello(sessionID: String, capabilities: [String])
}

enum BackendWire {
    static let maximumFrameBytes = 8 * 1024 * 1024

    static func decode(_ data: Data) throws -> BackendMessage {
        guard data.count < maximumFrameBytes else { throw BackendWireError.invalid("Frame exceeds maximum size") }
        guard String(data: data, encoding: .utf8) != nil else {
            throw BackendWireError.invalid("Frame is not UTF-8")
        }
        try validateJSONTokens(data)
        guard case .object(let object) = try JSONDecoder().decode(BackendJSON.self, from: data) else {
            throw BackendWireError.invalid("Envelope must be an object")
        }
        guard object["version"] == .integer(1) else {
            throw BackendWireError.invalid("Unsupported version")
        }
        func string(_ key: String, nonempty: Bool = true) throws -> String {
            guard case .string(let value) = object[key], !nonempty || !value.isEmpty else {
                throw BackendWireError.invalid("Invalid \(key)")
            }
            return value
        }
        func required(_ key: String) throws -> BackendJSON {
            guard let value = object[key] else { throw BackendWireError.invalid("Missing \(key)") }
            return value
        }
        switch try string("kind") {
        case "request":
            guard case .object(let params) = object["params"] else {
                throw BackendWireError.invalid("Invalid params")
            }
            return .request(id: try string("id"), command: try string("command"), params: params)
        case "response":
            let id = try string("id")
            guard (object["result"] != nil) != (object["error"] != nil) else {
                throw BackendWireError.invalid("Response must contain exactly one of result or error")
            }
            if let result = object["result"] { return .response(id: id, outcome: .result(result)) }
            guard case .object(let error) = object["error"], case .string(let detail) = error["detail"] else {
                throw BackendWireError.invalid("Invalid error")
            }
            if let code = error["code"], code != .null {
                guard case .string = code else { throw BackendWireError.invalid("Invalid error code") }
            }
            return .response(id: id, outcome: .error(.init(detail: detail, code: error["code"], operation: error["operation"])))
        case "event":
            let sequence = try string("sequence")
            let digits = sequence.utf8
            guard digits.allSatisfy({ $0 >= 48 && $0 <= 57 }), sequence == "0" || digits.first != 48 else {
                throw BackendWireError.invalid("Invalid event sequence")
            }
            return .event(sequence: sequence, name: try string("name"), payload: try required("payload"))
        case "hello":
            guard try string("protocol") == "tez.native", case .array(let values) = object["capabilities"] else {
                throw BackendWireError.invalid("Invalid hello")
            }
            let capabilities = try values.map { value -> String in
                guard case .string(let item) = value else { throw BackendWireError.invalid("Invalid capability") }
                return item
            }
            return .hello(sessionID: try string("sessionID"), capabilities: capabilities)
        default: throw BackendWireError.invalid("Unsupported kind")
        }
    }

    static func encode(_ message: BackendMessage) throws -> Data {
        var object: [String: BackendJSON] = ["version": .integer(1)]
        switch message {
        case .request(let id, let command, let params):
            object.merge(["kind": .string("request"), "id": .string(id), "command": .string(command), "params": .object(params)]) { _, new in new }
        case .response(let id, let outcome):
            object["kind"] = .string("response")
            object["id"] = .string(id)
            switch outcome {
            case .result(let value): object["result"] = value
            case .error(let error):
                var value: [String: BackendJSON] = ["detail": .string(error.detail)]
                value["code"] = error.code
                value["operation"] = error.operation
                object["error"] = .object(value)
            }
        case .event(let sequence, let name, let payload):
            object.merge(["kind": .string("event"), "sequence": .string(sequence), "name": .string(name), "payload": payload]) { _, new in new }
        case .hello(let sessionID, let capabilities):
            object.merge(["kind": .string("hello"), "protocol": .string("tez.native"), "sessionID": .string(sessionID), "capabilities": .array(capabilities.map(BackendJSON.string))]) { _, new in new }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(BackendJSON.object(object))
        _ = try decode(data)
        data.append(10)
        guard data.count <= maximumFrameBytes else { throw BackendWireError.invalid("Frame exceeds maximum size") }
        return data
    }

    // JSONDecoder discards duplicate keys and rounds integers outside its integer domain.
    private static func validateJSONTokens(_ data: Data) throws {
        let bytes = Array(data)
        var depth = 0
        var index = 0
        var expectsKey = false
        var keys = Set<String>()
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                if depth == 1 && expectsKey && index < bytes.count {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard keys.insert(key).inserted else { throw BackendWireError.invalid("Duplicate envelope key: \(key)") }
                    if key == "version" {
                        var cursor = index + 1
                        while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
                        if cursor < bytes.count && bytes[cursor] == 58 {
                            cursor += 1
                            while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
                            let start = cursor
                            while cursor < bytes.count && ![9, 10, 13, 32, 44, 125].contains(bytes[cursor]) { cursor += 1 }
                            guard bytes[start..<cursor].elementsEqual([49]) else {
                                throw BackendWireError.invalid("Unsupported version")
                            }
                        }
                    }
                    expectsKey = false
                }
            } else if byte == 45 || (byte >= 48 && byte <= 57) {
                let start = index
                while index < bytes.count {
                    let item = bytes[index]
                    guard (item >= 48 && item <= 57) || [45, 43, 46, 69, 101].contains(item) else { break }
                    index += 1
                }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                if !token.contains(".") && !token.contains("e") && !token.contains("E"),
                   Int64(token) == nil && UInt64(token) == nil {
                    throw BackendWireError.invalid("Integer outside supported range")
                }
                index -= 1
            } else if byte == 123 || byte == 91 {
                depth += 1
                if depth == 1 && byte == 123 { expectsKey = true }
            } else if byte == 125 || byte == 93 { depth -= 1 }
            else if byte == 44 && depth == 1 { expectsKey = true }
            index += 1
        }
    }
}

struct BackendFrameDecoder {
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [BackendMessage] {
        var messages: [BackendMessage] = []
        for byte in data {
            guard pending.count < BackendWire.maximumFrameBytes - 1 || (byte == 10 && pending.count == BackendWire.maximumFrameBytes - 1) else {
                throw BackendWireError.invalid("Frame exceeds maximum size")
            }
            if byte == 10 {
                guard !pending.isEmpty else { throw BackendWireError.invalid("Blank frame") }
                messages.append(try BackendWire.decode(pending))
                pending.removeAll(keepingCapacity: true)
            } else { pending.append(byte) }
        }
        return messages
    }

    mutating func finish() throws {
        guard pending.isEmpty else { throw BackendWireError.invalid("Incomplete frame at EOF") }
    }
}
