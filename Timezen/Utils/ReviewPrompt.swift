import Foundation

/// Decides when to ask for an App Store rating.
///
/// The system prompt is rate-limited by iOS itself (at most three per year, and it may
/// show nothing at all), so the app only has to pick a good moment: after the user has
/// actually gotten value out of it — a handful of finished timers — and never more than
/// once per app version.
enum ReviewPrompt {
    /// App Store id, used for the "write a review" deep link in Settings.
    static let appStoreId = "6786309367"

    /// Direct link that opens the App Store review sheet — always available, unlike the
    /// in-app prompt, which iOS may silently skip.
    static var writeReviewURL: URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreId)?action=write-review")
    }

    private static let completedKey = "review.completedTimers"
    private static let promptedVersionKey = "review.promptedVersion"

    /// Finished timers before the first ask, and after that between asks.
    private static let milestone = 8

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Record a finished timer and report whether this is a good moment to ask.
    static func registerCompletedTimer(defaults: UserDefaults = .standard) -> Bool {
        let count = defaults.integer(forKey: completedKey) + 1
        defaults.set(count, forKey: completedKey)
        guard count >= milestone else { return false }
        // One ask per version, so an update is what re-opens the question.
        guard defaults.string(forKey: promptedVersionKey) != currentVersion else { return false }
        defaults.set(currentVersion, forKey: promptedVersionKey)
        defaults.set(0, forKey: completedKey)
        return true
    }
}
