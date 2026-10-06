import Foundation
import Darwin
import XCTest
#if SWIFT_PACKAGE
@testable import CodexUsageCore
#endif

final class UsageTests: XCTestCase {
    func parse(_ json: String) throws -> [RateLimitBucket] {
        try RateLimitParser.buckets(from: Data(json.utf8))
    }

    func testSwappedWindowsAndFractionalPercent() throws {
        let buckets = try parse("""
        {"rateLimits":{"primary":{"usedPercent":54.5,"windowDurationMins":10080,"resetsAt":1800000000},
        "secondary":{"usedPercent":31,"windowDurationMins":300,"resetsAt":1790000000}}}
        """)
        XCTAssertEqual(buckets[0].fiveHour?.remainingPercent, 69)
        XCTAssertEqual(buckets[0].weekly?.remainingPercent, 45.5)
        XCTAssertEqual(buckets[0].fiveHour?.resetsAt?.timeIntervalSince1970, 1790000000)
    }

    func testMissingWindowAndNullValuesAreNotZero() throws {
        let buckets = try parse("""
        {"rateLimits":{"primary":{"usedPercent":null,"windowDurationMins":10080,"resetsAt":null},"secondary":null}}
        """)
        XCTAssertNil(buckets[0].fiveHour)
        XCTAssertNil(buckets[0].weekly?.remainingPercent)
        XCTAssertNil(buckets[0].weekly?.resetsAt)
        XCTAssertEqual(buckets[0].weekly?.percentText, "—")
    }

    func testDurationIsRequiredAndBooleansAreRejected() throws {
        let buckets = try parse("""
        {"rateLimits":{"primary":{"usedPercent":10},"secondary":{"usedPercent":true,"windowDurationMins":300,"resetsAt":false}}}
        """)
        XCTAssertNil(buckets[0].weekly)
        XCTAssertNil(buckets[0].fiveHour?.remainingPercent)
        XCTAssertNil(buckets[0].fiveHour?.resetsAt)
    }

    func testMultiBucketSelectionDoesNotCombineQuotas() throws {
        let buckets = try parse("""
        {"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},
        "rateLimitsByLimitId":{"other":{"primary":{"usedPercent":80,"windowDurationMins":300}},
        "codex":{"secondary":{"usedPercent":20,"windowDurationMins":10080}}}}
        """)
        let selected = RateLimitParser.select(buckets, preferredID: nil)
        XCTAssertEqual(selected?.id, "codex")
        XCTAssertNil(selected?.fiveHour)
        XCTAssertEqual(selected?.weekly?.remainingPercent, 80)
        XCTAssertEqual(RateLimitParser.select(buckets, preferredID: "other")?.fiveHour?.remainingPercent, 20)
        XCTAssertEqual(RateLimitParser.select(buckets, preferredID: "removed")?.id, "codex")
    }

    func testOutOfRangePercentAndUnknownWindowsAreUnavailable() throws {
        let buckets = try parse("""
        {"rateLimits":{"primary":{"usedPercent":-4,"windowDurationMins":300},"secondary":{"usedPercent":110,"windowDurationMins":10080}}}
        """)
        XCTAssertNil(buckets[0].fiveHour?.remainingPercent)
        XCTAssertNil(buckets[0].weekly?.remainingPercent)
        XCTAssertThrowsError(try parse("{}"))
        XCTAssertThrowsError(try parse("{broken"))
        XCTAssertNil(try parse("{\"rateLimits\":{\"primary\":{\"usedPercent\":3,\"windowDurationMins\":15}}}")[0].fiveHour)
    }

    func testStoreRoundTripAndFailedAttemptKeepsSuccessfulTimestamp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        var snapshot = UsageSnapshot.preview
        let successfulDate = snapshot.updatedAt
        try store.write(snapshot)
        XCTAssertEqual(try store.read(), snapshot)
        snapshot.status = .connectionFailed
        snapshot.attemptedAt = Date().addingTimeInterval(60)
        try store.write(snapshot)
        XCTAssertEqual(try store.read().updatedAt, successfulDate)
        let raw = try String(contentsOf: store.fileURL)
        for forbidden in ["accountId", "summary", "dailyUsage", "accessToken", "refreshToken"] {
            XCTAssertFalse(raw.contains(forbidden))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testCorruptAndFutureSchemaSnapshotRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SnapshotStore(directory: dir)
        try Data("broken".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.read())
        var snapshot = UsageSnapshot.empty
        snapshot.version = 200
        try store.write(snapshot)
        XCTAssertThrowsError(try store.read())
    }

    func testOversizedFileAndSymlinkAreRejectedBeforeReading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SnapshotStore(directory: dir)
        try Data(repeating: 0, count: 20000).write(to: store.fileURL)
        XCTAssertThrowsError(try store.read())
        try FileManager.default.removeItem(at: store.fileURL)
        let harmlessTarget = dir.appendingPathComponent("synthetic-target.json")
        try Data("{}".utf8).write(to: harmlessTarget)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: harmlessTarget)
        XCTAssertThrowsError(try store.read())
    }

    func testStalenessNeverInfersReset() {
        var snapshot = UsageSnapshot.preview
        let now = Date()
        snapshot.updatedAt = now
        snapshot.fiveHour = .init(durationMinutes: 300, remainingPercent: 0, resetsAt: now.addingTimeInterval(-10))
        XCTAssertFalse(snapshot.isStale(at: now.addingTimeInterval(179)))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(180)))
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 0)
        XCTAssertTrue(UsageSnapshot.empty.isStale(at: now))
    }

    func testTokenSummaryNullsAndIgnoredDailyHistory() throws {
        let result = try JSONDecoder().decode(TokenUsageResponse.self, from: Data("""
        {"summary":{"lifetimeTokens":123,"peakDailyTokens":null},"dailyUsageBuckets":[{"startDate":"2026-01-01","tokens":4}]}
        """.utf8))
        XCTAssertEqual(result.summary.lifetimeTokens, 123)
        XCTAssertNil(result.summary.peakDailyTokens)
    }

    func testMenuFitsBelowBarOnMultipleDisplays() {
        let screens = [CGRect(x: 0, y: 40, width: 1440, height: 840),
                       CGRect(x: -1280, y: 0, width: 1280, height: 1000)]
        for screen in screens {
            for x in [screen.minX, screen.midX, screen.maxX - 20] {
                let anchor = CGRect(x: x, y: screen.maxY, width: 70, height: 24)
                let panel = MenuPlacement.frame(anchor: anchor, visibleFrame: screen,
                                                size: CGSize(width: 280, height: 260))
                XCTAssertLessThan(panel.maxY, anchor.minY)
                XCTAssertLessThanOrEqual(panel.maxY, screen.maxY)
                XCTAssertGreaterThanOrEqual(panel.minX, screen.minX)
                XCTAssertLessThanOrEqual(panel.maxX, screen.maxX)
                XCTAssertGreaterThanOrEqual(panel.minY, screen.minY)
            }
        }
    }

    func testFramerPartialReadsMultipleLinesAndSizeLimit() throws {
        var framer = JSONLineFramer()
        XCTAssertTrue(try framer.append(Data("{\"id\":".utf8)).isEmpty)
        let lines = try framer.append(Data("1}\n{\"id\":2}\n\n".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"id\":1}", "{\"id\":2}"])
        XCTAssertThrowsError(try framer.append(Data(repeating: 65, count: JSONLineFramer.maximumBytes + 1)))
    }
    func testFIFOIsRejectedWithoutBlocking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SnapshotStore(directory: dir)
        XCTAssertEqual(mkfifo(store.fileURL.path, 0o600), 0)
        let started = Date()
        XCTAssertThrowsError(try store.read())
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testAtomicWriteDoesNotFollowDestinationSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: target)
        let store = SnapshotStore(directory: dir)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        try store.write(.preview)
        XCTAssertEqual(try String(contentsOf: target), "preserve")
        XCTAssertEqual(try store.read().status, .ready)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".snapshot-") })
    }

    func testSymlinkDirectoryCannotRedirectWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertThrowsError(try SnapshotStore(directory: link).write(.preview))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage-snapshot.json").path))
    }

    func testInvalidSnapshotDatesAndWindowsAreRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        var snapshot = UsageSnapshot.preview
        snapshot.updatedAt = Date(timeIntervalSince1970: 1e100)
        try store.write(snapshot)
        XCTAssertThrowsError(try store.read())
        snapshot = .preview
        snapshot.fiveHour = .init(durationMinutes: 1, remainingPercent: 5, resetsAt: nil)
        try store.write(snapshot)
        XCTAssertThrowsError(try store.read())
    }

    func testClockMovedBackAndPercentageFormattingAreSafe() {
        var snapshot = UsageSnapshot.preview
        snapshot.updatedAt = Date().addingTimeInterval(120)
        XCTAssertTrue(snapshot.isStale(at: Date()))
        for value in [Double.nan, Double.infinity, -1, 101] {
            XCTAssertEqual(UsageWindow(durationMinutes: 300, remainingPercent: value, resetsAt: nil).percentText, "—")
        }
    }

    func testUntrustedBucketIdentifiersAndExtremeNumbers() throws {
        XCTAssertThrowsError(try parse("{\"rateLimits\":{\"limitId\":\"bad\\nname\"}}"))
        let many = Dictionary(uniqueKeysWithValues: (0..<33).map { ("bucket-\($0)", [String: String]()) })
        let data = try JSONSerialization.data(withJSONObject: ["rateLimitsByLimitId": many])
        XCTAssertThrowsError(try RateLimitParser.buckets(from: data))
        for value in ["1e100", "-1e100", "true", "null", "2.5"] {
            let windows = try parse("{\"rateLimits\":{\"primary\":{\"windowDurationMins\":\(value),\"usedPercent\":1e100,\"resetsAt\":1e100}}}")
            XCTAssertNil(windows.first?.fiveHour)
        }
    }

}
