import Foundation

@main
struct BackendWireCheck {
    static func require(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
        if try !condition() { throw BackendWireError.invalid("Check failed: \(detail)") }
    }

    static func rejects(_ detail: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch { return }
        throw BackendWireError.invalid("Expected rejection: \(detail)")
    }

    static func main() {
        do {
            if CommandLine.arguments.contains("--roundtrip") {
                var decoder = BackendFrameDecoder()
                while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
                    for message in try decoder.append(chunk) {
                        try FileHandle.standardOutput.write(contentsOf: BackendWire.encode(message))
                    }
                }
                try decoder.finish()
                return
            }
            try checks()
            FileHandle.standardError.write(Data("Backend wire checks passed\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func checks() throws {
        let messages: [BackendMessage] = [
            .request(id: "r1", command: "read", params: ["unicode": .string("\u{4F60}\u{597D}\u{1F680}"), "bool": .bool(true), "min": .integer(.min), "max": .unsigned(.max)]),
            .response(id: "r1", outcome: .result(.null)),
            .response(id: "r2", outcome: .error(.init(detail: "failed", code: .null, operation: .object(["task": .array([.bool(false), .integer(17)])])))),
            .event(sequence: "184467440737095516160", name: "changed", payload: .array([.null, .number(0.25)])),
            .hello(sessionID: "s1", capabilities: ["read", "events"])
        ]
        var all = Data()
        for message in messages {
            let frame = try BackendWire.encode(message)
            all.append(frame)
            try require(BackendWire.decode(frame.dropLast()) == message, "message roundtrip")
        }
        for size in [1, 2, 7, 31, all.count] {
            var decoder = BackendFrameDecoder()
            var received: [BackendMessage] = []
            for offset in stride(from: 0, to: all.count, by: size) {
                received += try decoder.append(all.subdata(in: offset..<min(offset + size, all.count)))
            }
            try decoder.finish()
            try require(received == messages, "chunk size \(size)")
        }
        let invalid = [
            "{}", "[]", "null", "{", "{\"version\":true,\"kind\":\"hello\"}",
            "{\"version\":2,\"kind\":\"hello\"}", "{\"version\":1,\"kind\":\"unknown\"}",
            "{\"version\":1.0,\"kind\":\"response\",\"id\":\"r\",\"result\":null}",
            "{\"version\":1e0,\"kind\":\"response\",\"id\":\"r\",\"result\":null}",
            "{\"version\":1,\"kind\":\"response\",\"id\":\"r\"}",
            "{\"version\":1,\"kind\":\"response\",\"id\":\"r\",\"result\":null,\"error\":null}",
            "{\"version\":1,\"kind\":\"request\",\"id\":\"\",\"command\":\"x\",\"params\":{}}",
            "{\"version\":1,\"kind\":\"request\",\"id\":\"r\",\"command\":\"x\",\"params\":[]}",
            "{\"version\":1,\"kind\":\"response\",\"id\":\"r\",\"error\":{\"detail\":\"x\",\"code\":2}}",
            "{\"version\":1,\"kind\":\"hello\",\"protocol\":\"bad\",\"sessionID\":\"s\",\"capabilities\":[]}",
            "{\"version\":1,\"kind\":\"hello\",\"protocol\":\"tez.native\",\"sessionID\":\"s\",\"capabilities\":[1]}",
            "{\"version\":1,\"version\":1,\"kind\":\"hello\"}",
            "{\"version\":1,\"vers\\u0069on\":1,\"kind\":\"hello\"}"
        ]
        for json in invalid { try rejects(json) { _ = try BackendWire.decode(Data(json.utf8)) } }
        for number in ["18446744073709551616", "-9223372036854775809"] {
            try rejects("out-of-range integer \(number)") {
                _ = try BackendWire.decode(Data("{\"version\":1,\"kind\":\"response\",\"id\":\"r\",\"result\":{\"nested\":[\(number)]}}".utf8))
            }
            let quoted = BackendMessage.response(id: "r", outcome: .result(.string(number)))
            try require(BackendWire.decode(BackendWire.encode(quoted).dropLast()) == quoted, "integer digits in string")
        }
        for number in ["18446744073709551616.0", "-9223372036854775809e0", "1e100"] {
            _ = try BackendWire.decode(Data("{\"version\":1,\"kind\":\"response\",\"id\":\"r\",\"result\":\(number)}".utf8))
        }
        for sequence in ["", "01", "-1", "1.0", " 1", "\u{0661}"] {
            try rejects("sequence \(sequence)") { _ = try BackendWire.encode(.event(sequence: sequence, name: "x", payload: .null)) }
        }
        try rejects("invalid UTF-8") { _ = try BackendWire.decode(Data([255])) }
        try rejects("blank frame") { var decoder = BackendFrameDecoder(); _ = try decoder.append(Data([10])) }
        try rejects("truncated frame") { var decoder = BackendFrameDecoder(); _ = try decoder.append(Data("{".utf8)); try decoder.finish() }
        try rejects("oversized frame") { var decoder = BackendFrameDecoder(); _ = try decoder.append(Data(repeating: 32, count: BackendWire.maximumFrameBytes)) }
        let base = try BackendWire.encode(.response(id: "r", outcome: .result(.string(""))))
        let padding = String(repeating: "a", count: BackendWire.maximumFrameBytes - base.count)
        let exact = try BackendWire.encode(.response(id: "r", outcome: .result(.string(padding))))
        try require(exact.count == BackendWire.maximumFrameBytes, "inclusive maximum")
        var decoder = BackendFrameDecoder()
        try require(decoder.append(exact).count == 1, "maximum frame accepted")
        try decoder.finish()
        try rejects("oversized encode") { _ = try BackendWire.encode(.response(id: "r", outcome: .result(.string(padding + "a")))) }
    }
}
