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

struct TaskLabel: View {
    @EnvironmentObject var state: AppState
    let taskId: String?

    var body: some View {
        let task = state.task(for: taskId)
        Label(task?.name ?? "No task", systemImage: "checklist")
            .foregroundStyle(task == nil ? .secondary : .primary)
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

/// UIKit share sheet wrapper for exporting a file (e.g. a CSV).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Placeholder rows shown while the history is being fetched, so the first launch
/// doesn't read as "you have no time entries".
struct HistorySkeletonView: View {
    var rows: Int = 5
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar(width: 90, height: 12)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        bar(width: index.isMultiple(of: 2) ? 200 : 150, height: 14)
                        bar(width: 110, height: 11)
                    }
                    Spacer(minLength: 8)
                    bar(width: 62, height: 14)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider().padding(.leading, 16)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityElement()
        .accessibilityLabel("Loading time entries")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(Color.secondary.opacity(0.18))
            .frame(width: width, height: height)
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
