import ActivityKit
import WidgetKit
import SwiftUI

/// Live Activity for the running timer — Lock Screen banner + Dynamic Island.
struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            lockScreen(context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.projectName).lineLimit(1)
                    } icon: {
                        Circle().fill(hexColor(context.state.projectColorHex)).frame(width: 10, height: 10)
                    }
                    .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .monospacedDigit().font(.headline).frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(title(context.state)).font(.subheadline).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .monospacedDigit().frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "timer")
            }
            .keylineTint(hexColor(context.state.projectColorHex))
        }
    }

    private func title(_ s: TimerActivityAttributes.ContentState) -> String {
        s.title.isEmpty ? "Tracking time" : s.title
    }

    @ViewBuilder private func lockScreen(_ s: TimerActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            Circle().fill(hexColor(s.projectColorHex)).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(s)).font(.headline).lineLimit(1)
                Text(s.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(s.startedAt, style: .timer)
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(maxWidth: 96)
        }
    }
}

/// Local hex → Color (the app's Color+Hex isn't part of the widget target).
private func hexColor(_ hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)
    let r, g, b: UInt64
    if cleaned.count == 6 {
        (r, g, b) = (value >> 16, value >> 8 & 0xFF, value & 0xFF)
    } else {
        (r, g, b) = (120, 120, 120)
    }
    return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
}
