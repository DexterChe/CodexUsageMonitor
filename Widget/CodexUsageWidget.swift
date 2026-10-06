import SwiftUI
import WidgetKit
import os

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .init(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(.init(date: .now, snapshot: context.isPreview ? .preview : load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date(), snapshot = load()
        var entries = [UsageEntry(date: now, snapshot: snapshot)]
        if let date = snapshot.updatedAt?.addingTimeInterval(180), date > now {
            entries.append(.init(date: date, snapshot: snapshot))
        }
        // Reading cached data is cheap. macOS controls actual timeline delivery.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }

    private func load() -> UsageSnapshot {
        guard let store = try? SnapshotStore.local() else {
            var empty = UsageSnapshot.empty
            empty.status = .storageUnavailable
            return empty
        }
        do {
            let snapshot = try store.read()
            Logger(subsystem: "com.dexterche.CodexUsageMonitor", category: "widget")
                .info("Snapshot loaded: timestampPresent=\(snapshot.updatedAt != nil, privacy: .public) fiveHourAvailable=\(snapshot.fiveHour != nil, privacy: .public) weeklyAvailable=\(snapshot.weekly != nil, privacy: .public)")
            return snapshot
        } catch {
            Logger(subsystem: "com.dexterche.CodexUsageMonitor", category: "widget")
                .error("Snapshot unavailable; no private error details retained")
            var empty = UsageSnapshot.empty
            empty.status = .storageUnavailable
            return empty
        }
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content(for: family)
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: "codexusagemonitor://usage"))
    }

    func content(for family: WidgetFamily) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 7 : 12) {
            HStack {
                Label("Codex", systemImage: "chart.bar.fill").font(.caption.bold())
                Spacer(minLength: 2)
                Text(L10n.text("remaining")).font(.caption2).foregroundStyle(.secondary)
            }
            if family == .systemSmall {
                QuotaRow(titleKey: "fiveHour", window: entry.snapshot.fiveHour, compact: true, showsProgress: false)
                QuotaRow(titleKey: "weekly", window: entry.snapshot.weekly, compact: true, showsProgress: false)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    QuotaRow(titleKey: "fiveHour", window: entry.snapshot.fiveHour, compact: true)
                    QuotaRow(titleKey: "weekly", window: entry.snapshot.weekly, compact: true)
                }
            }
            UpdateFooter(snapshot: entry.snapshot, now: entry.date, compact: true, isWidget: true)
                .lineLimit(family == .systemSmall ? 1 : 2)
        }

    }
}

#if !VISUAL_AUDIT
@main
#endif
struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { UsageWidgetView(entry: $0) }
            .configurationDisplayName("CodexUsageMonitor")
            .description(L10n.text("widgetGalleryDescription"))
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
