import SwiftUI
import WidgetKit
import AppIntents

struct RefreshMonitorIntent: AppIntent {
    static var title: LocalizedStringResource = "refresh"
    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: MicroWidgetSnapshot.kind)
        return .result()
    }
}

struct MonitorEntry: TimelineEntry {
    let date: Date
    let snapshot: MicroWidgetSnapshot?
    var preview = false
    var fresh: Bool { snapshot?.isFresh(at: date) == true }
}

struct MonitorProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonitorEntry { MonitorEntry(date: Date(), snapshot: nil, preview: true) }
    func getSnapshot(in context: Context, completion: @escaping (MonitorEntry) -> Void) {
        completion(MonitorEntry(date: Date(), snapshot: context.isPreview ? nil : MicroWidgetSnapshot.read(), preview: context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MonitorEntry>) -> Void) {
        let now = Date(), snapshot = MicroWidgetSnapshot.read()
        var entries = [MonitorEntry(date: now, snapshot: snapshot)]
        if let snapshot, snapshot.isFresh(at: now) {
            entries.append(MonitorEntry(date: snapshot.updatedAt.addingTimeInterval(MicroWidgetSnapshot.lifetime), snapshot: nil))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(5 * 60))))
    }
}

struct MonitorWidgetView: View {
    let entry: MonitorEntry
    private var artwork: NSImage? {
        if entry.fresh, let data = entry.snapshot?.artwork, let image = NSImage(data: data) { return image }
        guard let url = Bundle.main.url(forResource: entry.preview ? "WidgetPreview" : "WidgetNeutral", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 544, geometry.size.height / 564)
            ZStack(alignment: .topLeading) {
                if let artwork {
                    Image(nsImage: artwork).resizable().interpolation(.high)
                        .frame(width: 590 * scale, height: 610 * scale)
                        .offset(x: -23 * scale, y: -23 * scale)
                        .accessibilityHidden(true)
                }
                ForEach(0..<14, id: \.self) { slot in
                    let key = entry.fresh ? entry.snapshot?.keys.first { $0.slot == slot } : nil
                    keyLink(cell: MicroWidgetSnapshot.cells[slot], scale: scale,
                        url: MicroWidgetSnapshot.url(threadID: key?.threadID, scope: entry.snapshot?.scope),
                        title: key?.label ?? localized("emptySlot"),
                        value: localized(key?.signal ?? "unknown"))
                }
                Button(intent: RefreshMonitorIntent()) {
                    Color.white.opacity(0.001).frame(width: 96 * scale, height: 96 * scale)
                        .contentShape(RoundedRectangle(cornerRadius: 14 * scale))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("refresh"))
                .accessibilityValue(entry.fresh ? entry.snapshot?.meter?.label ?? "" : localized("unknown"))
                .help(localized("refresh"))
                .offset(x: 65 * scale, y: 393 * scale)
                keyLink(cell: 15, scale: scale, url: MicroWidgetSnapshot.url(activateCodex: true), title: "Codex")
            }
            .frame(width: 544 * scale, height: 564 * scale, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .widgetURL(MicroWidgetSnapshot.url())
        .containerBackground(for: .widget) { Color.clear }
    }

    private func keyLink(cell: Int, scale: CGFloat, url: URL, title: String, value: String = "") -> some View {
        Link(destination: url) {
            Color.white.opacity(0.001)
                .frame(width: 96 * scale, height: 96 * scale)
                .contentShape(RoundedRectangle(cornerRadius: 14 * scale))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .help(value.isEmpty ? title : "\(title) · \(value)")
        .privacySensitive()
        .offset(x: (65 + CGFloat(cell % 4)*106) * scale, y: (75 + CGFloat(cell / 4)*106) * scale)
    }

    private func localized(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
}

@main struct MicroMonitorWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MicroWidgetSnapshot.kind, provider: MonitorProvider()) { MonitorWidgetView(entry: $0) }
            .configurationDisplayName("Codex Micro")
            .description("monitor")
            .supportedFamilies([.systemLarge])
            .contentMarginsDisabled()
            .containerBackgroundRemovable(false)
    }
}
