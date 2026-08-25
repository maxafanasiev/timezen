import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    var date: Date
    /// Completed time tracked today (the running timer is counted live from `liveOrigin`).
    var baseSeconds: Int
    /// Date the "today" counter would have started from — non-nil while a timer runs.
    var liveOrigin: Date?
    var runningStart: Date?
    var runningTitle: String
    var runningProject: String
    var runningColorHex: String

    /// Today's total at render time (used for the static, non-running case).
    var totalSeconds: Int { baseSeconds }
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        let start = Date().addingTimeInterval(-1500)
        return TodayEntry(date: Date(), baseSeconds: 4 * 3600 + 35 * 60,
                          liveOrigin: start.addingTimeInterval(-(4 * 3600 + 35 * 60)),
                          runningStart: start, runningTitle: "Prototype polish",
                          runningProject: "Mobile App", runningColorHex: "#8B5CF6")
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let entry = load(now: now)
        // While a timer runs the total is rendered live, so the only reload that really
        // matters is midnight, when "today" resets. Refresh periodically as a backstop.
        let cal = TimezenTodaySnapshot.calendar(UserDefaults(suiteName: timezenAppGroup))
        let midnight = cal.startOfDay(for: now.addingTimeInterval(24 * 3600))
        let next = min(midnight, now.addingTimeInterval(15 * 60))
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load(now: Date = Date()) -> TodayEntry {
        let ud = UserDefaults(suiteName: timezenAppGroup)
        let snapshot = TimezenTodaySnapshot.load(now: now, from: ud)
        return TodayEntry(
            date: now,
            baseSeconds: snapshot.seconds(at: now),
            liveOrigin: snapshot.liveOrigin,
            runningStart: snapshot.runningStart,
            runningTitle: ud?.string(forKey: "runningTitle") ?? "",
            runningProject: ud?.string(forKey: "runningProject") ?? "",
            runningColorHex: ud?.string(forKey: "runningColor") ?? "#888888")
    }
}

struct TodayWidgetView: View {
    var entry: TodayEntry

    private var running: Bool { entry.runningStart != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "timer").foregroundStyle(.tint)
                Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Group {
                if let origin = entry.liveOrigin {
                    // Counts up on its own, so the total stays live between timeline reloads.
                    Text(timerInterval: origin...Date.distantFuture, countsDown: false)
                } else {
                    Text(timezenDurationHMS(entry.totalSeconds))
                }
            }
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)

            if let start = entry.runningStart {
                HStack(spacing: 6) {
                    Circle().fill(hexColor(entry.runningColorHex)).frame(width: 8, height: 8)
                    Text(entry.runningTitle.isEmpty ? entry.runningProject : entry.runningTitle)
                        .font(.caption2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(start, style: .timer)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: 64, alignment: .trailing)
                }
            }

            Spacer(minLength: 0)

            Button(intent: ToggleTimerIntent()) {
                HStack(spacing: 5) {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                    Text(running ? "Stop" : "Start")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(running ? Color.red : Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
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
