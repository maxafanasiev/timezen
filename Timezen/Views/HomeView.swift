import SwiftUI

/// Clockify-style home: a running-timer bar pinned at the top with the day-grouped
/// history list below it. Tapping any entry (running or past) opens the edit sheet.
struct HomeView: View {
    @EnvironmentObject var state: AppState

    @State private var editingEntry: TimeEntry?
    @State private var showProjectPicker = false
    @State private var showTagPicker = false
    @State private var showNewEntry = false
    @State private var searchText = ""

    private var isRunning: Bool { state.activeEntry != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                timerBar
                Divider()
                historyList
            }
            .navigationTitle(state.selectedMembership?.organizationName ?? "Timezen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewEntry = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add entry")
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search description, project, tag")
            .sheet(isPresented: $showNewEntry) {
                EntryEditView()
            }
            .sheet(item: $editingEntry) { entry in
                EntryEditView(entry: entry)
            }
            #if DEBUG
            .task(id: debugEditKey) {
                // Testing convenience: ST_EDIT=active|first|new opens a sheet automatically.
                guard editingEntry == nil, !showNewEntry else { return }
                switch ProcessInfo.processInfo.environment["ST_EDIT"] {
                case "active": editingEntry = state.activeEntry
                case "first": editingEntry = state.recentEntries.first { !$0.isRunning }
                case "new": showNewEntry = true
                case "projpick": showProjectPicker = true
                default: break
                }
            }
            #endif
            .sheet(isPresented: $showProjectPicker) {
                ProjectPickerView(selectedProjectId: draftProjectBinding, selectedTaskId: $state.draftTaskId)
            }
            .sheet(isPresented: $showTagPicker) {
                TagPickerView(selected: $state.draftTagIds)
            }
        }
    }

    // MARK: - Timer bar

    private var timerBar: some View {
        VStack(spacing: 12) {
            if isRunning, let active = state.activeEntry {
                HStack(spacing: 12) {
                    Button {
                        editingEntry = active
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(active.description?.isEmpty == false ? active.description! : "No description")
                                .font(.body.weight(.medium))
                                .foregroundStyle(active.description?.isEmpty == false ? .primary : .secondary)
                                .lineLimit(1)
                            ProjectLabel(projectId: active.projectId, taskId: active.taskId)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text(SolidTimeFormatters.hms(state.activeElapsedSeconds))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    actionButton
                }
            } else {
                HStack(spacing: 12) {
                    TextField("What are you working on?", text: $state.draftDescription, axis: .vertical)
                        .lineLimit(1...2)
                    actionButton
                }
                HStack(spacing: 16) {
                    Button { showProjectPicker = true } label: {
                        ProjectLabel(projectId: state.draftProjectId, taskId: state.draftTaskId)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button { state.draftBillable.toggle() } label: {
                        Image(systemName: state.draftBillable ? "dollarsign.circle.fill" : "dollarsign.circle")
                            .foregroundStyle(state.draftBillable ? .green : .secondary)
                    }
                    Button { showTagPicker = true } label: {
                        Image(systemName: state.draftTagIds.isEmpty ? "tag" : "tag.fill")
                            .foregroundStyle(state.draftTagIds.isEmpty ? Color.secondary : Color.accentColor)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var actionButton: some View {
        Button {
            Task { isRunning ? await state.stopTimer() : await state.startTimer() }
        } label: {
            ZStack {
                Circle().fill(isRunning ? Color.red : Color.accentColor)
                    .frame(width: 48, height: 48)
                if state.isTimerBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(state.isTimerBusy)
    }

    // MARK: - History list

    private struct DayGroup: Identifiable {
        let id: Date
        let label: String
        let entries: [TimeEntry]
        let totalSeconds: Int
    }

    /// True if the entry matches the current search query (description, project or tag).
    private func matchesSearch(_ entry: TimeEntry) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if entry.description?.localizedCaseInsensitiveContains(q) == true { return true }
        if state.project(for: entry.projectId)?.name.localizedCaseInsensitiveContains(q) == true { return true }
        if state.task(for: entry.taskId)?.name.localizedCaseInsensitiveContains(q) == true { return true }
        if state.tagNames(for: entry.tags).contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        return false
    }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        let completed = state.recentEntries.filter { !$0.isRunning && matchesSearch($0) }
        let byDay = Dictionary(grouping: completed) { entry -> Date in
            cal.startOfDay(for: entry.startDate ?? .distantPast)
        }
        return byDay.keys.sorted(by: >).map { day in
            let entries = (byDay[day] ?? []).sorted {
                ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
            }
            let total = entries.reduce(0) { $0 + ($1.duration ?? 0) }
            return DayGroup(id: day, label: SolidTimeFormatters.dayLabel(day), entries: entries, totalSeconds: total)
        }
    }

    @ViewBuilder private var historyList: some View {
        if groups.isEmpty {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: "No matches",
                               message: "No entries match “\(searchText)”.")
            } else if state.entriesRestricted {
                EmptyStateView(icon: "lock", title: "History not available",
                               message: "Your role in this organization doesn't allow viewing the time-entry history. You can still track time.")
            } else {
                EmptyStateView(icon: "list.bullet.rectangle", title: "No time entries yet",
                               message: "Start the timer above to track your work. Your history will show up here.")
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            Button { editingEntry = entry } label: {
                                EntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { Task { await state.resume(entry) } } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }.tint(.green)
                                Button { Task { await state.duplicateEntry(entry) } } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }.tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await state.deleteEntry(entry) } } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(group.label)
                            Spacer()
                            Text(SolidTimeFormatters.hms(group.totalSeconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Blurred, full-width backing so rows don't bleed through the
                        // pinned header while scrolling.
                        .background(.ultraThinMaterial)
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await state.refreshEntries() }
        }
    }

    #if DEBUG
    private var debugEditKey: String {
        "\(state.activeEntry?.id ?? "none")-\(state.recentEntries.count)"
    }
    #endif

    private var draftProjectBinding: Binding<String?> {
        Binding(
            get: { state.draftProjectId },
            set: { newValue in
                state.draftProjectId = newValue
                if newValue == nil { state.draftTaskId = nil }
            }
        )
    }
}

/// A single time-entry row (description, project, tags, times, duration, billable flag).
struct EntryRow: View {
    @EnvironmentObject var state: AppState
    let entry: TimeEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.description?.isEmpty == false ? entry.description! : "No description")
                    .font(.body)
                    .foregroundStyle(entry.description?.isEmpty == false ? .primary : .secondary)
                    .lineLimit(2)

                ProjectLabel(projectId: entry.projectId, taskId: entry.taskId)

                if !entry.tags.isEmpty {
                    TagChips(names: state.tagNames(for: entry.tags))
                }

                if let startDate = entry.startDate {
                    let endText = entry.endDate.map { " – \(SolidTimeFormatters.clock($0))" } ?? ""
                    Text("\(SolidTimeFormatters.clock(startDate))\(endText)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(SolidTimeFormatters.hms(entry.duration ?? 0))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if entry.billable == true {
                    Image(systemName: "dollarsign.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
