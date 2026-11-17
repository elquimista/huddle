import MatrixRustSDK
import SwiftUI

struct RoomListView: View {
    @Bindable var account: AccountSession
    @State private var showsRecovery = false

    var body: some View {
        List(selection: $account.selectedRoomID) {
            ForEach(account.rooms) { room in
                RoomRow(room: room, media: account.media, reaction: account.reactionPreviews[room.id],
                        presence: room.directUserID.flatMap { account.presence.people[$0] })
                    .tag(room.id)
                    .onAppear {
                        account.roomBecameVisible(room.id)
                        if room.id == account.rooms.last?.id { account.loadMoreRooms() }
                    }
                    .onDisappear { account.roomBecameHidden(room.id) }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $account.searchText, placement: .sidebar, prompt: "Search rooms")
        .overlay {
            if account.rooms.isEmpty {
                if !account.searchText.isEmpty {
                    ContentUnavailableView.search(text: account.searchText)
                } else if account.hasLoadedRooms {
                    ContentUnavailableView("No Rooms Yet",
                                           systemImage: "tray",
                                           description: Text("Invitations and rooms you join will appear here."))
                } else if account.syncState == .running || account.syncState == .idle {
                    ProgressView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if account.verification == .unverified {
                    Banner(icon: "lock.trianglebadge.exclamationmark",
                           text: "Verify this session to read encrypted history",
                           action: "Verify") { showsRecovery = true }
                }
                if let status {
                    Banner(icon: "exclamationmark.triangle", text: status, action: nil) {}
                }
            }
        }
        .navigationTitle(account.displayName ?? account.userID)
        .sheet(isPresented: $showsRecovery) {
            RecoverySheet(account: account)
        }
    }

    private var status: String? {
        if account.needsReauth { return "Session expired. Sign out and back in." }
        if let error = account.startError { return error }
        switch account.syncState {
        case .offline: return "Offline. Reconnecting…"
        case .error, .terminated: return "Connection lost. Reconnecting…"
        default: return nil
        }
    }
}

private struct RoomRow: View {
    let room: RoomSummary
    let media: MediaLoader
    var reaction: ReactionPreview?
    /// The other person's, in a direct chat.
    var presence: PresenceInfo?

    /// The reaction, when it is more recent than the room's newest message.
    private var latestReaction: ReactionPreview? {
        guard let reaction, !room.isInvite, reaction.date > (room.timestamp ?? .distantPast) else { return nil }
        return reaction
    }

    private var preview: String {
        if room.isInvite { return room.lastMessage ?? "Invitation" }
        return latestReaction?.text ?? room.lastMessage ?? " "
    }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(media: media, url: room.avatarURL, name: room.name, seed: room.id, size: 36)
                .presenceDot(presence, avatarSize: 36)
                .help(presence?.description ?? "")
                .accessibilityValue(presence?.description ?? "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(room.name)
                        .fontWeight(room.hasUnread || room.isHighlighted ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let timestamp = latestReaction?.date ?? room.timestamp {
                        Text(timestamp.roomListLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .center) {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    badge
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var badge: some View {
        if room.isInvite {
            pill(Text("Invite"), color: .red, padding: 6)
        } else if room.mentions > 0 {
            pill(Text("@"), color: .red)
        } else if room.notifications > 0 {
            pill(Text("\(min(room.notifications, 99))"), color: room.isUrgent ? .red : .accentColor)
        } else if room.hasUnread {
            Circle()
                .fill(.tertiary)
                .frame(width: 8, height: 8)
                .frame(width: Self.badgeWidth)
        }
    }

    /// Every badge is at least this wide, so they line up down the list's right edge.
    private static let badgeWidth: CGFloat = 20

    private func pill(_ text: Text, color: Color, padding: CGFloat = 4) -> some View {
        text
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, padding)
            .frame(minWidth: Self.badgeWidth, minHeight: 18)
            .background(color, in: Capsule())
    }
}

private struct Banner: View {
    let icon: String
    let text: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action, action: perform)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
    }
}

/// Verifies the session by entering the account's recovery key.
private struct RecoverySheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify This Session")
                .font(.headline)
            Text("Enter your recovery key to unlock encrypted message history and mark this device as trusted.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Recovery key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Verify", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || isBusy)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        guard !key.isEmpty, !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await account.recover(with: key.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                self.error = error.userMessage
            }
        }
    }
}

extension Date {
    var roomListLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
