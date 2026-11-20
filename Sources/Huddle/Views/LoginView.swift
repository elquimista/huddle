import SwiftUI
import Perception

struct LoginView: View {
    let isFirstAccount: Bool
    @Environment(AccountStore.self) private var store
    @State private var flow = LoginFlow()
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    var body: some View { WithPerceptionTracking {
        VStack(spacing: 0) {
            header
                .padding(.bottom, flow.error == nil ? 26 : 16)

            if let error = flow.error {
                ErrorNote(text: error)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }

            Group {
                switch flow.step {
                case .server: serverStep
                case .password: passwordStep
                case .waitingForBrowser: browserStep
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                    removal: .opacity))

            ForEach(store.restoreErrors, id: \.self) { error in WithPerceptionTracking {
                Text("Couldn’t restore \(error)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            } }
        }
        // Fixed height, pinned to the top, so the icon and title stay put as the steps change.
        .frame(width: 300, height: 460, alignment: .top)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.28), value: flow.step)
        .animation(.smooth(duration: 0.2), value: flow.error)
        .background { LoginBackdrop(coversWindow: isFirstAccount) }
        .overlay(alignment: .topTrailing) {
            if !isFirstAccount {
                Button {
                    flow.cancel()
                    store.isAddingAccount = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Cancel")
                .padding(14)
            }
        }
    } }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            VStack(spacing: 5) {
                Text(isFirstAccount ? "Welcome to Huddle" : "Add an Account")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        switch flow.step {
        case .server: "Sign in with your Matrix account."
        case .password: "Enter your details for \(serverName)."
        case .waitingForBrowser: "Finish signing in to \(serverName) in your browser."
        }
    }

    /// The homeserver's host, without scheme or trailing slash.
    private var serverName: String {
        guard let url = URL(string: flow.homeserverURL), let host = url.host() else { return flow.homeserverURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    // MARK: Steps

    private var serverStep: some View {
        @Perception.Bindable var flow = flow
        return VStack(spacing: 14) {
            FieldGroup {
                FieldRow(icon: "globe") {
                    TextField("Homeserver", text: $flow.server, prompt: Text("matrix.org"))
                        .focused($focus, equals: .server)
                        .onSubmit(continueWithServer)
                }
            }
            PrimaryButton(title: "Continue", isBusy: flow.isBusy, action: continueWithServer)
                .disabled(flow.server.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Use your server’s name or address,\nlike matrix.org or chat.example.com.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .onAppear { focus = .server }
    }

    private var passwordStep: some View {
        @Perception.Bindable var flow = flow
        return VStack(spacing: 14) {
            FieldGroup {
                FieldRow(icon: "person") {
                    TextField("Username", text: $flow.username)
                        .textContentType(.username)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                }
                Divider().padding(.leading, 38)
                FieldRow(icon: "lock") {
                    SecureField("Password", text: $flow.password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit(logIn)
                }
            }
            PrimaryButton(title: "Sign In", isBusy: flow.isBusy, action: logIn)
                .disabled(flow.username.isEmpty || flow.password.isEmpty)

            if flow.supportsBrowser {
                OrDivider()
                Button {
                    Task { await flow.continueInBrowser(store: store) }
                } label: {
                    Label("Continue with Browser", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(flow.isBusy)
                .help("For accounts that use single sign-on, passkeys or two-step verification")
            }
            Button("Use a different server") { flow.cancel() }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
        }
        .onAppear { focus = .username }
    }

    private var browserStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for your browser…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(flow.supportsPassword ? "Use Password Instead" : "Use a different server") {
                flow.leaveBrowser()
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func continueWithServer() {
        guard !flow.isBusy else { return }
        Task { await flow.continueWithServer(store: store) }
    }

    private func logIn() {
        guard !flow.isBusy, !flow.username.isEmpty, !flow.password.isEmpty else { return }
        Task { await flow.logInWithPassword(store: store) }
    }
}

// MARK: - Pieces

/// Rounded container that groups one or more field rows, like a System Settings form section.
private struct FieldGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View { WithPerceptionTracking {
        VStack(spacing: 0) { content }
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.7))
            }
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    } }
}

private struct FieldRow<Content: View>: View {
    let icon: String
    @ViewBuilder var content: Content

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            content
                .textFieldStyle(.plain)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    } }
}

private struct PrimaryButton: View {
    let title: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View { WithPerceptionTracking {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .allowsHitTesting(!isBusy)
    } }
}

private struct OrDivider: View {
    var body: some View { WithPerceptionTracking {
        HStack(spacing: 10) {
            line
            Text("or")
                .font(.caption)
                .foregroundStyle(.tertiary)
            line
        }
    } }

    private var line: some View {
        Rectangle().fill(.separator).frame(height: 1)
    }
}

private struct ErrorNote: View {
    let text: String

    var body: some View { WithPerceptionTracking {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    } }
}

/// Translucent backdrop with a soft accent glow behind the icon. On the first-run screen it
/// also blends the title bar into the window.
private struct LoginBackdrop: View {
    let coversWindow: Bool

    var body: some View { WithPerceptionTracking {
        ZStack {
            VisualEffect(material: coversWindow ? .underWindowBackground : .sheet,
                         blending: coversWindow ? .behindWindow : .withinWindow)
            RadialGradient(colors: [Color.accentColor.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.5, y: 0.22),
                           startRadius: 0,
                           endRadius: 340)
        }
        .ignoresSafeArea()
        .background { if coversWindow { TitleBarBlender() } }
    } }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Hides the window's title and makes its title bar transparent while on screen.
private struct TitleBarBlender: NSViewRepresentable {
    final class Probe: NSView {
        private weak var styledWindow: NSWindow?
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations = []
            if let window {
                styledWindow = window
                apply(to: window)
                // SwiftUI resets these when the window's content updates, so hold them in place.
                observations = [
                    window.observe(\.titlebarAppearsTransparent) { [weak self] window, _ in
                        if !window.titlebarAppearsTransparent { self?.apply(to: window) }
                    },
                    window.observe(\.titleVisibility) { [weak self] window, _ in
                        if window.titleVisibility != .hidden { self?.apply(to: window) }
                    },
                ]
            } else if let styledWindow {
                styledWindow.titlebarAppearsTransparent = false
                styledWindow.titleVisibility = .visible
                styledWindow.isMovableByWindowBackground = false
            }
        }

        private func apply(to window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
}
