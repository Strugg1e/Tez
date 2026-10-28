import Foundation

@main
struct NativeIsolatedConnectionCheck {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NativeBackendError.unavailable(message) }
    }

    static func object(_ value: BackendJSON) throws -> [String: BackendJSON] {
        guard case .object(let result) = value else { throw NativeBackendError.unavailable("Expected object") }
        return result
    }

    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NativeBackendError.unavailable("Usage: native-isolated-connection-check BUNDLED_HELPER NEW_ISOLATED_ROOT")
        }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
        try require(!FileManager.default.fileExists(atPath: root), "Isolated root must not exist")
        let store = NativeBackendStore(helperURL: helper, arguments: ["--stdio", "--isolated", root],
                                       timeout: .seconds(30), mode: .managed)
        store.connect()
        do {
            let deadline = ContinuousClock.now + .seconds(30)
            while store.state == .connecting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try require(store.state == .connected, "Isolated handshake failed")
            for command in ["native_read_profile", "native_save_profile", "native_select_route",
                            "native_core_start", "native_core_stop", "native_core_restart", "native_get_runtime", "native_prepare_shutdown"] {
                try require(store.supports(command), "Isolated capability is missing")
            }
            let before = try object(await store.request("native_get_runtime"))
            try require(before["isolated"] == .bool(true) && before["running"] == .bool(false), "Expected stopped isolated core")
            try require(before["dataDir"] == .string(root), "Isolated root differs")
            let profile = try object(await store.request("native_read_profile", params: ["uid": .string("fixture")]))
            guard case .string(let content) = profile["content"], case .string(let revision) = profile["revision"] else {
                throw NativeBackendError.unavailable("Profile content or revision is missing")
            }
            let edited = content.replacingOccurrences(of: "log-level: info", with: "log-level: warning")
            try require(edited != content, "Expected isolated profile fixture")
            let saved = try object(await store.request("native_save_profile", params: [
                "uid": .string("fixture"), "content": .string(edited), "expectedRevision": .string(revision)
            ]))
            try require(saved["saved"] == .bool(true), "Profile save was rejected")
            let reread = try object(await store.request("native_read_profile", params: ["uid": .string("fixture")]))
            try require(reread["content"] == .string(edited), "Profile did not persist")
            _ = try await store.request("native_core_start")
            let running = try object(await store.request("native_get_runtime"))
            try require(running["running"] == .bool(true), "Core did not start")
            let settings = try object(await store.request("native_get_settings", serialWorkspace: true))
            try require(settings["mode"] == .string("rule"), "Fixture settings unavailable")
            let patch = try object(await store.request("native_patch_settings", params: [
                "values": .object(["default_latency_timeout": .integer(6000)])
            ], serialWorkspace: true))
            try require(patch["saved"] == .bool(true), "Fixture settings save failed")
            store.refresh()
            _ = try object(await store.request("native_get_settings", serialWorkspace: true))
            try await Task.sleep(for: .milliseconds(400))
            try require(store.state == .connected, "Settings update broke isolated connection")
            let selected = try object(await store.request("native_select_route", params: ["group": .string("Fixture"), "name": .string("REJECT")]))
            try require(selected["applied"] == .bool(true) && selected["persisted"] == .bool(true), "Route selection did not persist")
            _ = try await store.request("native_core_restart")
            let restarted = try object(await store.request("native_get_runtime"))
            try require(restarted["running"] == .bool(true), "Core did not restart")
            _ = try await store.request("native_core_stop")
            let stopped = try object(await store.request("native_get_runtime"))
            try require(stopped["running"] == .bool(false), "Core did not stop")
            _ = try await store.request("native_core_start")
            let readyToExit = try object(await store.request("native_get_runtime"))
            try require(readyToExit["running"] == .bool(true), "EOF shutdown requires a running core")
            let safelyStopped = await store.shutdownForTermination()
            try require(safelyStopped && store.state == .disconnected, "Managed EOF shutdown was not confirmed")
            print("PASS: Swift store used isolated real writes, lifecycle and prepared shutdown before EOF.")
        } catch {
            let safelyStopped = await store.shutdownForTermination()
            if !safelyStopped {
                FileHandle.standardError.write(Data("Isolated shutdown is unconfirmed; no force termination was attempted.\n".utf8))
            }
            throw error
        }
    }
}
