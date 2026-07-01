import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showSignOutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let user = state.user {
                        LabeledContent("Name", value: user.name)
                        LabeledContent("Email", value: user.email)
                    }
                    LabeledContent("Server") {
                        Text(state.host)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if state.memberships.count > 1 {
                    Section("Organization") {
                        ForEach(state.memberships) { membership in
                            Button {
                                Task { await state.switchOrganization(to: membership) }
                            } label: {
                                HStack {
                                    Text(membership.organizationName).foregroundStyle(.primary)
                                    Spacer()
                                    if membership.id == state.selectedMembership?.id {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                } else if let org = state.selectedMembership {
                    Section("Organization") {
                        LabeledContent("Current", value: org.organizationName)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $state.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                Section {
                    HStack {
                        Text("SolidTime Mobile")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of SolidTime?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { state.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your API token will be removed from this device.")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(v) (\(b))"
    }
}
