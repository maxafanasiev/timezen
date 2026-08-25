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

/// Keys the app publishes to the App Group so the widget and intents can render
/// "today" without the app running.
enum TimezenSharedKey {
    static let todayBaseSeconds = "todayBaseSeconds"   // completed entries that started today
    static let todayDay = "todayDay"                   // start of the day the base refers to
    static let runningStart = "runningStart"           // running timer start, -1 when idle
    static let timezone = "timezone"                   // the SolidTime profile's timezone
    // The draft the app would start a timer with, so the widget button matches it.
    static let draftDescription = "draftDescription"
    static let draftProjectId = "draftProjectId"
    static let draftTaskId = "draftTaskId"
    static let draftBillable = "draftBillable"
}

/// Today's tracked time, reconstructed from the shared snapshot.
///
/// The app publishes only the *completed* total plus the running timer's start, so the
/// widget can keep counting on its own and a stale snapshot from yesterday reads as 0
/// instead of silently showing yesterday's number.
struct TimezenTodaySnapshot {
    /// Completed seconds tracked on `day`.
    var baseSeconds: Int
    /// Start of the day `baseSeconds` belongs to.
    var day: Date
    /// Start of the running timer, if one is running.
    var runningStart: Date?

    /// "Today" follows the SolidTime profile's timezone, the same way the app and the
    /// server group days — a device travelling to another timezone shouldn't shift it.
    static func calendar(_ ud: UserDefaults?) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        if let name = ud?.string(forKey: TimezenSharedKey.timezone), let zone = TimeZone(identifier: name) {
            cal.timeZone = zone
        }
        return cal
    }

    static func load(now: Date = Date(),
                     from ud: UserDefaults? = UserDefaults(suiteName: timezenAppGroup)) -> TimezenTodaySnapshot {
        let cal = calendar(ud)
        let today = cal.startOfDay(for: now)
        let dayTS = ud?.double(forKey: TimezenSharedKey.todayDay) ?? 0
        let day = dayTS > 0 ? Date(timeIntervalSince1970: dayTS) : today
        let startTS = ud?.double(forKey: TimezenSharedKey.runningStart) ?? -1
        // A base written on an earlier day no longer describes today.
        let base = cal.isDate(day, inSameDayAs: today)
            ? (ud?.integer(forKey: TimezenSharedKey.todayBaseSeconds) ?? 0) : 0
        return TimezenTodaySnapshot(baseSeconds: max(0, base), day: today,
                                    runningStart: startTS > 0 ? Date(timeIntervalSince1970: startTS) : nil)
    }

    /// The running timer, but only when it started today — matching how the app counts
    /// "today's total" (a timer started yesterday isn't folded into today).
    var runningStartedToday: Date? {
        guard let runningStart, runningStart >= day else { return nil }
        return runningStart
    }

    /// Date from which `Text(timerInterval:)` counts up to today's total — i.e. the
    /// moment the total would have been zero. `nil` when nothing is running today.
    var liveOrigin: Date? {
        runningStartedToday.map { $0.addingTimeInterval(-Double(baseSeconds)) }
    }

    /// Today's total at `now` (base plus the running timer's elapsed time).
    func seconds(at now: Date = Date()) -> Int {
        guard let start = runningStartedToday else { return baseSeconds }
        return baseSeconds + max(0, Int(now.timeIntervalSince(start)))
    }

    /// Fold a just-finished entry into the shared base so the widget total doesn't dip
    /// until the app next publishes a snapshot.
    static func addCompleted(seconds: Int, startedAt: Date, now: Date = Date(),
                             to ud: UserDefaults? = UserDefaults(suiteName: timezenAppGroup)) {
        guard let ud, seconds > 0 else { return }
        let cal = calendar(ud)
        let today = cal.startOfDay(for: now)
        guard cal.isDate(startedAt, inSameDayAs: today) else { return }
        let current = load(now: now, from: ud)
        ud.set(current.baseSeconds + seconds, forKey: TimezenSharedKey.todayBaseSeconds)
        ud.set(today.timeIntervalSince1970, forKey: TimezenSharedKey.todayDay)
    }
}

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
            // Keep today's total intact until the app publishes a fresh snapshot.
            if let startString = e["start"] as? String,
               let started = timezenAPIDateFormatter.date(from: startString) {
                TimezenTodaySnapshot.addCompleted(seconds: Int(Date().timeIntervalSince(started)),
                                                 startedAt: started, to: ud)
            }
            ud?.set(-1.0, forKey: TimezenSharedKey.runningStart)
        } else {
            guard let org = ud?.string(forKey: "orgId"), !org.isEmpty,
                  let member = ud?.string(forKey: "memberId"), !member.isEmpty else { return }
            // Start with whatever the app has staged (project, task, description,
            // billable), so the widget button behaves like the button in the app.
            let description = ud?.string(forKey: TimezenSharedKey.draftDescription) ?? ""
            let projectId = ud?.string(forKey: TimezenSharedKey.draftProjectId) ?? ""
            let taskId = ud?.string(forKey: TimezenSharedKey.draftTaskId) ?? ""
            var body: [String: Any] = [
                "member_id": member, "start": now, "end": NSNull(),
                "billable": ud?.bool(forKey: TimezenSharedKey.draftBillable) ?? false,
            ]
            if !description.isEmpty { body["description"] = description }
            if !projectId.isEmpty { body["project_id"] = projectId }
            if !taskId.isEmpty { body["task_id"] = taskId }
            _ = await send("POST", "/organizations/\(org)/time-entries", body)
            ud?.set(Date().timeIntervalSince1970, forKey: TimezenSharedKey.runningStart)
            ud?.set(description, forKey: "runningTitle")
            ud?.set(ud?.string(forKey: "draftProjectName") ?? "Timer", forKey: "runningProject")
            ud?.set(ud?.string(forKey: "draftProjectColor") ?? "#5B4BEC", forKey: "runningColor")
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
