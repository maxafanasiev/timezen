import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {

    enum Phase {
        case launching       // deciding whether we have stored credentials
        case loggedOut
        case ready
    }

    // Persisted connection
    @AppStorage("solidtime.host") private var storedHost: String = ""
    @AppStorage("solidtime.selectedOrg") private var storedOrgId: String = ""

    // Session
    @Published var phase: Phase = .launching
    @Published var user: User?
    @Published var memberships: [Membership] = []
    @Published var selectedMembership: Membership?

    // Reference data (per organization)
    @Published var projects: [Project] = []
    @Published var tasks: [ProjectTask] = []
    @Published var tags: [Tag] = []
    @Published var clients: [Client] = []

    // Timer + entries
    @Published var activeEntry: TimeEntry?
    @Published var recentEntries: [TimeEntry] = []
    @Published var entriesRestricted: Bool = false   // history hidden (no permission in this org)
    @Published var now: Date = Date()

    // Dashboard
    @Published var dashboardEntries: [TimeEntry] = []
    @Published var dashboardLoading: Bool = false

    // Draft used when starting a new timer
    @Published var draftDescription: String = ""
    @Published var draftProjectId: String?
    @Published var draftTaskId: String?
    @Published var draftTagIds: Set<String> = []
    @Published var draftBillable: Bool = false

    // UI
    @Published var isBusy: Bool = false          // login / full session load
    @Published var isTimerBusy: Bool = false     // start/stop action in flight
    @Published var errorMessage: String?

    /// App theme; in-memory source of truth so the switch applies live, persisted on change.
    @Published var appearance: AppAppearance = AppState.loadAppearance() {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: AppAppearance.storageKey) }
    }

    private static func loadAppearance() -> AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.storageKey) ?? "") ?? .system
    }

    private var ticker: AnyCancellable?
    private var token: String = ""

    var host: String { storedHost }

    private var client: APIClient? {
        guard let url = Self.normalizedURL(from: storedHost), !token.isEmpty else { return nil }
        return APIClient(baseURL: url, token: token)
    }

    var organizationId: String? { selectedMembership?.organizationId }

    // MARK: - Lifecycle

    func bootstrap() async {
        #if DEBUG
        // Live-switch test: change the published theme after first render (as the picker does).
        if let t = ProcessInfo.processInfo.environment["ST_THEME"], let a = AppAppearance(rawValue: t) {
            appearance = a
        }
        #endif
        #if DEBUG
        // Testing convenience: auto sign-in when launched with ST_HOST / ST_TOKEN in the
        // environment (used to drive the app in the Simulator). Never compiled into Release.
        let env = ProcessInfo.processInfo.environment
        if let h = env["ST_HOST"], let t = env["ST_TOKEN"], !h.isEmpty, !t.isEmpty {
            await signIn(host: h, token: t)
            return
        }
        #endif
        token = Keychain.get("apiToken") ?? ""
        guard !storedHost.isEmpty, !token.isEmpty else {
            phase = .loggedOut
            return
        }
        await refreshSession()
    }

    /// Attempt sign-in with a host + token, persisting them on success.
    func signIn(host rawHost: String, token newToken: String) async {
        guard let url = Self.normalizedURL(from: rawHost) else {
            errorMessage = "Enter a valid server URL, e.g. https://time.example.com"
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        let probe = APIClient(baseURL: url, token: newToken)
        do {
            let me = try await probe.me()
            let mems = try await probe.memberships()
            // Persist only after the credentials proved valid.
            storedHost = url.absoluteString
            token = newToken
            Keychain.set(newToken, for: "apiToken")
            user = me
            memberships = mems
            selectMembership(preferredId: storedOrgId.isEmpty ? nil : storedOrgId)
            phase = .ready
            startTicker()
            await loadOrganizationData()
            await refreshEntries()
            await autoSelectActiveEntryOrg()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refreshSession() async {
        guard let client else { phase = .loggedOut; return }
        isBusy = true
        defer { isBusy = false }
        do {
            user = try await client.me()
            memberships = try await client.memberships()
            selectMembership(preferredId: storedOrgId.isEmpty ? nil : storedOrgId)
            phase = .ready
            startTicker()
            await loadOrganizationData()
            await refreshEntries()
            await autoSelectActiveEntryOrg()
        } catch APIError.unauthorized {
            signOut()
        } catch {
            // Keep the user signed in but surface the problem (e.g. server offline).
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            phase = memberships.isEmpty ? .loggedOut : .ready
            if phase == .ready { startTicker() }
        }
    }

    func signOut() {
        Keychain.delete("apiToken")
        token = ""
        storedHost = ""
        storedOrgId = ""
        user = nil
        memberships = []
        selectedMembership = nil
        projects = []; tasks = []; tags = []; clients = []
        activeEntry = nil; recentEntries = []
        resetDraft()
        ticker = nil
        phase = .loggedOut
    }

    private func selectMembership(preferredId: String?) {
        if let preferredId, let match = memberships.first(where: { $0.organizationId == preferredId }) {
            selectedMembership = match
        } else {
            selectedMembership = memberships.first
        }
        storedOrgId = selectedMembership?.organizationId ?? ""
    }

    func switchOrganization(to membership: Membership) async {
        selectedMembership = membership
        storedOrgId = membership.organizationId
        projects = []; tasks = []; tags = []; clients = []
        resetDraft()
        await loadOrganizationData()
        await refreshEntries()
    }

    // MARK: - Data loading

    func loadOrganizationData() async {
        guard let client, let orgId = organizationId else { return }
        async let p = client.projects(organizationId: orgId)
        async let t = client.tasks(organizationId: orgId)
        async let g = client.tags(organizationId: orgId)
        async let c = client.clients(organizationId: orgId)
        do {
            projects = try await p
            tasks = try await t
            tags = try await g
            clients = try await c
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func refreshEntries() async {
        guard let client, let orgId = organizationId else { return }

        // Running timer is user-scoped and always allowed.
        do {
            activeEntry = try await client.activeTimeEntry()
        } catch APIError.unauthorized {
            signOut(); return
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }

        // History is org-scoped: an "employee" may lack permission to list it.
        // Treat that as "no visible history" rather than an error or a sign-out.
        do {
            recentEntries = try await client.timeEntries(organizationId: orgId, memberId: selectedMembership?.id, limit: 100)
            entriesRestricted = false
        } catch APIError.unauthorized {
            signOut()
        } catch APIError.forbidden {
            recentEntries = []
            entriesRestricted = true
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// On initial load, if a timer is running in a different organization than the one
    /// selected, switch to it so the user lands on the org that actually has activity.
    private func autoSelectActiveEntryOrg() async {
        guard let active = activeEntry, let orgId = active.organizationId,
              orgId != selectedMembership?.organizationId,
              let target = memberships.first(where: { $0.organizationId == orgId }) else { return }
        await switchOrganization(to: target)
    }

    // MARK: - Timer actions

    func startTimer() async {
        guard let client, let orgId = organizationId, let memberId = selectedMembership?.id else { return }
        isTimerBusy = true
        errorMessage = nil
        defer { isTimerBusy = false }

        let payload = APIClient.TimeEntryPayload(
            memberId: memberId,
            projectId: draftProjectId,
            taskId: draftTaskId,
            start: SolidTimeFormatters.string(from: Date()),
            end: nil,
            billable: draftBillable,
            description: draftDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftDescription,
            tags: draftTagIds.isEmpty ? nil : Array(draftTagIds)
        )
        do {
            activeEntry = try await client.createTimeEntry(organizationId: orgId, payload: payload)
            await refreshEntries()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func stopTimer() async {
        guard let client, let entry = activeEntry else { return }
        // The running entry is user-global and may live in a different organization
        // than the one currently selected — stop it in its OWN organization.
        guard let entryOrg = entry.organizationId ?? organizationId else { return }
        isTimerBusy = true
        errorMessage = nil
        defer { isTimerBusy = false }

        let payload = APIClient.TimeEntryPayload(
            memberId: nil,   // omit: the selected org's member is invalid for another org
            projectId: entry.projectId,
            taskId: entry.taskId,
            start: entry.start,
            end: SolidTimeFormatters.string(from: Date()),
            billable: entry.billable ?? false,
            description: entry.description,
            tags: entry.tags.isEmpty ? nil : entry.tags
        )
        do {
            _ = try await client.updateTimeEntry(organizationId: entryOrg, id: entry.id, payload: payload)
            activeEntry = nil
            resetDraft()
            await refreshEntries()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Start a new timer pre-filled from a past entry ("resume").
    func resume(_ entry: TimeEntry) async {
        draftDescription = entry.description ?? ""
        draftProjectId = entry.projectId
        draftTaskId = entry.taskId
        draftTagIds = Set(entry.tags)
        draftBillable = entry.billable ?? false
        if activeEntry != nil { await stopTimer() }
        await startTimer()
    }

    /// Create an identical copy of an entry (same times, project, tags, billable).
    func duplicateEntry(_ entry: TimeEntry) async {
        guard let client, let orgId = organizationId, let memberId = selectedMembership?.id else { return }
        isTimerBusy = true
        errorMessage = nil
        defer { isTimerBusy = false }

        let payload = APIClient.TimeEntryPayload(
            memberId: memberId,
            projectId: entry.projectId,
            taskId: entry.taskId,
            start: entry.start,
            end: entry.end,
            billable: entry.billable ?? false,
            description: entry.description,
            tags: entry.tags.isEmpty ? nil : entry.tags
        )
        do {
            _ = try await client.createTimeEntry(organizationId: orgId, payload: payload)
            await refreshEntries()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deleteEntry(_ entry: TimeEntry) async {
        guard let client, let orgId = entry.organizationId ?? organizationId else { return }
        do {
            try await client.deleteTimeEntry(organizationId: orgId, id: entry.id)
            if activeEntry?.id == entry.id { activeEntry = nil }
            await refreshEntries()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Edit an existing entry — description, project/task/tags/billable and, crucially,
    /// its start and end times. Passing `end == nil` keeps (or makes) the entry running.
    func updateEntry(_ entry: TimeEntry,
                     description: String,
                     projectId: String?,
                     taskId: String?,
                     tagIds: [String],
                     billable: Bool,
                     start: Date,
                     end: Date?) async {
        guard let client, let entryOrg = entry.organizationId ?? organizationId else { return }
        isTimerBusy = true
        errorMessage = nil
        defer { isTimerBusy = false }

        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = APIClient.TimeEntryPayload(
            memberId: nil,
            projectId: projectId,
            taskId: taskId,
            start: SolidTimeFormatters.string(from: start),
            end: end.map(SolidTimeFormatters.string(from:)),
            billable: billable,
            description: trimmed.isEmpty ? nil : trimmed,
            tags: tagIds.isEmpty ? nil : tagIds
        )
        do {
            let updated = try await client.updateTimeEntry(organizationId: entryOrg, id: entry.id, payload: payload)
            // If this was the running entry, reflect whether it's still running.
            if activeEntry?.id == entry.id {
                activeEntry = updated.isRunning ? updated : nil
            }
            await refreshEntries()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func resetDraft() {
        draftDescription = ""
        draftProjectId = nil
        draftTaskId = nil
        draftTagIds = []
        draftBillable = false
    }

    // MARK: - Derived helpers

    func project(for id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func task(for id: String?) -> ProjectTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    func tagNames(for ids: [String]) -> [String] {
        ids.compactMap { id in tags.first { $0.id == id }?.name }
    }

    /// Elapsed seconds of the running entry, computed against the ticking clock.
    var activeElapsedSeconds: Int {
        guard let start = activeEntry?.startDate else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    // MARK: - Dashboard (entries for a user-chosen date range)

    /// Fetch the member's own entries within [from, to] for dashboard statistics.
    func loadDashboard(from: Date, to: Date) async {
        guard let client, let orgId = organizationId, let memberId = selectedMembership?.id else { return }
        dashboardLoading = true
        defer { dashboardLoading = false }
        do {
            dashboardEntries = try await client.timeEntries(
                organizationId: orgId, memberId: memberId, from: from, to: to, limit: 500)
            entriesRestricted = false
        } catch APIError.unauthorized {
            signOut()
        } catch APIError.forbidden {
            dashboardEntries = []
            entriesRestricted = true
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Dashboard rows (completed + running-if-in-range) with effective seconds and day bucket.
    func dashboardRows(from: Date, to: Date) -> [(entry: TimeEntry, seconds: Int, day: Date)] {
        let cal = Calendar.current
        var rows: [(TimeEntry, Int, Date)] = []
        for e in dashboardEntries where !e.isRunning {
            guard let s = e.startDate else { continue }
            rows.append((e, e.duration ?? 0, cal.startOfDay(for: s)))
        }
        // Include the running entry's live elapsed time if it started within the range.
        if let a = activeEntry, let s = a.startDate, s >= from, s <= to {
            rows.append((a, activeElapsedSeconds, cal.startOfDay(for: s)))
        }
        return rows.map { (entry: $0.0, seconds: $0.1, day: $0.2) }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    // MARK: - URL normalization

    static func normalizedURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        // Drop a trailing /api if the user pasted it.
        if s.lowercased().hasSuffix("/api") { s.removeLast(4) }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }
}
