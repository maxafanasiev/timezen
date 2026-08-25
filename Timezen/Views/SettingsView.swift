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
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(membership.organizationName).foregroundStyle(.primary)
                                        // The role decides what the dashboard can show:
                                        // team reports and billable rates need more than "employee".
                                        if let role = membership.role {
                                            Text(role.capitalized)
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
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
                        if let role = org.role {
                            LabeledContent("Your role", value: role.capitalized)
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $state.appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Security") {
                    Toggle(isOn: $state.lockEnabled) {
                        Label("Require Face ID / passcode", systemImage: "faceid")
                    }
                }

                Section("Reminders") {
                    Toggle(isOn: $state.reminderEnabled) {
                        Label("Long-timer reminder", systemImage: "bell")
                    }
                    if state.reminderEnabled {
                        Picker(selection: $state.reminderHours) {
                            ForEach([4, 6, 8, 10, 12], id: \.self) { Text("\($0) hours").tag($0) }
                        } label: {
                            Label("Remind after", systemImage: "clock")
                        }
                    }
                }

                Section {
                    HStack {
                        Label("Your rate", systemImage: "dollarsign.circle")
                        Spacer()
                        TextField("0", value: $state.localHourlyRate, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90)
                        Text("\(state.currency)/h").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Billable rate")
                } footer: {
                    Text(state.hasLocalRate
                         ? "Used only when your server doesn't share billable rates. Amounts are a local estimate from your billable time and never leave the device."
                         : "Set an hourly rate to estimate earnings locally when your server doesn't share billable rates.")
                }

                // Makes it visible when a self-hosted server is too old for the team
                // features, instead of them silently not appearing.
                Section("Server features") {
                    LabeledContent("Team members", value: state.membersStatus.label)
                    LabeledContent("Reports", value: state.reportStatus.label)
                }
                .font(.footnote)

                Section {
                    if let url = ReviewPrompt.writeReviewURL {
                        Link(destination: url) {
                            Label("Rate Timezen", systemImage: "star")
                        }
                    }
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
                        Text("Timezen")
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
