import MatrixRustSDK
import SwiftUI

struct RoomView: View {
    let account: AccountSession
    let roomID: String
    /// What the panel beside the timeline shows, if it is open.
    private var panel: ThreadPanel.Content? {
        get { account.sidePanels[roomID] }
        nonmutating set { account.sidePanels[roomID] = newValue }
    }

    private var summary: RoomSummary? {
        account.rooms.first { $0.id == roomID }
    }

    var body: some View {
        Group {
            if let room = account.room(id: roomID), room.membership() == .invited || summary?.isInvite == true {
                InviteView(account: account, roomID: roomID, name: title)
            } else if let timeline = account.timeline(for: roomID) {
                HStack(spacing: 0) {
                    TimelineView(timeline: timeline, media: account.media) { root in
                        panel = .thread(root)
                    }
                    .frame(minWidth: 320)
                    if let panel {
                        Divider()
                        ThreadPanel(account: account, roomID: roomID, roomName: title, content: panel) {
                            self.panel = $0
                        }
                        .id(roomID)
                        .frame(width: 380)
                        .transition(.move(edge: .trailing))
                    }
                }
                .animation(.smooth(duration: 0.22), value: panel != nil)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            panel = panel == .threadList ? nil : .threadList
                        } label: {
                            Label("Threads", systemImage: "bubble.left.and.text.bubble.right")
                        }
                        .help("Threads in this room")
                    }
                }
            } else {
                ContentUnavailableView("Room Unavailable", systemImage: "questionmark.bubble")
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        summary?.name ?? account.room(id: roomID)?.displayName() ?? "Room"
    }
}

private struct InviteView: View {
    let account: AccountSession
    let roomID: String
    let name: String
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.open")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("You're invited to \(name)")
                .font(.title3.weight(.semibold))
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Decline") { run { try await account.leave(roomID: roomID) } }
                Button("Join") { run { try await account.acceptInvite(roomID: roomID) } }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await work() } catch { self.error = error.userMessage }
        }
    }
}

