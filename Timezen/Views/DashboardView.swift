import SwiftUI
import Charts

/// Personal dashboard computed locally from the member's own entries within a
/// user-selected date range. Uses the API's `start`/`end` range filter to fetch,
/// so it works without org-wide admin permissions.
struct DashboardView: View {
    @EnvironmentObject var state: AppState

    /// The kind of period to look at.
    enum PeriodType: String, CaseIterable, Identifiable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
        case halfMonth = "Half"
        case custom = "Custom"
        var id: String { rawValue }
        var isPeriodic: Bool { self != .custom }
    }

    /// Current period vs the one before it.
    enum Offset: String, CaseIterable, Identifiable {
        case current = "Current"
        case previous = "Previous"
        var id: String { rawValue }
    }

    /// Whose time the dashboard reports on. Anything but `.me` goes through the
    /// server-side aggregation endpoint and needs admin/manager permissions.
    enum Scope: Hashable {
        case me
        case everyone
        case member(String)     // organization member id
    }

    @State private var type: PeriodType = DashboardView.initialType
    @State private var offset: Offset = .current
    @State private var scope: Scope = DashboardView.initialScope
    @State private var customFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var customTo: Date = Date()
    /// Project ids to include; empty = all. "__none__" represents entries with no project.
    @State private var projectFilter: Set<String> = []
    private static let noProjectKey = "__none__"
    @State private var exportURL: URL?
    @State private var showExport = false

    /// DEBUG convenience: ST_SCOPE=everyone opens the dashboard on the team report.
    private static var initialScope: Scope {
        #if DEBUG
        if ProcessInfo.processInfo.environment["ST_SCOPE"] == "everyone" { return .everyone }
        #endif
        return .me
    }

    private static var initialType: PeriodType {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["ST_RANGE"],
           let t = PeriodType(rawValue: raw) { return t }
        if ProcessInfo.processInfo.environment["ST_RANGE"] == "custom" { return .custom }
        #endif
        return .week
    }

    // MARK: Resolved range [from, to] (whole days, inclusive)

    private var range: (from: Date, to: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let back = offset == .previous  // shift one period into the past

        func endOfDay(_ d: Date) -> Date {
            cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: d))!
        }
        // First moment of the month `monthsAgo` before the month containing `today`.
        func monthStart(_ monthsAgo: Int) -> Date {
            let base = cal.dateInterval(of: .month, for: today)?.start ?? today
            return cal.date(byAdding: .month, value: -monthsAgo, to: base)!
        }
        // The semi-monthly period (1st–15th or 16th–end of month) containing `date`.
        func halfPeriod(containing date: Date) -> (from: Date, to: Date) {
            let mStart = cal.dateInterval(of: .month, for: date)?.start ?? date
            if cal.component(.day, from: date) <= 15 {
                let end = cal.date(byAdding: DateComponents(day: 15, second: -1), to: mStart)!  // through the 15th
                return (mStart, end)
            } else {
                let start = cal.date(byAdding: .day, value: 15, to: mStart)!                    // the 16th
                let nextMonth = cal.date(byAdding: .month, value: 1, to: mStart)!
                let end = cal.date(byAdding: DateComponents(second: -1), to: nextMonth)!          // end of month
                return (start, end)
            }
        }

        switch type {
        case .day:
            let day = cal.date(byAdding: .day, value: back ? -1 : 0, to: today)!
            return (day, endOfDay(day))

        case .week:
            let start0 = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let start = cal.date(byAdding: .day, value: back ? -7 : 0, to: start0)!
            let end = cal.date(byAdding: DateComponents(day: 7, second: -1), to: start)!
            return (start, end)

        case .month:
            let start = monthStart(back ? 1 : 0)
            let end = cal.date(byAdding: DateComponents(month: 1, second: -1), to: start)!
            return (start, end)

        case .halfMonth:
            // Semi-monthly periods (1st–15th and 16th–end) that run consecutively.
            let current = halfPeriod(containing: today)
            if !back { return current }
            // "Previous" = the half-period immediately before the current one.
            let dayBefore = cal.date(byAdding: .day, value: -1, to: current.from)!
            return halfPeriod(containing: dayBefore)

        case .custom:
            let f = cal.startOfDay(for: customFrom)
            let t = endOfDay(customTo)
            return (min(f, t), max(f, t))
        }
    }

    private var rows: [(entry: TimeEntry, seconds: Int, day: Date)] {
        let all = state.dashboardRows(from: range.from, to: range.to)
        guard !projectFilter.isEmpty else { return all }
        return all.filter { projectFilter.contains($0.entry.projectId ?? Self.noProjectKey) }
    }

    private var isTeamScope: Bool { scope != .me }

    /// The report backing the team scopes; nil while it hasn't loaded.
    private var teamReport: OrgReport? { isTeamScope ? state.report : nil }

    /// `member_id` filter for the current scope: own membership for `.me`, none for
    /// `.everyone` (whole organization), or the picked member.
    private var scopeMemberId: String? {
        switch scope {
        case .me: return state.selectedMembership?.id
        case .everyone: return nil
        case .member(let id): return id
        }
    }

    private var scopeLabel: String {
        switch scope {
        case .me: return "Me"
        case .everyone: return "Everyone"
        case .member(let id): return state.members.first { $0.id == id }?.name ?? "Member"
        }
    }

    /// Day/project/seconds triples the chart and the project breakdown are built from,
    /// so personal and team scopes share one rendering path.
    private var chartRows: [(day: Date, projectKey: String, seconds: Int)] {
        if let report = teamReport {
            return report.days.flatMap { day in
                day.projects.map { (day.day, $0.key ?? Self.noProjectKey, $0.seconds) }
            }
        }
        return rows.map {
            // A running entry ticks every second; round it so the bars don't re-layout.
            ($0.day, $0.entry.projectId ?? Self.noProjectKey,
             $0.entry.isRunning ? ($0.seconds / 60) * 60 : $0.seconds)
        }
    }

    /// Per-project totals with money when the server reports it.
    private var breakdownRows: [(key: String, seconds: Int, cost: Int?)] {
        if let report = teamReport {
            return report.projects.map { ($0.key ?? Self.noProjectKey, $0.seconds, $0.cost) }
        }
        var totals: [String: Int] = [:]
        var billable: [String: Int] = [:]
        for row in rows {
            let key = row.entry.projectId ?? Self.noProjectKey
            totals[key, default: 0] += row.seconds
            if row.entry.billable == true { billable[key, default: 0] += row.seconds }
        }
        return totals
            .map { (key: $0.key,
                    seconds: $0.value,
                    cost: state.localCostCents(forBillableSeconds: billable[$0.key] ?? 0)) }
            .sorted { ($0.seconds, $1.key) > ($1.seconds, $0.key) }
    }

    /// Seconds on billable entries in the personal scope — the basis for the local
    /// rate estimate when the server doesn't share money.
    private var billableSeconds: Int {
        rows.filter { $0.entry.billable == true }.reduce(0) { $0 + $1.seconds }
    }

    /// True when the amounts shown are the app's own estimate rather than the server's.
    private var isEstimatedCost: Bool {
        !isTeamScope && state.report?.totalCost == nil && state.hasLocalRate
    }

    /// Money for the current selection: from the report for every scope, including `.me`
    /// (the personal totals are computed locally, but only the server knows the rates).
    private var scopeCostCents: Int? {
        if isTeamScope { return teamReport?.totalCost }
        // The personal totals are computed locally, so the report's money only lines up
        // with what's on screen while no project filter is applied.
        if projectFilter.isEmpty, let cost = state.report?.totalCost { return cost }
        // Server withheld the rates — fall back to the rate the user entered in Settings.
        return state.localCostCents(forBillableSeconds: billableSeconds)
    }

    private var isLoading: Bool {
        isTeamScope ? state.reportLoading : state.dashboardLoading
    }

    /// Filter options. The personal scope lists the projects seen in the loaded entries;
    /// team scopes list the organization's active projects, because the report is already
    /// filtered server-side and would otherwise shrink its own option list.
    private var availableProjectKeys: [String] {
        if isTeamScope {
            var keys = state.projects.filter { !($0.isArchived ?? false) }.map(\.id)
            keys.append(Self.noProjectKey)
            return keys
        }
        var keys: [String] = []
        var seen = Set<String>()
        for e in state.dashboardEntries {
            let key = e.projectId ?? Self.noProjectKey
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    /// The project filter translated for the API: "none" stands for "no project".
    private var scopeProjectIds: [String] {
        projectFilter.sorted().map { $0 == Self.noProjectKey ? "none" : $0 }
    }

    private func projectName(forKey key: String) -> String {
        key == Self.noProjectKey ? "No project" : (state.project(for: key)?.name ?? "Project")
    }

    private var filterLabel: String {
        if projectFilter.isEmpty { return "All projects" }
        if projectFilter.count == 1, let only = projectFilter.first { return projectName(forKey: only) }
        return "\(projectFilter.count) projects"
    }

    private var totalSeconds: Int {
        if let report = teamReport { return report.totalSeconds }
        return rows.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    rangePicker
                    if state.canViewTeam { scopeMenu }
                    projectFilterMenu
                    totalCard
                    if isTeamScope && state.reportRestricted {
                        restrictedCard
                    } else {
                        perDayChart
                        projectBreakdown
                        if isTeamScope { memberBreakdown }
                    }
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .task(id: reloadKey) { await reload() }
            .refreshable { await reload() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportURL = buildCSV()
                        showExport = exportURL != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export CSV")
                    .disabled(isTeamScope ? (teamReport?.totalSeconds ?? 0) == 0 : rows.isEmpty)
                }
            }
            .sheet(isPresented: $showExport) {
                if let exportURL { ActivityView(items: [exportURL]) }
            }
        }
    }

    /// Build a CSV of the current range and write it to a temp file. Team scopes export
    /// the aggregated report (the raw entries of other members aren't loaded).
    private func buildCSV() -> URL? {
        if isTeamScope { return buildReportCSV() }
        return buildEntriesCSV()
    }

    private func buildReportCSV() -> URL? {
        guard let report = teamReport else { return nil }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func amount(_ cents: Int?) -> String {
            guard let cents else { return "" }
            return String(format: "%.2f", Double(cents) / 100.0)
        }
        func hours(_ seconds: Int) -> String { String(format: "%.2f", Double(seconds) / 3600.0) }

        var lines = ["Group,Name,Duration,Hours,Amount,Currency"]
        lines.append(["Total", esc(scopeLabel), SolidTimeFormatters.hms(report.totalSeconds),
                      hours(report.totalSeconds), amount(report.totalCost), state.currency].joined(separator: ","))
        for slice in report.projects {
            lines.append(["Project", esc(projectName(forKey: slice.key ?? Self.noProjectKey)),
                          SolidTimeFormatters.hms(slice.seconds), hours(slice.seconds),
                          amount(slice.cost), state.currency].joined(separator: ","))
        }
        for slice in report.members {
            lines.append(["Member", esc(state.memberName(forUserId: slice.key)),
                          SolidTimeFormatters.hms(slice.seconds), hours(slice.seconds),
                          amount(slice.cost), state.currency].joined(separator: ","))
        }
        for day in report.days where day.seconds > 0 {
            lines.append(["Day", df.string(from: day.day), SolidTimeFormatters.hms(day.seconds),
                          hours(day.seconds), "", state.currency].joined(separator: ","))
        }

        let name = "timezen-report-\(df.string(from: range.from))_\(df.string(from: range.to)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func buildEntriesCSV() -> URL? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Date,Start,End,Duration,Project,Task,Description,Tags,Billable"]
        let sorted = rows.sorted { ($0.entry.startDate ?? .distantPast) < ($1.entry.startDate ?? .distantPast) }
        for row in sorted {
            let e = row.entry
            let fields = [
                e.startDate.map { df.string(from: $0) } ?? "",
                e.startDate.map { tf.string(from: $0) } ?? "",
                e.endDate.map { tf.string(from: $0) } ?? "",
                SolidTimeFormatters.hms(e.duration ?? row.seconds),
                state.project(for: e.projectId)?.name ?? "",
                state.task(for: e.taskId)?.name ?? "",
                e.description ?? "",
                state.tagNames(for: e.tags).joined(separator: "; "),
                (e.billable ?? false) ? "yes" : "no",
            ]
            lines.append(fields.map(esc).joined(separator: ","))
        }
        let name = "timezen-\(df.string(from: range.from))_\(df.string(from: range.to)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // Re-fetch whenever the effective range, organization or scope changes.
    private var reloadKey: String {
        // The personal scope filters locally, so only team scopes re-fetch on filter changes.
        let filter = isTeamScope ? scopeProjectIds.joined(separator: ",") : ""
        return "\(state.organizationId ?? "")-\(range.from.timeIntervalSince1970)-\(range.to.timeIntervalSince1970)-\(scopeLabel)-\(isTeamScope)-\(filter)"
    }

    private func reload() async {
        // The member listing doubles as the permission probe for the team scopes.
        if !state.membersProbed { await state.loadMembers() }
        if !isTeamScope { await state.loadDashboard(from: range.from, to: range.to) }
        await state.loadReport(from: range.from, to: range.to,
                               memberId: scopeMemberId,
                               projectIds: isTeamScope ? scopeProjectIds : [])
    }

    // MARK: Range picker

    private var rangePicker: some View {
        VStack(spacing: 10) {
            Picker("Period", selection: $type) {
                ForEach(PeriodType.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if type.isPeriodic {
                Picker("Offset", selection: $offset) {
                    ForEach(Offset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } else {
                VStack(spacing: 8) {
                    DatePicker("From", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                    DatePicker("To", selection: $customTo, in: customFrom...Date(), displayedComponents: .date)
                }
                .font(.subheadline)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Scope (whose time to report on)

    @ViewBuilder private var scopeMenu: some View {
        Menu {
            Button { scope = .me } label: {
                Label("Me", systemImage: scope == .me ? "checkmark" : "person")
            }
            Button { scope = .everyone } label: {
                Label("Everyone", systemImage: scope == .everyone ? "checkmark" : "person.3")
            }
            if !state.members.isEmpty { Divider() }
            ForEach(state.members) { member in
                Button { scope = .member(member.id) } label: {
                    Label(member.name, systemImage: scope == .member(member.id) ? "checkmark" : "person")
                }
            }
        } label: {
            HStack {
                Image(systemName: isTeamScope ? "person.3" : "person")
                Text(scopeLabel)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .tint(.primary)
    }

    private var restrictedCard: some View {
        EmptyStateView(icon: "lock",
                       title: "Team reports not available",
                       message: "Your role in this organization doesn't allow viewing other members' time.")
            .frame(minHeight: 160)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Project filter

    @ViewBuilder private var projectFilterMenu: some View {
        let keys = availableProjectKeys
        Menu {
            Button {
                projectFilter = []
            } label: {
                Label("All projects", systemImage: projectFilter.isEmpty ? "checkmark" : "circle")
            }
            if !keys.isEmpty { Divider() }
            ForEach(keys, id: \.self) { key in
                Button {
                    if projectFilter.contains(key) { projectFilter.remove(key) }
                    else { projectFilter.insert(key) }
                } label: {
                    Label(projectName(forKey: key),
                          systemImage: projectFilter.contains(key) ? "checkmark" : "circle")
                }
            }
        } label: {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(filterLabel)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .menuActionDismissBehavior(.disabled)
        .tint(.primary)
    }

    // MARK: Total

    private var totalCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rangeLabel).font(.subheadline).foregroundStyle(.secondary)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(height: 41, alignment: .leading)
                } else {
                    Text(SolidTimeFormatters.humanDuration(totalSeconds))
                        .font(.largeTitle.bold()).monospacedDigit()
                }
            }
            Spacer()
            // Money is only shown when the server actually reports a cost — it withholds
            // billable rates from members who may not see them.
            if let cents = scopeCostCents, !isLoading {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(isEstimatedCost ? "Billable (estimate)" : "Billable")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(SolidTimeFormatters.money(cents: cents, currency: state.currency))
                        .font(.title2.bold()).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var rangeLabel: String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        if Calendar.current.isDate(range.from, inSameDayAs: range.to) {
            return f.string(from: range.from)
        }
        return "\(f.string(from: range.from)) – \(f.string(from: range.to))"
    }

    // MARK: Per-day chart (stacked by project, in project colors)

    private struct DayProjectSlice: Identifiable {
        let date: Date
        let projectName: String
        let seconds: Int
        var id: String { "\(date.timeIntervalSince1970)-\(projectName)" }
    }

    /// One slice per (day, project) so the bar for each day is split by project.
    ///
    /// The order is fully deterministic — by day, then by the project's position in the
    /// style scale — because Swift Charts stacks segments in data order: an unordered
    /// Dictionary walk made the coloured blocks swap places on every redraw.
    /// A running timer's seconds are rounded down to whole minutes for the same reason:
    /// the bars shouldn't re-layout once a second.
    private var dayProjectData: [DayProjectSlice] {
        var totals: [Date: [String: Int]] = [:]   // day -> projectName -> seconds
        for row in chartRows {
            let name = projectName(forKey: row.projectKey)
            totals[row.day, default: [:]][name, default: 0] += row.seconds
        }
        let order = projectOrder
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return totals
            .sorted { $0.key < $1.key }
            .flatMap { day, byName in
                byName
                    .map { DayProjectSlice(date: day, projectName: $0.key, seconds: $0.value) }
                    .sorted { (rank[$0.projectName] ?? .max, $0.projectName) < (rank[$1.projectName] ?? .max, $1.projectName) }
            }
    }

    /// Project names ordered by total time (desc), name as tie-breaker so equal totals
    /// don't shuffle between redraws — Swift's sort isn't stable.
    private var projectOrder: [String] {
        var totals: [String: Int] = [:]
        for row in chartRows {
            totals[projectName(forKey: row.projectKey), default: 0] += row.seconds
        }
        return totals.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// Stable project → color scale for the chart (ordered by total time, desc).
    private var projectStyleScale: (domain: [String], range: [Color]) {
        let ordered = projectOrder
        let colors = ordered.map { name -> Color in
            if name == "No project" { return Color.secondary.opacity(0.4) }
            if let p = state.projects.first(where: { $0.name == name }) { return Color(hex: p.color) }
            return Color.secondary.opacity(0.4)
        }
        return (ordered, colors)
    }

    private var perDayChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By day").font(.headline)
            let data = dayProjectData
            let scale = projectStyleScale
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            } else if data.isEmpty {
                Text("No tracked time in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(data) { slice in
                    BarMark(
                        x: .value("Day", slice.date, unit: .day),
                        y: .value("Hours", Double(slice.seconds) / 3600.0),
                        stacking: .standard
                    )
                    .foregroundStyle(by: .value("Project", slice.projectName))
                    .cornerRadius(2)
                }
                .animation(.default, value: data.count)
                .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
                .chartLegend(scale.domain.count > 1 ? .visible : .hidden)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))h") } }
                    }
                }
                .frame(height: 200)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Project breakdown

    private var projectBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By project").font(.headline)
            let data = breakdownRows
            let total = max(1, data.reduce(0) { $0 + $1.seconds })
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 40)
            } else if data.isEmpty {
                Text("Nothing tracked in this range yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(data, id: \.key) { row in
                    let project = row.key == Self.noProjectKey ? nil : state.project(for: row.key)
                    let color = project.map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.4)
                    BreakdownRow(color: color,
                                 name: projectName(forKey: row.key),
                                 isMuted: project == nil,
                                 seconds: row.seconds,
                                 subtitle: nil,
                                 money: row.cost.map { SolidTimeFormatters.money(cents: $0, currency: state.currency) },
                                 fraction: Double(row.seconds) / Double(total))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Member breakdown (team scopes)

    private var memberBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By member").font(.headline)
            let data = teamReport?.members ?? []
            let total = max(1, data.reduce(0) { $0 + $1.seconds })
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 40)
            } else if data.isEmpty {
                Text("Nobody tracked time in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(data) { row in
                    let member = state.member(forUserId: row.key)
                    // The hourly rate stored on the membership, when the API exposes it.
                    let rate = member?.billableRate.map {
                        SolidTimeFormatters.money(cents: $0, currency: state.currency) + "/h"
                    }
                    BreakdownRow(color: .accentColor,
                                 name: state.memberName(forUserId: row.key),
                                 isMuted: false,
                                 seconds: row.seconds,
                                 subtitle: rate,
                                 money: row.cost.map { SolidTimeFormatters.money(cents: $0, currency: state.currency) },
                                 fraction: Double(row.seconds) / Double(total))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// One line of a dashboard breakdown: name, optional rate, time, money and a share bar.
private struct BreakdownRow: View {
    let color: Color
    let name: String
    let isMuted: Bool
    let seconds: Int
    let subtitle: String?
    let money: String?
    let fraction: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ProjectDot(color: color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).foregroundStyle(isMuted ? .secondary : .primary)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(SolidTimeFormatters.humanDuration(seconds))
                        .foregroundStyle(.secondary).monospacedDigit()
                    if let money {
                        Text(money).font(.caption.weight(.medium)).monospacedDigit()
                    }
                }
            }
            .font(.subheadline)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                }
            }
            .frame(height: 6)
        }
    }
}
