import Foundation
import Observation

struct NativeLatencyPayload: Decodable {
    struct Result: Decodable { var name: String; var delay: UInt32?; var error: String? }
    var results: [Result]
}

struct NativeLatencySample: Equatable {
    let date: Date?
    let delay: UInt64?
}

@Observable @MainActor
final class NativeLatencyModel {
    typealias Request = @MainActor (String, [String: BackendJSON]) async throws -> BackendJSON
    private(set) var results: [String: NativeLatencyPayload.Result] = [:]
    private(set) var testing: Set<String> = []
    private(set) var busy = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var error: String?
    private(set) var stopped = false
    private var stopRequested = false
    private(set) var measuredAt: [String: Date] = [:]
    private(set) var samples: [String: [NativeLatencySample]] = [:]

    func stopAfterCurrentBatch() { stopRequested = true }

    func test(names: [String], url: String, timeout: Int, request: Request) async {
        guard !busy else { return }
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !unique.isEmpty else { return }
        busy = true; completed = 0; total = unique.count; error = nil; stopped = false; stopRequested = false
        defer { busy = false; testing = [] }
        // Small batches bound backend occupancy. Stopping never cancels a write or selects a route.
        for offset in stride(from: 0, to: unique.count, by: 4) {
            if stopRequested || Task.isCancelled { stopped = true; return }
            let batch = Array(unique[offset..<min(offset + 4, unique.count)])
            testing = Set(batch)
            for name in batch { results.removeValue(forKey: name); measuredAt.removeValue(forKey: name) }
            do {
                let value = try await request("native_test_latency", ["names": .array(batch.map(BackendJSON.string)),
                    "url": .string(url), "timeout": .integer(Int64(timeout))])
                let payload = try value.decoded(NativeLatencyPayload.self)
                guard payload.results.count == batch.count, Set(payload.results.map(\.name)) == Set(batch) else {
                    throw BackendWireError.invalid("Invalid latency result identities")
                }
                let date = Date()
                for result in payload.results {
                    results[result.name] = result
                    measuredAt[result.name] = date
                    let delay = result.error == nil ? result.delay.flatMap { $0 > 0 ? UInt64($0) : nil } : nil
                    let sample = NativeLatencySample(date: date, delay: delay)
                    samples[result.name] = Array(((samples[result.name] ?? []) + [sample]).suffix(20))
                }
                completed += batch.count
            } catch { self.error = NativeFeatureError.message(error); return }
        }
    }

    func label(for name: String, fallback: String) -> String {
        if testing.contains(name) { return "测速中" }
        guard let result = results[name] else { return fallback }
        guard result.error == nil, let delay = result.delay, delay > 0 else { return "超时 / 失败" }
        return "\(delay) ms"
    }
}
