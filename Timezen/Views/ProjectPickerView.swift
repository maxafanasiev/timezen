import SwiftUI

struct ProjectPickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedProjectId: String?
    @Binding var selectedTaskId: String?
    @State private var search = ""
    @State private var showNewProject = false
    @State private var showNewTask = false
    @State private var newTaskName = ""

    private var filteredProjects: [Project] {
        let active = state.projects.filter { !($0.isArchived ?? false) }
        guard !search.isEmpty else { return active }
        return active.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var tasksForSelected: [ProjectTask] {
        guard let pid = selectedProjectId else { return [] }
        return state.tasks.filter { $0.projectId == pid && !($0.isDone ?? false) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selectedProjectId = nil
                        selectedTaskId = nil
                        dismiss()
                    } label: {
                        HStack {
                            ProjectDot(color: .secondary.opacity(0.4))
                            Text("No project").foregroundStyle(.primary)
                            Spacer()
                            if selectedProjectId == nil {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }

                Section("Projects") {
                    ForEach(filteredProjects) { project in
                        Button {
                            if selectedProjectId != project.id { selectedTaskId = nil }
                            selectedProjectId = project.id
                            if tasksForSelected.isEmpty { dismiss() }
                        } label: {
                            HStack {
                                ProjectDot(color: Color(hex: project.color))
                                Text(project.name).foregroundStyle(.primary)
                                Spacer()
                                if selectedProjectId == project.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                if !tasksForSelected.isEmpty {
                    Section("Task") {
                        Button {
                            selectedTaskId = nil
                        } label: {
                            HStack {
                                Text("No task").foregroundStyle(.secondary)
                                Spacer()
                                if selectedTaskId == nil {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        ForEach(tasksForSelected) { task in
                            Button {
                                selectedTaskId = task.id
                            } label: {
                                HStack {
                                    Text(task.name).foregroundStyle(.primary)
                                    Spacer()
                                    if selectedTaskId == task.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                        Button { newTaskName = ""; showNewTask = true } label: {
                            Label("New task", systemImage: "plus.circle")
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Select Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showNewProject = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New project")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showNewProject) {
                CreateProjectSheet { name, color, billable in
                    if let p = await state.createProject(name: name, color: color, isBillable: billable) {
                        selectedProjectId = p.id
                        selectedTaskId = nil
                    }
                }
            }
            .alert("New task", isPresented: $showNewTask) {
                TextField("Task name", text: $newTaskName)
                Button("Create") {
                    guard let pid = selectedProjectId else { return }
                    let name = newTaskName
                    Task { if let t = await state.createTask(name: name, projectId: pid) { selectedTaskId = t.id } }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

/// Small sheet to create a project (name + color + billable).
struct CreateProjectSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, String, Bool) async -> Void

    @State private var name = ""
    @State private var color = "#3B82F6"
    @State private var billable = false
    @State private var busy = false

    private let palette = ["#3B82F6", "#8B5CF6", "#F59E0B", "#10B981", "#EF4444",
                           "#EC4899", "#14B8A6", "#6366F1", "#F97316", "#84CC16"]

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Project name", text: $name) }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(palette, id: \.self) { hex in
                            Circle().fill(Color(hex: hex))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if hex == color {
                                        Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold())
                                    }
                                }
                                .onTapGesture { color = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle(isOn: $billable) { Label("Billable", systemImage: "dollarsign.circle") }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        busy = true
                        Task { await onCreate(name, color, billable); dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
    }
}

struct TagPickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: Set<String>
    @State private var showNewTag = false
    @State private var newTagName = ""

    var body: some View {
        NavigationStack {
            List {
                if state.tags.isEmpty {
                    Text("No tags in this organization yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.tags) { tag in
                    Button {
                        if selected.contains(tag.id) { selected.remove(tag.id) }
                        else { selected.insert(tag.id) }
                    } label: {
                        HStack {
                            Image(systemName: "tag")
                            Text(tag.name).foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(tag.id) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { newTagName = ""; showNewTag = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New tag")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New tag", isPresented: $showNewTag) {
                TextField("Tag name", text: $newTagName)
                Button("Create") {
                    let name = newTagName
                    Task { if let t = await state.createTag(name: name) { selected.insert(t.id) } }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
