import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    var date: Date
    var todaySeconds: Int
    var runningStart: Date?
    var runningTitle: String
    var runningProject: String
    var runningColorHex: String
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), todaySeconds: 4 * 3600 + 35 * 60, runningStart: Date().addingTimeInterval(-1500),
                   runningTitle: "Prototype polish", runningProject: "Mobile App", runningColorHex: "#8B5CF6")
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = load()
        // Refresh a minute at a time so the "today" total stays fresh.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private func load() -> TodayEntry {
        let ud = UserDefaults(suiteName: timezenAppGroup)
        let startTS = ud?.double(forKey: "runningStart") ?? -1
        let start = startTS > 0 ? Date(timeIntervalSince1970: startTS) : nil
        return TodayEntry(
            date: Date(),
            todaySeconds: ud?.integer(forKey: "todaySeconds") ?? 0,
            runningStart: start,
            runningTitle: ud?.string(forKey: "runningTitle") ?? "",
            runningProject: ud?.string(forKey: "runningProject") ?? "",
            runningColorHex: ud?.string(forKey: "runningColor") ?? "#888888")
    }
}

struct TodayWidgetView: View {
    var entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "timer").foregroundStyle(.tint)
                Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(timezenDurationHMS(entry.todaySeconds))
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Spacer(minLength: 0)

            if let start = entry.runningStart {
                HStack(spacing: 6) {
                    Circle().fill(hexColor(entry.runningColorHex)).frame(width: 8, height: 8)
                    Text(entry.runningTitle.isEmpty ? entry.runningProject : entry.runningTitle)
                        .font(.caption2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(start, style: .timer)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .frame(maxWidth: 52, alignment: .trailing)
                }
            } else {
                Text("No timer running").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TimezenToday", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Time tracked today and the running timer.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private func hexColor(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)
    let r, g, b: UInt64
    if cleaned.count == 6 { (r, g, b) = (value >> 16, value >> 8 & 0xFF, value & 0xFF) }
    else { (r, g, b) = (120, 120, 120) }
    return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
}
