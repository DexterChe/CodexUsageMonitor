import Foundation
import CoreGraphics

enum MenuPlacement {
    static func frame(anchor: CGRect, visibleFrame: CGRect, size: CGSize) -> CGRect {
        let margin: CGFloat = 6
        let width = min(size.width, max(1, visibleFrame.width - 2 * margin))
        let top = min(anchor.minY - margin, visibleFrame.maxY - margin)
        let availableHeight = max(1, top - visibleFrame.minY - margin)
        let height = min(size.height, availableHeight)
        let left = min(max(anchor.midX - width / 2, visibleFrame.minX + margin),
                       visibleFrame.maxX - width - margin)
        return CGRect(x: left, y: top - height, width: width, height: height)
    }
}

enum MonitorStatus: String, Codable, Sendable {
    case starting, ready, cliMissing, loginRequired, connectionFailed, storageUnavailable
}

struct UsageWindow: Codable, Equatable, Sendable {
    let durationMinutes: Int
    let remainingPercent: Double?
    let resetsAt: Date?

    var percentText: String {
        guard let remainingPercent, remainingPercent.isFinite, (0...100).contains(remainingPercent) else { return "—" }
        return "\(Int(remainingPercent.rounded()))%"
    }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var version = schemaVersion
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var updatedAt: Date?
    var attemptedAt: Date?
    var status: MonitorStatus = .starting
    var bucketID: String?

    func isStale(at date: Date) -> Bool {
        guard let updatedAt else { return true }
        let age = date.timeIntervalSince(updatedAt)
        return age >= 180 || age < -60
    }

    static var empty: Self { .init() }

    // Synthetic gallery data; never copied from a real account.
    static var preview: Self {
        .init(fiveHour: .init(durationMinutes: 300, remainingPercent: 68,
                             resetsAt: Date().addingTimeInterval(8200)),
              weekly: .init(durationMinutes: 10080, remainingPercent: 46,
                           resetsAt: Date().addingTimeInterval(172800)),
              updatedAt: Date(), attemptedAt: Date(), status: .ready, bucketID: "codex")
    }
}

struct RateLimitBucket: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
}

enum ModelError: Error { case invalidResponse }

enum RateLimitParser {
    static func buckets(from data: Data) throws -> [RateLimitBucket] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError.invalidResponse
        }
        if let values = root["rateLimitsByLimitId"] as? [String: Any], !values.isEmpty {
            guard values.count <= 32 else { throw ModelError.invalidResponse }
            let buckets = values.keys.sorted().compactMap { key -> RateLimitBucket? in
                guard validIdentifier(key), let bucket = values[key] as? [String: Any] else { return nil }
                return parse(bucket, id: key)
            }
            guard !buckets.isEmpty else { throw ModelError.invalidResponse }
            return buckets
        }
        guard let legacy = root["rateLimits"] as? [String: Any] else { throw ModelError.invalidResponse }
        let id = legacy["limitId"] as? String ?? "codex"
        guard validIdentifier(id) else { throw ModelError.invalidResponse }
        return [parse(legacy, id: id)]
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func select(_ buckets: [RateLimitBucket], preferredID: String?) -> RateLimitBucket? {
        if let preferredID, let chosen = buckets.first(where: { $0.id == preferredID }) { return chosen }
        return buckets.first(where: { $0.id == "codex" }) ?? buckets.first
    }

    private static func parse(_ bucket: [String: Any], id: String) -> RateLimitBucket {
        let windows = [bucket["primary"], bucket["secondary"]].compactMap(window)
        return .init(id: id, name: id,
                     fiveHour: windows.first(where: { $0.durationMinutes == 300 }),
                     weekly: windows.first(where: { $0.durationMinutes == 10080 }))
    }

    private static func window(_ raw: Any?) -> UsageWindow? {
        guard let value = raw as? [String: Any],
              let duration = value["windowDurationMins"] as? NSNumber,
              CFGetTypeID(duration) != CFBooleanGetTypeID(), duration.doubleValue > 0,
              duration.doubleValue < Double(Int.max),
              duration.doubleValue.rounded() == duration.doubleValue else { return nil }
        let used = value["usedPercent"] as? NSNumber
        let remaining: Double?
        if let used, CFGetTypeID(used) != CFBooleanGetTypeID(),
           used.doubleValue.isFinite, (0...100).contains(used.doubleValue) {
            remaining = 100 - used.doubleValue
        } else { remaining = nil }
        let reset = value["resetsAt"] as? NSNumber
        let date: Date?
        if let reset, CFGetTypeID(reset) != CFBooleanGetTypeID(), reset.doubleValue.isFinite,
           reset.doubleValue > 0, reset.doubleValue < 253402300800 {
            date = Date(timeIntervalSince1970: reset.doubleValue)
        } else { date = nil }
        return .init(durationMinutes: duration.intValue, remainingPercent: remaining, resetsAt: date)
    }
}

struct TokenUsageSummary: Decodable, Equatable, Sendable {
    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    var currentStreakDays: Int64?
}

struct TokenUsageResponse: Decodable, Sendable {
    let summary: TokenUsageSummary
}

import CoreFoundation

enum MonitorPreferences {
    static func cliPath(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: "CLIPath")
    }

    static func bucketID(from defaults: UserDefaults) -> String {
        guard let id = defaults.string(forKey: "BucketID"),
              RateLimitParser.validIdentifier(id) else { return "codex" }
        return id
    }

    static func saveCLIPath(_ path: String, to defaults: UserDefaults) {
        defaults.set(path, forKey: "CLIPath")
    }

    static func saveBucketID(_ id: String, to defaults: UserDefaults) {
        guard RateLimitParser.validIdentifier(id) else { return }
        defaults.set(id, forKey: "BucketID")
    }
}
