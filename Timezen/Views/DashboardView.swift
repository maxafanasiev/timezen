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

    @State private var type: PeriodType = DashboardView.initialType
    @State private var offset: Offset = .current
    @State private var customFrom: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var customTo: Date = Date()
    /// Project ids to include; empty = all. "__none__" represents entries with no project.
    @State private var projectFilter: Set<String> = []
    private static let noProjectKey = "__none__"
    @State private var exportURL: URL?
    @State private var showExport = false

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

    /// Projects (and possibly "No project") that appear in the loaded range — the filter options.
    private var availableProjectKeys: [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for e in state.dashboardEntries {
            let key = e.projectId ?? Self.noProjectKey
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    private func projectName(forKey key: String) -> String {
        key == Self.noProjectKey ? "No project" : (state.project(for: key)?.name ?? "Project")
    }

    private var filterLabel: String {
        if projectFilter.isEmpty { return "All projects" }
        if projectFilter.count == 1, let only = projectFilter.first { return projectName(forKey: only) }
        return "\(projectFilter.count) projects"
    }

    private var totalSeconds: Int { rows.reduce(0) { $0 + $1.seconds } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    rangePicker
                    projectFilterMenu
                    totalCard
                    perDayChart
                    projectBreakdown
                }
                .padding()
            }
            .navigationTitle("Dashboard")
            .task(id: reloadKey) { await state.loadDashboard(from: range.from, to: range.to) }
            .refreshable { await state.loadDashboard(from: range.from, to: range.to) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportURL = buildCSV()
                        showExport = exportURL != nil
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export CSV")
                    .disabled(rows.isEmpty)
                }
            }
            .sheet(isPresented: $showExport) {
                if let exportURL { ActivityView(items: [exportURL]) }
            }
        }
    }

    /// Build a CSV of the current range's entries and write it to a temp file.
    private func buildCSV() -> URL? {
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

    // Re-fetch whenever the effective range or organization changes.
    private var reloadKey: String {
        "\(state.organizationId ?? "")-\(range.from.timeIntervalSince1970)-\(range.to.timeIntervalSince1970)"
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
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(rangeLabel).font(.subheadline).foregroundStyle(.secondary)
                if state.dashboardLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(height: 41, alignment: .leading)
                } else {
                    Text(SolidTimeFormatters.humanDuration(totalSeconds))
                        .font(.largeTitle.bold()).monospacedDigit()
                }
            }
            Spacer()
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
    private var dayProjectData: [DayProjectSlice] {
        var totals: [Date: [String: Int]] = [:]   // day -> projectName -> seconds
        for row in rows {
            let name = state.project(for: row.entry.projectId)?.name ?? "No project"
            totals[row.day, default: [:]][name, default: 0] += row.seconds
        }
        return totals.flatMap { day, byName in
            byName.map { DayProjectSlice(date: day, projectName: $0.key, seconds: $0.value) }
        }
    }

    /// Stable project → color scale for the chart (ordered by total time, desc).
    private var projectStyleScale: (domain: [String], range: [Color]) {
        var totals: [String: Int] = [:]
        for row in rows {
            let name = state.project(for: row.entry.projectId)?.name ?? "No project"
            totals[name, default: 0] += row.seconds
        }
        let ordered = totals.sorted { $0.value > $1.value }.map(\.key)
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
            if state.dashboardLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            } else if data.isEmpty {
                Text("No tracked time in this range.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(data) { slice in
                    BarMark(
                        x: .value("Day", slice.date, unit: .day),
                        y: .value("Hours", Double(slice.seconds) / 3600.0)
                    )
                    .foregroundStyle(by: .value("Project", slice.projectName))
                    .cornerRadius(2)
                }
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

    private var byProject: [(projectId: String?, seconds: Int)] {
        var totals: [String: Int] = [:]
        for row in rows { totals[row.entry.projectId ?? "__none__", default: 0] += row.seconds }
        return totals
            .map { (projectId: $0.key == "__none__" ? nil : $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    private var projectBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By project").font(.headline)
            let data = byProject
            let total = max(1, data.reduce(0) { $0 + $1.seconds })
            if state.dashboardLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 40)
            } else if data.isEmpty {
                Text("Nothing tracked in this range yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(data, id: \.projectId) { row in
                    let project = state.project(for: row.projectId)
                    let color = project.map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.4)
                    VStack(spacing: 6) {
                        HStack {
                            ProjectDot(color: color)
                            Text(project?.name ?? "No project")
                                .foregroundStyle(project == nil ? .secondary : .primary)
                            Spacer()
                            Text(SolidTimeFormatters.humanDuration(row.seconds))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.subheadline)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.15))
                                Capsule().fill(color)
                                    .frame(width: geo.size.width * CGFloat(row.seconds) / CGFloat(total))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
