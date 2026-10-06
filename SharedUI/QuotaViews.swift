import SwiftUI

struct QuotaRow: View {
    let titleKey: String
    let window: UsageWindow?
    var compact = false
    var showsProgress = true

    private var color: Color {
        guard let value = window?.remainingPercent else { return .secondary }
        return value <= 10 ? .red : value <= 25 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            HStack {
                Text(L10n.text(titleKey)).font(compact ? .caption : .subheadline)
                Spacer(minLength: 4)
                Text(window?.percentText ?? "—").font(compact ? .headline : .title2)
                    .monospacedDigit().foregroundStyle(color)
            }
            if showsProgress, let remaining = window?.remainingPercent {
                GeometryReader { geometry in
                    Capsule().fill(.secondary.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(color)
                                .frame(width: geometry.size.width * remaining / 100)
                        }
                }
                .frame(height: 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text(titleKey) + " " + L10n.text("remaining"))
                .accessibilityValue(window?.percentText ?? L10n.text("notAvailable"))
            }
            if let reset = window?.resetsAt {
                if reset > Date() {
                    HStack(spacing: 3) {
                        Text(L10n.text("resetTime"))
                        Text(reset, format: .dateTime.weekday(.abbreviated).hour().minute())
                    }.font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(reset.formatted(date: .complete, time: .shortened))
                } else {
                    Text(L10n.text(compact ? "resetPendingShort" : "awaitingReset")).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.text("notAvailable")).font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct UpdateFooter: View {
    let snapshot: UsageSnapshot
    let now: Date
    var compact = false
    var isWidget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if snapshot.status != .ready {
                Text(isWidget ? L10n.text("short_" + snapshot.status.rawValue) : L10n.status(snapshot.status)).foregroundStyle(.secondary)
            } else if snapshot.isStale(at: now) {
                Label(L10n.text("stale"), systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if let date = snapshot.updatedAt {
                HStack(spacing: 3) {
                    Text(L10n.text("updated"))
                    Text(date, format: .dateTime.hour().minute()).monospacedDigit()
                }.foregroundStyle(.secondary)
                    .help(date.formatted(date: .complete, time: .shortened))
                if !compact {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            } else if !isWidget || snapshot.status == .ready {
                Text(L10n.text("noUpdate")).foregroundStyle(.secondary)
            }
        }.font(compact ? .caption2 : .caption)
    }
}
