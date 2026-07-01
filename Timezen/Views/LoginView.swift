import SwiftUI

struct LoginView: View {
    @EnvironmentObject var state: AppState
    @State private var host: String = ""
    @State private var token: String = ""
    @FocusState private var focus: Field?

    private enum Field { case host, token }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server URL").font(.subheadline.weight(.semibold))
                        TextField("https://time.example.com", text: $host)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .host)
                            .submitLabel(.next)
                            .onSubmit { focus = .token }
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        Text("The base URL of your self-hosted SolidTime instance.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Token").font(.subheadline.weight(.semibold))
                        SecureField("Personal access token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .token)
                            .submitLabel(.go)
                            .onSubmit { Task { await submit() } }
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        Text("Profile Settings → API Tokens → create a token, then paste it here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let error = state.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            if state.isBusy { ProgressView().tint(.white) }
                            Text(state.isBusy ? "Connecting…" : "Connect")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit || state.isBusy)
                }
                .padding(24)
            }
            .navigationTitle("SolidTime")
            .scrollDismissesKeyboard(.interactively)
            .onAppear { host = state.host }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Connect to your instance")
                .font(.title2.bold())
            Text("Sign in with your server URL and a personal API token.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() async {
        focus = nil
        await state.signIn(host: host, token: token)
    }
}
