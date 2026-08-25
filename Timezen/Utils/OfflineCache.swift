import Foundation

/// Last known server data, kept on disk so the app shows something useful before the
/// first response arrives — and when the server is unreachable.
///
/// Only reference data and the entry history are cached; the running timer is not, since
/// a stale one would be worse than none.
struct CachedSession: Codable {
    var organizationId: String
    var entries: [TimeEntry]
    var projects: [Project]
    var tasks: [ProjectTask]
    var tags: [Tag]
    var clients: [Client]
    var savedAt: Date
}

enum OfflineCache {
    private static let fileName = "session-cache.json"

    private static var url: URL? {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent(fileName)
    }

    static func load() -> CachedSession? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedSession.self, from: data)
    }

    static func save(_ session: CachedSession) {
        guard let url, let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // The cache mirrors time entries, which are personal data: keep it unreadable
        // while the device is locked, like the token in the Keychain.
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
