import AppKit
import SwiftUI
import WidgetKit

/// Synthetic native-view renders only. This entry point never starts polling or opens credentials.
@main
@MainActor
struct VisualAudit {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var normal = UsageSnapshot.preview
        normal.updatedAt = Date()
        var stale = normal
        stale.updatedAt = Date().addingTimeInterval(-600)
        var error = stale
        error.status = .connectionFailed
        var extremes = normal
        extremes.fiveHour = .init(durationMinutes: 300, remainingPercent: 0, resetsAt: Date().addingTimeInterval(-60))
        extremes.weekly = .init(durationMinutes: 10080, remainingPercent: 100, resetsAt: Date().addingTimeInterval(604800))
        for (name, snapshot) in [("normal", normal), ("stale", stale), ("error", error), ("empty", .empty), ("extremes", extremes)] {
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let model = MonitorModel(preview: snapshot)
                try render(MonitorView(model: model).environment(\.colorScheme, scheme),
                           width: 280, height: nil, path: directory.appendingPathComponent("menu-\(name)-\(appearance).png"))
                for (size, family, width) in [("small", WidgetFamily.systemSmall, 164.0), ("medium", WidgetFamily.systemMedium, 344.0)] {
                    let content = UsageWidgetView(entry: .init(date: Date(), snapshot: snapshot)).content(for: family).padding(16)
                        .frame(width: width, height: 164)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 24))
                        .environment(\.colorScheme, scheme)
                    try render(content, width: width, height: 164,
                               path: directory.appendingPathComponent("widget-\(size)-\(name)-\(appearance).png"))
                }
            }
        }
        print("Rendered 30 synthetic native views at 2x scale; no polling or live data.")
    }

    static func render<V: View>(_ content: V, width: CGFloat, height: CGFloat?, path: URL) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "VisualAudit", code: 1)
        }
        try png.write(to: path)
    }
}
