import ActivityKit
import Foundation

/// App Group used to share timer state between the app and the widget extension.
let timezenAppGroup = "group.com.afanasievmaksym.timezen"

/// "1:23:45" / "12:05" duration formatter shared by the app and widgets.
func timezenDurationHMS(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

/// Shared between the app and the widget extension. Describes the running-timer Live Activity.
struct TimerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var startedAt: Date
        var title: String
        var projectName: String
        var projectColorHex: String
    }

    /// The time-entry id this activity represents.
    var entryId: String
}
