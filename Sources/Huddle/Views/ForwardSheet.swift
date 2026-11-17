import MatrixRustSDK
import SwiftUI

/// Sends a message on to other rooms: the message at the top, the account's rooms below, each
/// with its own Send button, so it can go to several before the sheet is closed.
struct ForwardSheet: View {
    let account: AccountSession
    let request: ForwardRequest
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var states: [String: SendState] = [:]
    /// The rooms in the order they had when the sheet opened. Sending to one makes it the most
    /// recent, and the list would reorder under the pointer as the user goes down it.
    @State private var order: [String: Int] = [:]
    @FocusState private var isSearching: Bool

    enum SendState: Equatable {
        case sending
        case sent
        case failed(String)
    }

    private var rooms: [RoomSummary] {
        let joined = account.rooms.filter { !$0.isInvite }
            .sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? joined : joined.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var sentCount: Int { states.values.filter { $0 == .sent }.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Forward Message")
                    .font(.headline)
                quote
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Find a room", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearching)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator) }
            }
            .padding(16)
            Divider()
            Group {
                if rooms.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rooms) { room in
                                row(room)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                if sentCount > 0 {
                    Label(sentCount == 1 ? "Sent to 1 room" : "Sent to \(sentCount) rooms", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .animation(.easeOut(duration: 0.2), value: sentCount)
        }
        .frame(width: 420, height: 520)
        .onAppear {
            order = Dictionary(account.rooms.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            isSearching = true
        }
    }

    /// The message being forwarded, as a quote.
    private var quote: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(request.preview.tint)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.preview.senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(request.preview.tint)
                ReplySnippet(reply: request.preview)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func row(_ room: RoomSummary) -> some View {
        HStack(spacing: 10) {
            AvatarView(media: account.media, url: room.avatarURL, name: room.name, seed: room.id, size: 28)
            Text(room.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            switch states[room.id] {
            case nil:
                Button("Send") { send(to: room) }
                    .controlSize(.small)
                    .accessibilityLabel("Send to \(room.name)")
            case .sending:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44)
            case .sent:
                Label("Sent", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            case .failed(let message):
                Button("Try Again") { send(to: room) }
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .help(message)
                    .accessibilityLabel("Try sending to \(room.name) again")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .animation(.easeOut(duration: 0.15), value: states[room.id])
        .accessibilityElement(children: .contain)
    }

    private func send(to room: RoomSummary) {
        states[room.id] = .sending
        Task {
            do {
                try await account.forward(request.content, to: room.id)
                states[room.id] = .sent
            } catch {
                states[room.id] = .failed(error.userMessage)
            }
        }
    }
}
