import AppIntents
import Foundation

// MARK: - Shared context for background intents

/// Builds an API client from the credentials stored by the app (no UI needed).
enum TimezenIntentContext {
    static var host: String? { UserDefaults.standard.string(forKey: "solidtime.host") }
    static var token: String? { Keychain.get("apiToken") }
    static var selectedOrg: String? {
        let value = UserDefaults.standard.string(forKey: "solidtime.selectedOrg")
        return (value?.isEmpty == false) ? value : nil
    }
    static var client: APIClient? {
        guard let host, let url = AppState.normalizedURL(from: host),
              let token, !token.isEmpty else { return nil }
        return APIClient(baseURL: url, token: token)
    }
}

enum TimezenIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case noOrganization

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Open Timezen and sign in first."
        case .noOrganization: return "No organization is selected in Timezen."
        }
    }
}

// MARK: - Start timer

struct StartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Timer"
    static var description = IntentDescription("Start a new time entry in Timezen.")
    static var openAppWhenRun = false

    @Parameter(title: "Description", default: "")
    var entryDescription: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = TimezenIntentContext.client, let org = TimezenIntentContext.selectedOrg else {
            throw TimezenIntentError.notSignedIn
        }
        let alreadyRunning = ((try? await client.activeTimeEntry()) ?? nil) != nil
        if alreadyRunning {
            return .result(dialog: "A timer is already running.")
        }
        let memberships = try await client.memberships()
        guard let member = memberships.first(where: { $0.organizationId == org }) ?? memberships.first else {
            throw TimezenIntentError.noOrganization
        }
        let trimmed = entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = APIClient.TimeEntryPayload(
            memberId: member.id, projectId: nil, taskId: nil,
            start: SolidTimeFormatters.string(from: Date()), end: nil, billable: false,
            description: trimmed.isEmpty ? nil : trimmed, tags: nil)
        _ = try await client.createTimeEntry(organizationId: member.organizationId, payload: payload)
        return .result(dialog: trimmed.isEmpty ? "Timer started." : "Started “\(trimmed)”.")
    }
}

// MARK: - Stop timer

struct StopTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Timer"
    static var description = IntentDescription("Stop the running time entry in Timezen.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = TimezenIntentContext.client else { throw TimezenIntentError.notSignedIn }
        guard let active = try await client.activeTimeEntry(), let org = active.organizationId else {
            return .result(dialog: "No timer is running.")
        }
        let payload = APIClient.TimeEntryPayload(
            memberId: nil, projectId: active.projectId, taskId: active.taskId,
            start: active.start, end: SolidTimeFormatters.string(from: Date()),
            billable: active.billable ?? false, description: active.description,
            tags: active.tags.isEmpty ? nil : active.tags)
        _ = try await client.updateTimeEntry(organizationId: org, id: active.id, payload: payload)
        return .result(dialog: "Timer stopped.")
    }
}

// MARK: - Today's total

struct TodayTotalIntent: AppIntent {
    static var title: LocalizedStringResource = "Today's Total"
    static var description = IntentDescription("How much time you've tracked today.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Fast path: the value the app last published to the shared App Group.
        let seconds = UserDefaults(suiteName: timezenAppGroup)?.integer(forKey: "todaySeconds") ?? 0
        let text = timezenDurationHMS(seconds)
        return .result(value: text, dialog: "You've tracked \(text) today.")
    }
}

// MARK: - App Shortcuts (Siri / Shortcuts / Spotlight)

struct TimezenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: [
                "Start a timer in \(.applicationName)",
                "Start tracking in \(.applicationName)",
            ],
            shortTitle: "Start Timer",
            systemImageName: "play.fill")
        AppShortcut(
            intent: StopTimerIntent(),
            phrases: [
                "Stop the timer in \(.applicationName)",
                "Stop tracking in \(.applicationName)",
            ],
            shortTitle: "Stop Timer",
            systemImageName: "stop.fill")
        AppShortcut(
            intent: TodayTotalIntent(),
            phrases: [
                "How much have I tracked in \(.applicationName)",
                "Today's total in \(.applicationName)",
            ],
            shortTitle: "Today's Total",
            systemImageName: "sum")
    }
}
