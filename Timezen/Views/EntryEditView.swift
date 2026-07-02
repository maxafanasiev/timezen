import SwiftUI

/// Edit sheet for a single time entry — works for both completed entries and the
/// currently-running one. For a running entry only the start time is editable; for a
/// completed entry both start and end can be changed.
struct EntryEditView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// The entry being edited, or nil when creating a brand-new manual entry.
    let existing: TimeEntry?

    @State private var description: String
    @State private var projectId: String?
    @State private var taskId: String?
    @State private var tagIds: Set<String>
    @State private var billable: Bool
    @State private var start: Date
    @State private var end: Date?

    @State private var showProjectPicker = false
    @State private var showTagPicker = false
    @State private var showDeleteConfirm = false
    @State private var editingDuration = false

    private var isRunning: Bool { existing?.isRunning ?? false }
    private var isNew: Bool { existing == nil }

    init(entry: TimeEntry) {
        self.existing = entry
        _description = State(initialValue: entry.description ?? "")
        _projectId = State(initialValue: entry.projectId)
        _taskId = State(initialValue: entry.taskId)
        _tagIds = State(initialValue: Set(entry.tags))
        _billable = State(initialValue: entry.billable ?? false)
        _start = State(initialValue: entry.startDate ?? Date())
        _end = State(initialValue: entry.endDate)
    }

    /// New manual entry — defaults to the previous hour.
    init() {
        self.existing = nil
        let now = Date()
        _description = State(initialValue: "")
        _projectId = State(initialValue: nil)
        _taskId = State(initialValue: nil)
        _tagIds = State(initialValue: [])
        _billable = State(initialValue: false)
        _start = State(initialValue: now.addingTimeInterval(-3600))
        _end = State(initialValue: now)
    }

    private var durationSeconds: Int {
        Int((end ?? Date()).timeIntervalSince(start))
    }

    private var isValid: Bool {
        if let end { return end >= start }
        return start <= Date()
    }

    // MARK: Duration editing (completed entries)

    private enum DurationComponent { case hours, minutes, seconds }

    private func durationComponentBinding(_ component: DurationComponent) -> Binding<Int> {
        Binding(
            get: {
                let d = max(0, durationSeconds)
                switch component {
                case .hours: return min(23, d / 3600)
                case .minutes: return (d % 3600) / 60
                case .seconds: return d % 60
                }
            },
            set: { newValue in
                let d = max(0, durationSeconds)
                var h = d / 3600, m = (d % 3600) / 60, s = d % 60
                switch component {
                case .hours: h = newValue
                case .minutes: m = newValue
                case .seconds: s = newValue
                }
                let total = h * 3600 + m * 60 + s
                end = start.addingTimeInterval(TimeInterval(total))
            }
        )
    }

    private func durationWheel(range: Range<Int>, unit: String, binding: Binding<Int>) -> some View {
        HStack(spacing: 2) {
            Picker(unit, selection: binding) {
                ForEach(range, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            Text(unit).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What are you working on?", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    Button { showProjectPicker = true } label: {
                        HStack {
                            ProjectLabel(projectId: projectId, taskId: taskId)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Button { showTagPicker = true } label: {
                        HStack {
                            Image(systemName: "tag").foregroundStyle(.secondary)
                            let names = state.tagNames(for: Array(tagIds))
                            Text(names.isEmpty ? "Add tags" : names.joined(separator: ", "))
                                .foregroundStyle(names.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    Toggle(isOn: $billable) {
                        Label("Billable", systemImage: "dollarsign.circle")
                    }
                }

                Section("Time") {
                    DatePicker("Start", selection: $start, in: ...(end ?? Date.distantFuture),
                               displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: start) { _, newValue in
                            if let e = end, e < newValue { end = newValue }
                        }

                    if isRunning {
                        LabeledContent("End") {
                            Label("Running", systemImage: "circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                                .imageScale(.small)
                        }
                    } else {
                        DatePicker("End", selection: Binding(
                            get: { end ?? Date() },
                            set: { end = $0 }
                        ), in: start..., displayedComponents: [.date, .hourAndMinute])
                    }

                    if isRunning {
                        LabeledContent("Duration", value: SolidTimeFormatters.hms(max(0, durationSeconds)))
                            .monospacedDigit()
                    } else {
                        // Editable duration — changing it keeps the start fixed and moves the end.
                        Button {
                            withAnimation { editingDuration.toggle() }
                        } label: {
                            HStack {
                                Text("Duration")
                                Spacer()
                                Text(SolidTimeFormatters.hms(max(0, durationSeconds)))
                                    .monospacedDigit()
                                    .foregroundStyle(editingDuration ? Color.accentColor : .secondary)
                                Image(systemName: editingDuration ? "chevron.up" : "chevron.down")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        if editingDuration {
                            HStack(spacing: 0) {
                                durationWheel(range: 0..<24, unit: "h", binding: durationComponentBinding(.hours))
                                durationWheel(range: 0..<60, unit: "m", binding: durationComponentBinding(.minutes))
                                durationWheel(range: 0..<60, unit: "s", binding: durationComponentBinding(.seconds))
                            }
                            .frame(height: 130)
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label("Delete entry", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New Entry" : (isRunning ? "Running Entry" : "Edit Entry"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!isValid || state.isTimerBusy)
                }
            }
            .sheet(isPresented: $showProjectPicker) {
                ProjectPickerView(selectedProjectId: projectBinding, selectedTaskId: $taskId)
            }
            .sheet(isPresented: $showTagPicker) {
                TagPickerView(selected: $tagIds)
            }
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let existing { Task { await state.deleteEntry(existing); dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { projectId },
            set: { newValue in
                projectId = newValue
                if newValue == nil { taskId = nil }
            }
        )
    }

    private func save() async {
        if let existing {
            await state.updateEntry(
                existing,
                description: description,
                projectId: projectId,
                taskId: taskId,
                tagIds: Array(tagIds),
                billable: billable,
                start: start,
                end: isRunning ? nil : end
            )
        } else {
            await state.createManualEntry(
                description: description,
                projectId: projectId,
                taskId: taskId,
                tagIds: Array(tagIds),
                billable: billable,
                start: start,
                end: end ?? Date()
            )
        }
        if state.errorMessage == nil { dismiss() }
    }
}
