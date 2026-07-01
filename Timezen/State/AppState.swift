import Foundation
import SwiftUI
import Combine
import LocalAuthentication
import UserNotifications
import ActivityKit

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

    // Offline demo / App Review mode (no network; mutations are local).
    @Published var isDemo: Bool = false
    private var demoCounter = 0

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

    /// Require Face ID / Touch ID / passcode to open the app.
    @Published var lockEnabled: Bool = UserDefaults.standard.bool(forKey: "timezen.lock") {
        didSet {
            UserDefaults.standard.set(lockEnabled, forKey: "timezen.lock")
            isUnlocked = true   // keep the current session; re-locks on next background
        }
    }
    /// Whether the app is currently unlocked (starts locked when lock is enabled).
    @Published var isUnlocked: Bool = false

    /// Prompt biometric / passcode authentication to unlock.
    func unlock() async {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Passcode"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics/passcode configured — don't lock the user out.
            isUnlocked = true
            return
        }
        do {
            isUnlocked = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Timezen")
        } catch {
            isUnlocked = false
        }
    }

    func lockNow() {
        if lockEnabled { isUnlocked = false }
    }

    // MARK: - Long-running-timer reminder

    private static let reminderID = "timer-reminder"

    @Published var reminderEnabled: Bool = UserDefaults.standard.bool(forKey: "timezen.reminder") {
        didSet {
            UserDefaults.standard.set(reminderEnabled, forKey: "timezen.reminder")
            if reminderEnabled {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            syncTimerReminder()
        }
    }
    /// Hours after which a still-running timer triggers a reminder.
    @Published var reminderHours: Int = {
        let v = UserDefaults.standard.integer(forKey: "timezen.reminderHours")
        return v == 0 ? 6 : v
    }() {
        didSet {
            UserDefaults.standard.set(reminderHours, forKey: "timezen.reminderHours")
            syncTimerReminder()
        }
    }

    /// Schedule (or cancel) the reminder for the currently-running entry.
    func syncTimerReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        guard reminderEnabled, let start = activeEntry?.startDate else { return }
        let interval = start.addingTimeInterval(Double(reminderHours) * 3600).timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Timer still running"
        let what = activeEntry?.description?.isEmpty == false ? "“\(activeEntry!.description!)”" : "your timer"
        content.body = "\(reminderHours)h on \(what). Don't forget to stop it."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.reminderID, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        center.add(request)
    }

    // MARK: - Live Activity (running timer)

    private var liveActivity: Activity<TimerActivityAttributes>?

    /// Start/update/end the running-timer Live Activity to match `activeEntry`.
    func syncLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let active = activeEntry, let start = active.startDate {
            let project = project(for: active.projectId)
            let content = ActivityContent(
                state: TimerActivityAttributes.ContentState(
                    startedAt: start,
                    title: active.description ?? "",
                    projectName: project?.name ?? "No project",
                    projectColorHex: project?.color ?? "#888888"),
                staleDate: nil)
            if let liveActivity, liveActivity.attributes.entryId == active.id {
                Task { await liveActivity.update(content) }
            } else {
                if let old = liveActivity { Task { await old.end(nil, dismissalPolicy: .immediate) } }
                liveActivity = try? Activity.request(
                    attributes: TimerActivityAttributes(entryId: active.id),
                    content: content, pushType: nil)
            }
        } else if let old = liveActivity {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
            liveActivity = nil
        }
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
        // Demo mode for App Store screenshots — synthetic data, no network.
        if ProcessInfo.processInfo.environment["ST_DEMO"] == "1" {
            loadDemoData()
            return
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
        // Restore demo session without hitting the network.
        if Self.isDemoCredentials(host: storedHost, token: token) {
            loadDemoData()
            return
        }
        await refreshSession()
    }

    // MARK: - Demo / App Review account

    /// Fixed credentials that unlock an offline demo (given to Apple in App Review Information).
    static let demoHost = "https://demo.timezen.app"
    static let demoToken = "timezen-demo-review"

    static func isDemoCredentials(host: String, token: String) -> Bool {
        let h = normalizedURL(from: host)?.absoluteString.lowercased()
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h == demoHost && t == demoToken
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

        // Demo/review account: fixed credentials load synthetic data with no network.
        if Self.isDemoCredentials(host: url.absoluteString, token: newToken) {
            storedHost = url.absoluteString
            token = newToken
            Keychain.set(newToken, for: "apiToken")
            loadDemoData()
            return
        }

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
        activeEntry = nil; recentEntries = []; dashboardEntries = []
        isDemo = false
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
        if isDemo { return }   // demo data is local; nothing to fetch
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
        syncTimerReminder()
        syncLiveActivity()
    }

    /// On initial load, if a timer is running in a different organization than the one
    /// selected, switch to it so the user lands on the org that actually has activity.
    private func autoSelectActiveEntryOrg() async {
        guard let active = activeEntry, let orgId = active.organizationId,
              orgId != selectedMembership?.organizationId,
              let target = memberships.first(where: { $0.organizationId == orgId }) else { return }
        await switchOrganization(to: target)
    }

    // MARK: - Create project / task / tag (inline)

    func createProject(name: String, color: String, isBillable: Bool) async -> Project? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isDemo {
            demoCounter += 1
            let p = Project(id: "demo-p-\(demoCounter)", name: trimmed, color: color,
                            clientId: nil, isArchived: false, isBillable: isBillable)
            projects.append(p); return p
        }
        guard let client, let orgId = organizationId else { return nil }
        do {
            let p = try await client.createProject(organizationId: orgId, name: trimmed, color: color, isBillable: isBillable)
            projects.append(p); return p
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func createTask(name: String, projectId: String) async -> ProjectTask? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isDemo {
            demoCounter += 1
            let t = ProjectTask(id: "demo-t-\(demoCounter)", name: trimmed, isDone: false, projectId: projectId)
            tasks.append(t); return t
        }
        guard let client, let orgId = organizationId else { return nil }
        do {
            let t = try await client.createTask(organizationId: orgId, name: trimmed, projectId: projectId)
            tasks.append(t); return t
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    func createTag(name: String) async -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isDemo {
            demoCounter += 1
            let t = Tag(id: "demo-g-\(demoCounter)", name: trimmed)
            tags.append(t); return t
        }
        guard let client, let orgId = organizationId else { return nil }
        do {
            let t = try await client.createTag(organizationId: orgId, name: trimmed)
            tags.append(t); return t
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    // MARK: - Timer actions

    func startTimer() async {
        if isDemo { startDemoTimer(); return }
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
        if isDemo { stopDemoTimer(); return }
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
        if isDemo {
            recentEntries.insert(demoClone(entry), at: 0)
            dashboardEntries = recentEntries
            return
        }
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

    /// Create a brand-new completed entry for a past interval (manual logging).
    func createManualEntry(description: String,
                           projectId: String?,
                           taskId: String?,
                           tagIds: [String],
                           billable: Bool,
                           start: Date,
                           end: Date) async {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDemo {
            demoCounter += 1
            let e = TimeEntry(
                id: "demo-\(demoCounter)", start: SolidTimeFormatters.string(from: start),
                end: SolidTimeFormatters.string(from: end), duration: max(0, Int(end.timeIntervalSince(start))),
                description: trimmed.isEmpty ? nil : trimmed, taskId: taskId, projectId: projectId,
                organizationId: selectedMembership?.organizationId, userId: user?.id, tags: tagIds, billable: billable)
            recentEntries.insert(e, at: 0)
            dashboardEntries = recentEntries
            return
        }
        guard let client, let orgId = organizationId, let memberId = selectedMembership?.id else { return }
        isTimerBusy = true
        errorMessage = nil
        defer { isTimerBusy = false }
        let payload = APIClient.TimeEntryPayload(
            memberId: memberId, projectId: projectId, taskId: taskId,
            start: SolidTimeFormatters.string(from: start), end: SolidTimeFormatters.string(from: end),
            billable: billable, description: trimmed.isEmpty ? nil : trimmed,
            tags: tagIds.isEmpty ? nil : tagIds)
        do {
            _ = try await client.createTimeEntry(organizationId: orgId, payload: payload)
            await refreshEntries()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deleteEntry(_ entry: TimeEntry) async {
        if isDemo {
            recentEntries.removeAll { $0.id == entry.id }
            if activeEntry?.id == entry.id { activeEntry = nil }
            dashboardEntries = recentEntries
            return
        }
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
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDemo {
            let updated = TimeEntry(
                id: entry.id, start: SolidTimeFormatters.string(from: start),
                end: end.map(SolidTimeFormatters.string(from:)),
                duration: end.map { Int($0.timeIntervalSince(start)) } ?? 0,
                description: trimmedDesc.isEmpty ? nil : trimmedDesc, taskId: taskId, projectId: projectId,
                organizationId: entry.organizationId, userId: entry.userId, tags: tagIds, billable: billable)
            if activeEntry?.id == entry.id {
                activeEntry = updated.isRunning ? updated : nil
                if !updated.isRunning { recentEntries.insert(updated, at: 0) }
            } else if let i = recentEntries.firstIndex(where: { $0.id == entry.id }) {
                recentEntries[i] = updated
            }
            dashboardEntries = recentEntries
            return
        }
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
        if isDemo { dashboardEntries = recentEntries; return }   // local demo data
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

    // MARK: - Demo data (offline demo / App Review account)

    func loadDemoData() {
        isDemo = true
        demoCounter = 0
        let now = Date()
        let cal = Calendar.current
        let org = "org-demo"

        user = User(id: "u1", name: "Alex Rivera", email: "alex@acme.studio",
                    profilePhotoUrl: nil, timezone: "Europe/Kyiv")
        let membership = Membership(
            id: "m1",
            organization: Membership.Organization(id: org, name: "Acme Studio", currency: "USD"),
            role: "owner")
        memberships = [membership]
        selectedMembership = membership

        projects = [
            Project(id: "p1", name: "Website Redesign", color: "#3B82F6", clientId: nil, isArchived: false, isBillable: true),
            Project(id: "p2", name: "Mobile App", color: "#8B5CF6", clientId: nil, isArchived: false, isBillable: true),
            Project(id: "p3", name: "Marketing", color: "#F59E0B", clientId: nil, isArchived: false, isBillable: false),
            Project(id: "p4", name: "Client Support", color: "#10B981", clientId: nil, isArchived: false, isBillable: true),
        ]
        tasks = [
            ProjectTask(id: "t1", name: "Landing page", isDone: false, projectId: "p1"),
            ProjectTask(id: "t2", name: "Onboarding flow", isDone: false, projectId: "p2"),
            ProjectTask(id: "t3", name: "Q3 campaign", isDone: false, projectId: "p3"),
        ]
        tags = [Tag(id: "g1", name: "focus"), Tag(id: "g2", name: "meeting"), Tag(id: "g3", name: "review")]
        clients = []

        func mk(_ id: String, _ desc: String, _ pid: String?, _ tid: String?, _ tags: [String],
                _ billable: Bool, day: Int, h: Int, m: Int, minutes: Int) -> TimeEntry {
            let dayStart = cal.date(byAdding: .day, value: -day, to: cal.startOfDay(for: now))!
            let s = cal.date(byAdding: DateComponents(hour: h, minute: m), to: dayStart)!
            let e = s.addingTimeInterval(Double(minutes) * 60)
            return TimeEntry(id: id, start: SolidTimeFormatters.string(from: s),
                             end: SolidTimeFormatters.string(from: e), duration: minutes * 60,
                             description: desc, taskId: tid, projectId: pid, organizationId: org,
                             userId: "u1", tags: tags, billable: billable)
        }

        recentEntries = [
            // Today
            mk("e1", "Landing page hero section", "p1", "t1", ["g1"], true, day: 0, h: 9, m: 5, minutes: 95),
            mk("e2", "Standup & sprint planning", "p2", nil, ["g2"], true, day: 0, h: 11, m: 0, minutes: 40),
            mk("e3", "Q3 email campaign draft", "p3", "t3", [], false, day: 0, h: 12, m: 30, minutes: 75),
            mk("e4", "Customer bug triage", "p4", nil, ["g3"], true, day: 0, h: 14, m: 20, minutes: 65),
            // Yesterday
            mk("e5", "Onboarding flow build", "p2", "t2", ["g1"], true, day: 1, h: 9, m: 30, minutes: 150),
            mk("e6", "Design review", "p1", nil, ["g3"], true, day: 1, h: 13, m: 0, minutes: 80),
            mk("e7", "Support inbox", "p4", nil, [], true, day: 1, h: 15, m: 0, minutes: 95),
            // Earlier this week
            mk("e8", "Component library", "p2", "t2", ["g1"], true, day: 2, h: 10, m: 0, minutes: 180),
            mk("e9", "Landing copy polish", "p1", "t1", [], true, day: 2, h: 14, m: 30, minutes: 70),
            mk("e10", "Analytics dashboard", "p3", nil, ["g1"], false, day: 3, h: 9, m: 45, minutes: 140),
            mk("e11", "Release checklist", "p2", nil, ["g2"], true, day: 3, h: 13, m: 30, minutes: 90),
            mk("e12", "Client call — Northwind", "p4", nil, ["g2"], true, day: 4, h: 11, m: 0, minutes: 55),
            mk("e13", "Homepage A/B test", "p1", "t1", ["g1"], true, day: 4, h: 14, m: 0, minutes: 120),
        ]
        dashboardEntries = recentEntries

        // Running entry started 37 minutes ago.
        let start = now.addingTimeInterval(-37 * 60)
        activeEntry = TimeEntry(id: "active", start: SolidTimeFormatters.string(from: start), end: nil,
                                duration: 0, description: "Prototype polish", taskId: "t2", projectId: "p2",
                                organizationId: org, userId: "u1", tags: ["g1"], billable: true)

        errorMessage = nil
        phase = .ready
        startTicker()
    }

    // Local (offline) demo mutations.

    private func startDemoTimer() {
        demoCounter += 1
        let desc = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        activeEntry = TimeEntry(
            id: "demo-\(demoCounter)", start: SolidTimeFormatters.string(from: Date()), end: nil,
            duration: 0, description: desc.isEmpty ? nil : desc, taskId: draftTaskId, projectId: draftProjectId,
            organizationId: selectedMembership?.organizationId, userId: user?.id,
            tags: Array(draftTagIds), billable: draftBillable)
        syncTimerReminder()
        syncLiveActivity()
    }

    private func stopDemoTimer() {
        guard let entry = activeEntry, let start = entry.startDate else { return }
        let end = Date()
        let stopped = TimeEntry(
            id: entry.id, start: entry.start, end: SolidTimeFormatters.string(from: end),
            duration: max(0, Int(end.timeIntervalSince(start))), description: entry.description,
            taskId: entry.taskId, projectId: entry.projectId, organizationId: entry.organizationId,
            userId: entry.userId, tags: entry.tags, billable: entry.billable)
        recentEntries.insert(stopped, at: 0)
        dashboardEntries = recentEntries
        activeEntry = nil
        resetDraft()
        syncTimerReminder()
        syncLiveActivity()
    }

    private func demoClone(_ entry: TimeEntry) -> TimeEntry {
        demoCounter += 1
        return TimeEntry(
            id: "demo-\(demoCounter)", start: entry.start, end: entry.end, duration: entry.duration,
            description: entry.description, taskId: entry.taskId, projectId: entry.projectId,
            organizationId: entry.organizationId, userId: entry.userId, tags: entry.tags, billable: entry.billable)
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
