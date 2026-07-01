import SwiftUI

/// Small colored dot used to represent a project.
struct ProjectDot: View {
    let color: Color
    var size: CGFloat = 10
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// A row-friendly label combining a project's color dot and name (or "No project").
struct ProjectLabel: View {
    @EnvironmentObject var state: AppState
    let projectId: String?
    let taskId: String?

    var body: some View {
        let project = state.project(for: projectId)
        HStack(spacing: 6) {
            ProjectDot(color: project.map { Color(hex: $0.color) } ?? Color.secondary.opacity(0.4))
            Text(project?.name ?? "No project")
                .foregroundStyle(project == nil ? .secondary : .primary)
            if let task = state.task(for: taskId) {
                Text("· \(task.name)").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
    }
}

struct TagChips: View {
    let names: [String]
    var body: some View {
        if !names.isEmpty {
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
        }
    }
}

/// Empty-state placeholder.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
