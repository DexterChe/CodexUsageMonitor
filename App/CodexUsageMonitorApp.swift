import AppKit
import Combine
import SwiftUI

// AppKit owns the status item; SwiftUI owns the panel and settings content.
// Avoid rendering a dynamic SwiftUI view into NSStatusBarButton on macOS 27.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MonitorModel()
    private var statusItem: NSStatusItem?
    private var menuPanel: NSPanel?
    private var observation: AnyCancellable?
    private var detailWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Codex")
            button.image?.isTemplate = true
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            button.imagePosition = .imageLeading
            button.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel)
        }
        observation = model.$snapshot.sink { [weak self] snapshot in self?.updateStatus(snapshot) }
        model.start()
    }

    private func updateStatus(_ snapshot: UsageSnapshot) {
        let title = "\(snapshot.fiveHour?.percentText ?? "—")·\(snapshot.weekly?.percentText ?? "—")"
        if statusItem?.button?.title != title { statusItem?.button?.title = title }
        let description = "\(L10n.text("fiveHour")): \(snapshot.fiveHour?.percentText ?? "—") · \(L10n.text("weekly")): \(snapshot.weekly?.percentText ?? "—")"
        statusItem?.button?.toolTip = description + (snapshot.isStale(at: .now) ? " · " + L10n.text("stale") : "")
        statusItem?.button?.setAccessibilityLabel(description)
    }

    @objc private func togglePanel() {
        if menuPanel?.isVisible == true { menuPanel?.orderOut(nil); return }
        guard let button = statusItem?.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        if menuPanel == nil {
            let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.contentViewController = NSHostingController(rootView:
                MonitorView(model: model, onSettings: { [weak self] in self?.showSettings() }))
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = true
            panel.isMovable = false
            panel.collectionBehavior = [.transient, .moveToActiveSpace]
            menuPanel = panel
        }
        guard let panel = menuPanel else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 280, height: 260)
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = MenuPlacement.frame(anchor: anchor, visibleFrame: screen.visibleFrame,
                                        size: NSSize(width: 280, height: max(200, fitting.height)))
        panel.setFrame(frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, content: NSViewController, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = content
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func showSettings() {
        menuPanel?.orderOut(nil)
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: L10n.text("settings"),
                content: NSHostingController(rootView: SettingsView(model: model)),
                size: NSSize(width: 490, height: 440))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "codexusagemonitor" && $0.host == "usage" }) else { return }
        if detailWindow == nil {
            detailWindow = makeWindow(title: "CodexUsageMonitor",
                content: NSHostingController(rootView: MonitorView(model: model,
                    onSettings: { [weak self] in self?.showSettings() })),
                size: NSSize(width: 350, height: 430))
        }
        detailWindow?.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        Task { await model.refresh() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        observation?.cancel()
        menuPanel?.orderOut(nil)
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); orderOut(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { orderOut(nil) } else { super.keyDown(with: event) }
    }
}

#if !VISUAL_AUDIT
@main
#endif
@MainActor
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            Task {
                let model = MonitorModel()
                await model.refresh()
                print("Quotas: \(model.snapshot.status == .ready ? "OK" : "FAILED")")
                print("Widget store: \(model.storageAvailable ? "OK" : "UNAVAILABLE")")
                print("Windows: fiveHour=\(model.snapshot.fiveHour != nil), weekly=\(model.snapshot.weekly != nil)")
                if let store = try? SnapshotStore.local(), let cached = try? store.read() {
                    print("Widget snapshot round trip: \(cached.updatedAt == model.snapshot.updatedAt ? "OK" : "FAILED")")
                }
                let passed = model.snapshot.status == .ready && model.storageAvailable
                await model.shutdown()
                exit(passed ? 0 : 1)
            }
            RunLoop.main.run()
        } else {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    var onSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundStyle(Color.accentColor)
                Text("Codex").font(.headline)
                Spacer()
                Text(L10n.text("remaining")).font(.caption).foregroundStyle(.secondary)
            }
            if model.buckets.count > 1 {
                Picker(L10n.text("bucket"), selection: Binding(
                    get: { model.selectedBucketID }, set: { model.selectBucket($0) }
                )) {
                    ForEach(model.buckets) { Text($0.name).tag($0.id) }
                }
            } else if let id = model.snapshot.bucketID, id != "codex" {
                Text(id).font(.caption).foregroundStyle(.secondary)
            }
            QuotaRow(titleKey: "fiveHour", window: model.snapshot.fiveHour, compact: true)
            QuotaRow(titleKey: "weekly", window: model.snapshot.weekly, compact: true)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                UpdateFooter(snapshot: model.snapshot, now: context.date, compact: true)
            }
            if !model.storageAvailable {
                Text(L10n.text("storageUnavailable")).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button { Task { await model.refresh() } } label: {
                    Label(L10n.text(model.isRefreshing ? "refreshing" : "refresh"), systemImage: "arrow.clockwise")
                }.disabled(model.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .help(L10n.text("settings"))
                    .accessibilityLabel(L10n.text("settings"))
                    .keyboardShortcut(",", modifiers: .command)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help(L10n.text("quit"))
                    .accessibilityLabel(L10n.text("quit"))
                    .keyboardShortcut("q", modifiers: .command)
            }.buttonStyle(.borderless)
        }.padding(12).frame(width: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        Form {
            Section(L10n.text("localCLI")) {
                Text(model.cliPath.isEmpty ? L10n.text("cliMissing") : model.cliPath)
                    .font(.caption).textSelection(.enabled)
                Button(L10n.text("chooseCLI")) { model.chooseCLI() }
                if model.cliSelectionError { Text(L10n.text("invalidCLI")).foregroundStyle(.red) }
            }
            Section {
                Toggle(L10n.text("launchAtLogin"), isOn: Binding(
                    get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }
                ))
                if model.loginError { Text(L10n.text("loginItemError")).foregroundStyle(.orange) }
            }
            Section(L10n.text("tokenActivity")) {
                if let usage = model.usage {
                    Text("\(L10n.text("lifetimeTokens")): \(usage.lifetimeTokens.map { $0.formatted() } ?? "—")")
                    Text("\(L10n.text("peakDailyTokens")): \(usage.peakDailyTokens.map { $0.formatted() } ?? "—")")
                    Text("\(L10n.text("currentStreakDays")): \(usage.currentStreakDays.map { $0.formatted() } ?? "—")")
                } else { Text(L10n.text("usageUnavailable")) }
            }
            Section(L10n.text("privacy")) {
                Text(L10n.text("privacyDescription"))
                Text(L10n.text("widgetDescription"))
                if !model.storageAvailable { Text(L10n.text("storageUnavailable")).foregroundStyle(.orange) }
            }
            Section {
                Text("CodexUsageMonitor \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 490, height: 440)
    }
}
