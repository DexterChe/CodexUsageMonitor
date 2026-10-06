import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot = UsageSnapshot.empty
    @Published var buckets: [RateLimitBucket] = []
    @Published var usage: TokenUsageSummary?
    @Published var isRefreshing = false
    @Published var cliPath: String
    @Published var selectedBucketID: String
    @Published var storageAvailable = false
    @Published var loginEnabled = false
    @Published var loginError = false
    @Published var cliSelectionError = false
    private let rpc = CodexRPCClient()
    private var store: SnapshotStore?
    private var polling: Task<Void, Never>?
    private var failures = 0
    private var lastAttempt: Date?
    private var lastPublished: UsageSnapshot?
    private var shuttingDown = false
    private var sleeping = false
    private var usageSupported = true
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults

    init(preview: UsageSnapshot? = nil, defaults: UserDefaults = .standard,
         store: SnapshotStore? = try? SnapshotStore.local()) {
        self.defaults = defaults
        if let preview {
            cliPath = ""
            selectedBucketID = "codex"
            snapshot = preview
            storageAvailable = true
            return
        }
        cliPath = MonitorPreferences.cliPath(from: defaults) ?? Self.findCLI() ?? ""
        selectedBucketID = MonitorPreferences.bucketID(from: defaults)
        self.store = store
        storageAvailable = store != nil
        if let cached = try? store?.read() { snapshot = cached }
        loginEnabled = SMAppService.mainApp.status == .enabled
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.sleeping = false; self?.lastAttempt = nil; await self?.refresh() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.sleeping = true; await self?.rpc.stop() } })
    }

    static func findCLI() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"
        ]
        return candidates.first { Self.validExecutable($0) }
    }

    static func validExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path),
              let values = try? URL(fileURLWithPath: path).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o022 == 0
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let delay: Int = self.failures <= 1 ? 60 : self.failures == 2 ? 120 : 300
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func refresh() async {
        guard !isRefreshing, !shuttingDown, !sleeping else { return }
        let now = Date()
        if let lastAttempt, (0..<10).contains(now.timeIntervalSince(lastAttempt)) { return }
        lastAttempt = now
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot.attemptedAt = Date()
        guard Self.validExecutable(cliPath) else {
            snapshot.status = .cliMissing
            failures = min(4, failures + 1)
            publish()
            return
        }
        do {
            let reconnected = try await rpc.connect(executable: URL(fileURLWithPath: cliPath))
            if reconnected { usageSupported = true }
            let response = try await rpc.readRateLimits()
            guard !shuttingDown, !sleeping else { return }
            let parsed = try RateLimitParser.buckets(from: response)
            guard let selected = RateLimitParser.select(parsed, preferredID: selectedBucketID) else {
                throw ModelError.invalidResponse
            }
            buckets = parsed
            selectedBucketID = selected.id
            MonitorPreferences.saveBucketID(selected.id, to: defaults)
            snapshot.fiveHour = selected.fiveHour
            snapshot.weekly = selected.weekly
            snapshot.bucketID = selected.id
            snapshot.updatedAt = Date()
            snapshot.status = .ready
            failures = 0
            publish()
            if usageSupported {
                do {
                    let response = try await rpc.readUsage()
                    usage = try JSONDecoder().decode(TokenUsageResponse.self, from: response).summary
                } catch {
                    usage = nil
                    if case RPCError.server(_, .unsupported) = error { usageSupported = false }
                }
            }
        } catch {
            guard !shuttingDown, !sleeping else { return }
            usage = nil
            snapshot.status = Self.status(for: error)
            failures = min(4, failures + 1)
            await rpc.stop()
            usageSupported = true
            publish()
        }
    }

    static func status(for error: Error) -> MonitorStatus {
        if case RPCError.server(_, .authentication) = error { return .loginRequired }
        return .connectionFailed
    }

    private func publish() {
        // Attempt time is diagnostic only; repeated identical errors need no disk/WidgetKit churn.
        if var previous = lastPublished {
            previous.attemptedAt = snapshot.attemptedAt
            if previous == snapshot { return }
        }
        do {
            guard let store else { throw StoreError.unavailable }
            try store.write(snapshot)
            storageAvailable = true
            lastPublished = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: "CodexUsageWidget")
        } catch { storageAvailable = false }
    }

    func selectBucket(_ id: String) {
        guard let selected = buckets.first(where: { $0.id == id }) else { return }
        selectedBucketID = id
        MonitorPreferences.saveBucketID(id, to: defaults)
        snapshot.fiveHour = selected.fiveHour
        snapshot.weekly = selected.weekly
        snapshot.bucketID = id
        publish()
    }

    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("chooseCLIMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Self.validExecutable(url.path) else {
            cliSelectionError = true
            return
        }
        cliSelectionError = false
        Task {
            // Wait until a current cycle finishes before replacing its connection.
            while isRefreshing && !shuttingDown {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await rpc.stop()
            guard !shuttingDown else { return }
            lastAttempt = nil
            cliPath = url.path
            MonitorPreferences.saveCLIPath(cliPath, to: defaults)
            usageSupported = true
            usage = nil
            await refresh()
        }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = false
        } catch { loginError = true }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func shutdown() async {
        shuttingDown = true
        polling?.cancel()
        polling = nil
        await rpc.stop()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
