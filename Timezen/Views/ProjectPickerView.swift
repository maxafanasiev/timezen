import SwiftUI

struct ProjectPickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedProjectId: String?
    @Binding var selectedTaskId: String?
    @State private var search = ""

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
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Select Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct TagPickerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: Set<String>

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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
