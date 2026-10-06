import AppKit
import XCTest

@MainActor
final class AppTests: XCTestCase {
    private func isolatedDefaults() -> (String, UserDefaults) {
        let name = "CodexUsageMonitor.AppTests." + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func mockCLI(in directory: URL, mode: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mock_server", withExtension: "py", subdirectory: "Fixtures"))
        let script = try String(contentsOf: source)
            .replacingOccurrences(of: "mode = sys.argv[1] if sys.argv[1] != \"app-server\" else \"normal\"",
                                  with: "mode = \"\(mode)\"")
        let executable = directory.appendingPathComponent("codex-test")
        try ("#!/usr/bin/python3\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testPreferencesAreIsolatedAndInvalidBucketFallsBack() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        MonitorPreferences.saveCLIPath("/synthetic/codex", to: defaults)
        MonitorPreferences.saveBucketID("codex", to: defaults)
        XCTAssertEqual(MonitorPreferences.cliPath(from: defaults), "/synthetic/codex")
        XCTAssertEqual(MonitorPreferences.bucketID(from: defaults), "codex")
        defaults.set("\ninvalid", forKey: "BucketID")
        XCTAssertEqual(MonitorPreferences.bucketID(from: defaults), "codex")
        MonitorPreferences.saveBucketID("\ninvalid", to: defaults)
        XCTAssertEqual(defaults.string(forKey: "BucketID"), "\ninvalid")
    }

    func testModelRefreshCoalescesAndDoesNotRefreshAfterShutdown() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let executable = try mockCLI(in: dir, mode: "normal")
        MonitorPreferences.saveCLIPath(executable.path, to: defaults)
        let store = SnapshotStore(directory: dir.appendingPathComponent("snapshot"))
        let model = MonitorModel(defaults: defaults, store: store)
        await model.refresh()
        XCTAssertEqual(model.snapshot.status, .ready)
        XCTAssertEqual(model.snapshot.fiveHour?.remainingPercent, 68)
        XCTAssertEqual(model.snapshot.weekly?.remainingPercent, 46)
        XCTAssertEqual(model.usage?.lifetimeTokens, 123)
        XCTAssertEqual(try store.read().updatedAt, model.snapshot.updatedAt)
        let timestamp = model.snapshot.attemptedAt
        await model.refresh()
        XCTAssertEqual(model.snapshot.attemptedAt, timestamp)
        await model.shutdown()
        await model.refresh()
        XCTAssertEqual(model.snapshot.attemptedAt, timestamp)
    }

    func testModelMissingCLIAndAuthenticationError() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        MonitorPreferences.saveCLIPath(dir.appendingPathComponent("missing").path, to: defaults)
        let model = MonitorModel(defaults: defaults, store: SnapshotStore(directory: dir.appendingPathComponent("snapshot")))
        await model.refresh()
        XCTAssertEqual(model.snapshot.status, .cliMissing)
        await model.shutdown()
        let auth = try mockCLI(in: dir, mode: "auth")
        MonitorPreferences.saveCLIPath(auth.path, to: defaults)
        let next = MonitorModel(defaults: defaults, store: SnapshotStore(directory: dir.appendingPathComponent("snapshot2")))
        await next.refresh()
        XCTAssertEqual(next.snapshot.status, .loginRequired)
        await next.shutdown()
    }

    func testCLIPathValidationRejectsWritableAndNonRegularTargets() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = try mockCLI(in: dir, mode: "normal")
        XCTAssertTrue(MonitorModel.validExecutable(executable.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: executable.path)
        XCTAssertFalse(MonitorModel.validExecutable(executable.path))
        XCTAssertFalse(MonitorModel.validExecutable(dir.path))
    }
}
