import Foundation

struct NativeRouteMeasurement: Equatable {
    enum Origin: Equatable { case session, snapshot, none }

    let origin: Origin
    let date: Date?
    let rawTime: String?

    init(sessionDate: Date?, snapshotTime: String?, hasSessionResult: Bool = false) {
        if hasSessionResult || sessionDate != nil {
            origin = .session
            date = sessionDate
            rawTime = nil
        } else if let snapshotTime {
            origin = .snapshot
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: snapshotTime) ?? ISO8601DateFormatter().date(from: snapshotTime)
            rawTime = snapshotTime
        } else {
            origin = .none
            date = nil
            rawTime = nil
        }
    }

    var originLabel: String {
        switch origin {
        case .session: "本次测速"
        case .snapshot: "历史快照"
        case .none: "未测速"
        }
    }

    func relativeAge(at now: Date) -> String {
        guard let date else { return origin == .none ? "未测速" : "时间未提供" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    var exactTime: String {
        guard let date else { return rawTime.flatMap { $0.isEmpty ? nil : $0 } ?? "时间未提供" }
        return date.formatted(.dateTime.year().month().day().hour().minute().second().timeZone())
    }
}

struct NativeRouteComparisonSelection: Equatable {
    static let limit = 3
    private(set) var ids: [String] = []
    var isFull: Bool { ids.count >= Self.limit }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func add(_ id: String) {
        guard !contains(id), !isFull else { return }
        ids.append(id)
    }

    mutating func remove(_ id: String) { ids.removeAll { $0 == id } }
    mutating func clear() { ids.removeAll() }
    mutating func retain(_ availableIDs: Set<String>) { ids.removeAll { !availableIDs.contains($0) } }
}
