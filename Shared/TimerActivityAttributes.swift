import ActivityKit
import Foundation

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
