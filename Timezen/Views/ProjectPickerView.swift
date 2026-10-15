import SwiftUI

struct ProjectPickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedProjectId: String?
    @Binding var selectedTaskId: String?
    @State private var search = ""
    @State private var showNewProject = false

    private var filteredProjects: [Project] {
        let active = state.projects.filter { !($0.isArchived ?? false) }
        guard !search.isEmpty else { return active }
        return active.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var errorAlert: Binding<Bool> {
        Binding(get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } })
    }

    private var tasksForSelected: [ProjectTask] { state.openTasks(for: selectedProjectId) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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

                if let pid = selectedProjectId, !tasksForSelected.isEmpty {
                    TaskSection(projectId: pid, selectedTaskId: $selectedTaskId)
                }

                Section {
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
                } header: {
                    Text("Projects")
                } footer: {
                    if !state.canCreateProjects {
                        Text("Your role in this organization doesn't allow creating projects.")
                    }
                }
            }
            // Tasks sit above a possibly huge project list; jump there after picking a project.
            .onChange(of: selectedProjectId) {
                withAnimation { proxy.scrollTo("tasks", anchor: .top) }
            }
            }
            .refreshable { await state.refreshProjectsAndTasks() }
            .task { await state.refreshProjectsAndTasks() }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Select Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showNewProject = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New project")
                        // Employees can't create projects; the server would 403.
                        .disabled(!state.canCreateProjects)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't save", isPresented: errorAlert) {
                Button("OK", role: .cancel) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
            .sheet(isPresented: $showNewProject) {
                CreateProjectSheet { name, color, billable, isPublic in
                    guard let p = await state.createProject(name: name, color: color,
                                                            isBillable: billable, isPublic: isPublic) else {
                        return false
                    }
                    selectedProjectId = p.id
                    selectedTaskId = nil
                    return true
                }
            }
        }
    }
}

struct TaskSection: View {
    @EnvironmentObject var state: AppState
    let projectId: String
    @Binding var selectedTaskId: String?
    @State private var showNewTask = false
    @State private var newTaskName = ""

    var body: some View {
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
            .id("tasks")
            ForEach(state.openTasks(for: projectId)) { task in
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
            .disabled(!state.canCreateTasks)
        }
        .alert("New task", isPresented: $showNewTask) {
            TextField("Task name", text: $newTaskName)
            Button("Create") {
                let name = newTaskName
                Task { if let t = await state.createTask(name: name, projectId: projectId) { selectedTaskId = t.id } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct TaskPickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let projectId: String
    @Binding var selectedTaskId: String?

    var body: some View {
        NavigationStack {
            List {
                TaskSection(projectId: projectId, selectedTaskId: $selectedTaskId)
            }
            .refreshable { await state.refreshProjectsAndTasks() }
            .onChange(of: selectedTaskId) { dismiss() }
            .alert("Couldn't save", isPresented: Binding(get: { state.errorMessage != nil },
                                                          set: { if !$0 { state.errorMessage = nil } })) {
                Button("OK", role: .cancel) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
            .navigationTitle("Select Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Small sheet to create a project (name + color + billable).
struct CreateProjectSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    /// Returns true when the project was created; a failure keeps the sheet open so the
    /// entered name isn't lost.
    let onCreate: (String, String, Bool, Bool) async -> Bool

    @State private var name = ""
    @State private var color = "#3b82f6"
    @State private var billable = false
    @State private var isPublic = false
    @State private var busy = false

    // Lowercase hex: the API's colour rule is `^#[0-9a-f]{6}$`.
    private let palette = ["#3b82f6", "#8b5cf6", "#f59e0b", "#10b981", "#ef4444",
                           "#ec4899", "#14b8a6", "#6366f1", "#f97316", "#84cc16"]

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
                    Toggle(isOn: $isPublic) { Label("Public", systemImage: "person.3") }
                } footer: {
                    Text(isPublic
                         ? "Everyone in the organization can see and track time on this project."
                         : "Only admins and members assigned to the project can see it.")
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        busy = true
                        Task {
                            let created = await onCreate(name, color, billable, isPublic)
                            busy = false
                            if created { dismiss() }
                        }
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
                        .disabled(!state.canCreateTags)
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
