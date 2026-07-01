import Foundation

/// Date parsing/formatting helpers matching the SolidTime API contract:
/// timestamps use the format `Y-m-d\TH:i:s\Z` in UTC (e.g. `2024-02-26T17:17:17Z`).
enum SolidTimeFormatters {
    static let api: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    static func parse(_ string: String) -> Date? {
        api.date(from: string)
    }

    static func string(from date: Date) -> String {
        api.string(from: date)
    }

    /// "1:23:45" for a running timer / long durations, "12:05" for short ones.
    static func hms(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }

    /// Compact human duration like "2h 05m" used in list rows.
    static func humanDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    private static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func clock(_ date: Date) -> String {
        timeOfDay.string(from: date)
    }

    private static let dayHeader: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "EEEE, d MMM"
        return f
    }()

    static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return dayHeader.string(from: date)
    }
}
