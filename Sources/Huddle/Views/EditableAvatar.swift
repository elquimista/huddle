import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Perception

/// A large picture that can be changed: a click asks for a new one, or, when there is one,
/// offers to see it large or remove it too. "Edit" shows on hover, and a spinner while a change
/// is saved. One that can't be changed opens large when clicked, if there's a picture.
/// Room Info and Edit Profile use it.
struct EditableAvatar<Picture: View>: View {
    let canChange: Bool
    let isBusy: Bool
    let hasPicture: Bool
    /// What the open panel says the picture is for.
    let chooseMessage: String
    let choose: (URL) -> Void
    let remove: () -> Void
    /// Shows the picture large; nil when there's none to show (only an initial).
    var showLarge: (() -> Void)? = nil
    @ViewBuilder let picture: Picture
    @State private var isHovering = false
    @State private var anchor = MenuAnchor()

    private var isEnabled: Bool { canChange && !isBusy }

    var body: some View { WithPerceptionTracking {
        // One that can't be changed is just the picture, or a way to see it large. A disabled
        // button would dim it.
        if canChange {
            button
        } else if let showLarge {
            Button(action: showLarge) {
                picture.contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("View picture")
            .accessibilityLabel("View picture")
        } else {
            picture.accessibilityLabel("Picture")
        }
    } }

    private var button: some View {
        Button(action: open) {
            picture
                .overlay {
                    if isBusy {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().controlSize(.small).tint(.white)
                    } else if isEnabled, isHovering {
                        Circle().fill(.black.opacity(0.4))
                        Text("Edit")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Not `.disabled` while a change is saved, which would dim the picture under the spinner.
        .allowsHitTesting(isEnabled)
        .background(MenuAnchorView(anchor: anchor))
        .onHoverInFrontWindow { isHovering = $0 }
        .help(isEnabled ? "Change the picture" : "")
        .accessibilityLabel(isEnabled ? "Change picture" : "Picture")
        // The menu's choices, straight from VoiceOver's actions.
        .accessibilityActions {
            if isEnabled {
                if let showLarge { Button("View Picture", action: showLarge) }
                Button("Choose Picture") { pick() }
                if hasPicture { Button("Remove Picture") { remove() } }
            }
        }
    }

    private func open() {
        guard hasPicture, let view = anchor.view else { return pick() }
        let menu = NSMenu()
        if let showLarge {
            menu.addItem(ClosureMenuItem(title: "View Picture", handler: showLarge))
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "Choose Picture…") { pick() })
        menu.addItem(ClosureMenuItem(title: "Remove Picture") { remove() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func pick() {
        guard let url = ImagePicker.choose(message: chooseMessage) else { return }
        choose(url)
    }
}

/// Asks for a picture file. In the Dev build, HUDDLE_DEV_PICK_FILE answers instead, as an open
/// panel can't be driven by a test.
enum ImagePicker {
    @MainActor static func choose(message: String) -> URL? {
        if let path = DevHooks.pickedFile { return URL(fileURLWithPath: path) }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
