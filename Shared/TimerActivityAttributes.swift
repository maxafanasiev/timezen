import ActivityKit
import AppIntents
import Foundation
import WidgetKit

/// App Group used to share timer state between the app and the widget extension.
let timezenAppGroup = "group.com.afanasievmaksym.timezen"

/// API timestamp format used by SolidTime (UTC, `yyyy-MM-dd'T'HH:mm:ss'Z'`).
let timezenAPIDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f
}()

/// Interactive widget button: start the timer if none is running, otherwise stop it.
/// Runs from the widget using credentials the app publishes to the App Group.
struct ToggleTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start / Stop Timer"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await TimezenWidgetTimer.toggle()
        return .result()
    }
}

enum TimezenWidgetTimer {
    static func toggle() async {
        let ud = UserDefaults(suiteName: timezenAppGroup)
        guard let host = ud?.string(forKey: "host"), !host.isEmpty,
              let token = ud?.string(forKey: "token"), !token.isEmpty,
              let base = URL(string: host) else { return }

        func send(_ method: String, _ path: String, _ body: [String: Any]?) async -> (Int, [String: Any]?) {
            var req = URLRequest(url: base.appendingPathComponent("api/v1" + path))
            req.httpMethod = method
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (code, json ?? nil)
        }

        let now = timezenAPIDateFormatter.string(from: Date())
        let (code, json) = await send("GET", "/users/me/time-entries/active", nil)
        let active = (code == 200) ? (json?["data"] as? [String: Any]) : nil

        if let e = active, let id = e["id"] as? String, let org = e["organization_id"] as? String {
            var body: [String: Any] = ["start": e["start"] as? String ?? now, "end": now,
                                       "billable": e["billable"] as? Bool ?? false]
            if let p = e["project_id"] as? String { body["project_id"] = p }
            _ = await send("PUT", "/organizations/\(org)/time-entries/\(id)", body)
            ud?.set(-1.0, forKey: "runningStart")
        } else {
            guard let org = ud?.string(forKey: "orgId"), !org.isEmpty,
                  let member = ud?.string(forKey: "memberId"), !member.isEmpty else { return }
            _ = await send("POST", "/organizations/\(org)/time-entries",
                           ["member_id": member, "start": now, "end": NSNull(), "billable": false])
            ud?.set(Date().timeIntervalSince1970, forKey: "runningStart")
            ud?.set("", forKey: "runningTitle")
            ud?.set("Timer", forKey: "runningProject")
            ud?.set("#5B4BEC", forKey: "runningColor")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

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
