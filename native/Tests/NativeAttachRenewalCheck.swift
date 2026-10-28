import Foundation

@main
struct NativeAttachRenewalCheck {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NativeBackendError.unavailable("Expected bundled helper path")
        }
        let store = NativeBackendStore(helperURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            arguments: ["--stdio", "--attach"], timeout: .seconds(15), renewalRequestLimit: 2)
        defer { store.disconnect() }
        store.connect()
        try await waitUntil { store.state == .connected }
        guard store.snapshot != nil, !store.supports("native_core_start") else {
            throw NativeBackendError.unavailable("Expected read-only snapshot")
        }
        for _ in 0..<2 {
            let response = Task { try await store.request("native_get_snapshot") }
            try await waitUntil { store.state == .renewing }
            guard store.snapshot != nil, !store.supports("native_get_snapshot") else {
                throw NativeBackendError.unavailable("Renewal must retain its snapshot and suspend commands")
            }
            _ = try await response.value
            try await waitUntil { store.state == .connected }
            guard store.snapshot != nil, store.supports("native_get_activity") else {
                throw NativeBackendError.unavailable("Renewed session did not subscribe")
            }
        }
        print("PASS: real read-only helper renewed twice, retained snapshots and resubscribed without core control.")
    }

    @MainActor static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw NativeBackendError.unavailable("Read-only renewal deadline exceeded")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
