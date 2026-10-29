import Foundation

@MainActor
private final class ActivityProbe {
    var calls = 0
    var continuation: CheckedContinuation<BackendJSON, Never>?
    func read() async -> BackendJSON {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
}

@main
struct ActivityCheck {
    static func fixture(_ host: String = "example.test") -> BackendJSON {
        .object([
            "schemaVersion": .integer(1), "source": .string("sidecar"),
            "connections": .object([
                "state": .string("ready"), "total": .integer(1), "truncated": .bool(false),
                "uploadTotal": .integer(1024), "downloadTotal": .integer(2048), "memory": .integer(4096),
                "message": .null,
                "items": .array([.object([
                    "id": .string("a"), "closeable": .bool(true), "host": .string(host), "destination": .string("192.0.2.1:443"),
                    "network": .string("tcp"), "type": .string("HTTPS"), "process": .string("Browser"),
                    "rule": .string("MATCH"), "chains": .array([.string("DIRECT")]),
                    "upload": .integer(1024), "download": .integer(2048), "start": .string("2026-10-27T00:00:00Z")
                ])])
            ]),
            "rules": .object([
                "state": .string("ready"), "total": .integer(1), "truncated": .bool(false), "message": .null,
                "items": .array([.object(["index": .integer(0), "type": .string("MATCH"), "payload": .string(""), "proxy": .string("DIRECT"), "size": .integer(0)])])
            ]),
            "providers": .object([
                "state": .string("unavailable"), "total": .integer(0), "truncated": .bool(false), "message": .string("Unavailable"), "items": .array([])
            ])
        ])
    }

    @MainActor static func main() async throws {
        let projected = try NativeActivity.decode(fixture())
        precondition(projected.connections.items.count == 1)
        precondition(projected.connections.uploadTotal == 1024 && projected.providers.state == "unavailable")
        precondition(projected.connections.items[0].matches("BROWSER"))
        precondition(projected.connections.items[0].matches("192.0.2"))
        precondition(!projected.connections.items[0].matches("missing"))
        var rates = NativeActivityRates()
        rates.sample(projected.connections, at: 10)
        precondition(rates.connections["a"]?.upload == nil)
        rates.sample(projected.connections, at: 12)
        precondition(rates.connections["a"]?.status == "空闲" && rates.total.upload == 0)
        guard case .object(var traffic) = fixture(), case .object(var counters) = traffic["connections"],
              case .array(var trafficRows) = counters["items"], case .object(var trafficRow) = trafficRows[0] else { fatalError() }
        trafficRow["upload"] = .integer(3072); trafficRow["download"] = .integer(6144)
        trafficRows[0] = .object(trafficRow); counters["items"] = .array(trafficRows)
        counters["uploadTotal"] = .integer(3072); counters["downloadTotal"] = .integer(6144)
        traffic["connections"] = .object(counters)
        rates.sample(try NativeActivity.decode(.object(traffic)).connections, at: 14)
        precondition(rates.connections["a"]?.upload == 1024 && rates.connections["a"]?.download == 2048)
        precondition(rates.connections["a"]?.status == "传输中" && rates.total.download == 2048)
        rates.sample(projected.connections, at: 16)
        precondition(rates.connections["a"]?.upload == nil, "Counter resets must not underflow")
        rates.reset()
        precondition(rates.connections.isEmpty && rates.total.upload == nil)
        precondition(NativeConnectionRate.label(nil) == "—" && NativeConnectionRate.label(1024).hasSuffix("/s"))
        let portOnly = NativeActivityConnection(id: "port", host: nil, destination: ":443", network: "tcp",
            type: nil, process: nil, rule: nil, chains: [], upload: 0, download: 0, start: nil)
        precondition(portOnly.title == "未知目标" && portOnly.destinationLabel == "端口 443")
        precondition(projected.rules.items[0].matches("direct"))
        precondition(NativeActivityFormat.bytes(nil) == "—")
        precondition(!NativeActivityFormat.bytes(UInt64.max).isEmpty)
        precondition(NativeActivityFormat.issue("response_too_large").contains("上限"))
        precondition(NativeActivityFormat.issue("controller_timeout").contains("超时"))
        let pageQuery = NativeActivityQuery(section: "rules", query: "late-match", offset: 256, limit: 256)
        precondition(pageQuery.isValid && pageQuery.params["offset"] == .unsigned(256))
        precondition(!NativeActivityQuery(section: "rules", query: String(repeating: "中", count: 86), limit: 256).isValid)
        precondition(!NativeActivityQuery(section: "rules", limit: 257).isValid)
        precondition(!NativeActivityQuery(section: "unknown", limit: 1).isValid)
        let page = try NativeActivity.decode(pageFixture(offset: 256, matched: 700, nextOffset: 257))
        precondition(page.rules.offset == 256 && page.rules.matched == 700 && page.rules.nextOffset == 257)
        precondition(page.rules.items[0].index == 700)
        try page.validate(query: pageQuery)
        do { try projected.validate(query: pageQuery); preconditionFailure("Legacy first page accepted for paged request") } catch {}
        do {
            _ = try NativeActivity.decode(pageFixture(offset: 256, matched: 700, nextOffset: 258))
            preconditionFailure("Non-contiguous next page accepted")
        } catch {}
        do {
            _ = try NativeActivity.decode(pageFixture(offset: 256, matched: 1001, nextOffset: nil))
            preconditionFailure("Matched count exceeds total")
        } catch {}
        if case .object(var root) = pageFixture(offset: 256, matched: 700, nextOffset: nil),
           case .object(var section) = root["rules"] {
            section.removeValue(forKey: "matched")
            root["rules"] = .object(section)
            do { _ = try NativeActivity.decode(.object(root)); preconditionFailure("Incomplete page accepted") } catch {}
        }
        if case .object(var root) = pageFixture(offset: 800, matched: 700, nextOffset: nil),
           case .object(var rules) = root["rules"] {
            rules["items"] = .array([])
            root["rules"] = .object(rules)
            let empty = try NativeActivity.decode(.object(root))
            try empty.validate(query: NativeActivityQuery(section: "rules", offset: 800, limit: 256))
            precondition(empty.rules.items.isEmpty && empty.rules.matched == 700)
        }

        guard case .object(var malformed) = fixture(), case .object(var connections) = malformed["connections"] else { fatalError() }
        malformed["schemaVersion"] = .integer(2)
        do { _ = try NativeActivity.decode(.object(malformed)); preconditionFailure("Unsupported schema accepted") } catch {}
        malformed["schemaVersion"] = .integer(1)
        connections["items"] = .array(Array(repeating: projectedConnection(), count: 2))
        connections["total"] = .integer(2)
        malformed["connections"] = .object(connections)
        do { _ = try NativeActivity.decode(.object(malformed)); preconditionFailure("Duplicate rows accepted") } catch {}
        connections["items"] = .array(Array(repeating: projectedConnection(), count: 129))
        connections["total"] = .integer(129)
        malformed["connections"] = .object(connections)
        do { _ = try NativeActivity.decode(.object(malformed)); preconditionFailure("Oversized section accepted") } catch {}
        if case .object(var longRow) = projectedConnection() {
            longRow["host"] = .string(String(repeating: "a", count: 513))
            connections["items"] = .array([.object(longRow)])
            connections["total"] = .integer(1)
            malformed["connections"] = .object(connections)
            do { _ = try NativeActivity.decode(.object(malformed)); preconditionFailure("Oversized text accepted") } catch {}
        }

        let model = NativeActivityModel()
        await model.refresh { fixture() }
        precondition(model.snapshot == projected && model.updatedAt != nil && !model.isLoading)
        var closedIDs: [String] = []
        let closed = await model.close(id: "a") {
            closedIDs.append("a")
            return .object(["closed": .bool(true), "id": .string("a")])
        }
        precondition(closed && closedIDs == ["a"] && !model.closeError && model.closingID == nil)
        let invalid = await model.close(id: "other") { closedIDs.append("other"); return .null }
        precondition(!invalid && closedIDs == ["a"])
        let failedClose = await model.close(id: "a") { throw BackendWireError.invalid("injected close error") }
        precondition(!failedClose && model.closeError && model.closeMessage != nil && model.snapshot == projected)
        let wrongClose = await model.close(id: "a") { .object(["closed": .bool(true), "id": .string("other")]) }
        precondition(!wrongClose && model.closeError)
        await model.refresh { throw BackendWireError.invalid("fixture error") }
        precondition(model.snapshot == projected && model.errorMessage != nil)

        let probe = ActivityProbe()
        let pending = Task { await model.refresh { await probe.read() } }
        while probe.continuation == nil { await Task.yield() }
        precondition(model.isLoading)
        await model.refresh { probe.calls += 1; return fixture("overlap") }
        precondition(probe.calls == 1)
        model.stop()
        probe.continuation?.resume(returning: fixture("stale"))
        await pending.value
        precondition(model.snapshot == projected && !model.isLoading)
        await model.refresh { fixture("fresh") }
        precondition(model.snapshot?.connections.items[0].host == "fresh" && model.errorMessage == nil)

        let cancelled = ActivityProbe()
        let cancelledTask = Task { await model.refresh { await cancelled.read() } }
        while cancelled.continuation == nil { await Task.yield() }
        cancelledTask.cancel()
        cancelled.continuation?.resume(returning: fixture("cancelled"))
        await cancelledTask.value
        precondition(model.snapshot?.connections.items[0].host == "fresh" && !model.isLoading)

        let firstQuery = NativeActivityQuery(section: "rules", query: "first", limit: 256)
        let secondQuery = NativeActivityQuery(section: "rules", query: "second", offset: 256, limit: 256)
        let firstRead = ActivityProbe()
        let switching = Task { await model.refresh(query: firstQuery) { await firstRead.read() } }
        while firstRead.continuation == nil { await Task.yield() }
        model.select(secondQuery)
        var secondCalls = 0
        let secondRead = ActivityProbe()
        let nextPage = Task { await model.refresh(query: secondQuery) { secondCalls += 1; return await secondRead.read() } }
        for _ in 0..<10 { await Task.yield() }
        precondition(secondCalls == 0)
        firstRead.continuation?.resume(returning: fixture("late-first-page"))
        await switching.value
        while secondRead.continuation == nil { await Task.yield() }
        precondition(model.snapshot?.connections.items[0].host == "fresh")
        secondRead.continuation?.resume(returning: queryFixture("second-page", query: secondQuery))
        await nextPage.value
        precondition(secondCalls == 1 && model.snapshotQuery == secondQuery)
        precondition(model.snapshot?.connections.items[0].host == "second-page")
        var invalidCalls = 0
        await model.refresh(query: NativeActivityQuery(section: "rules", query: String(repeating: "a", count: 257), limit: 256)) {
            invalidCalls += 1; return fixture("invalid-query")
        }
        precondition(invalidCalls == 0 && model.snapshot?.connections.items[0].host == "second-page" && model.errorMessage != nil)

        let serialProbe = ActivityProbe()
        let serial = Task { await model.refresh(query: firstQuery) { await serialProbe.read() } }
        while serialProbe.continuation == nil { await Task.yield() }
        let cancelledPage = Task { await model.refresh(query: secondQuery) { secondCalls += 1; return fixture("cancelled-page") } }
        await Task.yield()
        cancelledPage.cancel()
        await cancelledPage.value
        serialProbe.continuation?.resume(returning: fixture("outdated-page"))
        await serial.value
        precondition(secondCalls == 1 && model.snapshot?.connections.items[0].host == "second-page" && !model.isLoading)
        print("Activity checks passed: typed projection, paging, stale-query rejection, measured transfer rates and resets, exact single-connection close, error preservation and cancellation")
    }

    private static func projectedConnection() -> BackendJSON {
        guard case .object(let root) = fixture(), case .object(let section) = root["connections"],
              case .array(let items) = section["items"] else { fatalError() }
        return items[0]
    }

    private static func pageFixture(offset: UInt64, matched: UInt64, nextOffset: UInt64?) -> BackendJSON {
        guard case .object(var root) = fixture(), case .object(var rules) = root["rules"] else { fatalError() }
        rules["total"] = .unsigned(1000)
        rules["matched"] = .unsigned(matched)
        rules["offset"] = .unsigned(offset)
        rules["nextOffset"] = nextOffset.map(BackendJSON.unsigned) ?? .null
        rules["items"] = .array([.object(["index": .unsigned(700), "type": .string("MATCH"),
            "payload": .string("late-match"), "proxy": .string("DIRECT"), "size": .integer(0)])])
        root["rules"] = .object(rules)
        return .object(root)
    }

    private static func queryFixture(_ host: String, query: NativeActivityQuery) -> BackendJSON {
        guard case .object(var root) = pageFixture(offset: query.offset, matched: 700, nextOffset: nil),
              case .object(let fresh) = fixture(host) else { fatalError() }
        root["connections"] = fresh["connections"]
        return .object(root)
    }
}
