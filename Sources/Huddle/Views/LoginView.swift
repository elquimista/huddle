import SwiftUI

struct LoginView: View {
    let isFirstAccount: Bool
    @Environment(AccountStore.self) private var store
    @State private var flow = LoginFlow()
    @FocusState private var usernameFocused: Bool

    var body: some View {
        @Bindable var flow = flow
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text(isFirstAccount ? "Welcome to Huddle" : "Add Account")
                .font(.title2.weight(.semibold))

            switch flow.step {
            case .server:
                Text("Enter your Matrix homeserver.")
                    .foregroundStyle(.secondary)
                TextField("matrix.org", text: $flow.server)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(continueWithServer)
                Button("Continue", action: continueWithServer)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.server.trimmingCharacters(in: .whitespaces).isEmpty || flow.isBusy)

            case .password:
                Text(flow.homeserverURL)
                    .foregroundStyle(.secondary)
                TextField("Username", text: $flow.username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .focused($usernameFocused)
                    .onAppear { usernameFocused = true }
                SecureField("Password", text: $flow.password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit(logIn)
                HStack {
                    Button("Back") { flow.cancel() }
                    Button("Sign In", action: logIn)
                        .keyboardShortcut(.defaultAction)
                        .disabled(flow.username.isEmpty || flow.password.isEmpty || flow.isBusy)
                }

            case .waitingForBrowser:
                Text("Finish signing in to \(flow.homeserverURL) in your browser.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Back") { flow.cancel() }
            }

            if flow.isBusy {
                ProgressView().controlSize(.small)
            }
            if let error = flow.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(store.restoreErrors, id: \.self) { error in
                Text("Couldn't restore \(error)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if !isFirstAccount {
                Button("Cancel") {
                    flow.cancel()
                    store.isAddingAccount = false
                }
                .keyboardShortcut(.cancelAction)
                .padding(14)
            }
        }
    }

    private func continueWithServer() {
        Task { await flow.continueWithServer(store: store) }
    }

    private func logIn() {
        Task { await flow.logInWithPassword(store: store) }
    }
}
