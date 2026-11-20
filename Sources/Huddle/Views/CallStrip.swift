import SwiftUI
import WebKit
import Perception

/// A call going on, at the foot of the room list wherever you are in Huddle: who it's with, how
/// it's going, Mute and End. Clicking who it's with goes to its room.
struct CallStrip: View {
    let call: any HuddleCall

    var body: some View { WithPerceptionTracking {
        if let legacy = call as? LegacyCall {
            LegacyCallStrip(call: legacy)
        } else if let session = call as? CallSession {
            ElementCallStrip(session: session)
        }
    } }
}

/// The older kind of one-to-one call: the other person, and how the call between you is going.
private struct LegacyCallStrip: View {
    let call: LegacyCall

    var body: some View { WithPerceptionTracking {
        // Its picture as the room list shows the chat.
        let room = call.account.allRooms.first { $0.id == call.roomID }
        CallStripLayout(call: call, status: status, peerIsMuted: call.peerIsMuted && !call.isEnded,
                        isMuted: call.isMuted, canMute: call.canMute, isEnded: call.isEnded,
                        toggleMute: call.toggleMute) {
            AvatarView(media: call.account.media, url: room?.avatarURL ?? call.peerAvatarURL,
                       name: room?.name ?? call.title, seed: call.roomID, size: 32)
        }
    } }

    private var status: CallStripStatus {
        switch call.state {
        case .starting, .calling: .text("Calling…")
        case .ringing: .text("Ringing…")
        case .connecting: .text("Connecting…")
        case .connected(let since): .connected(since: since, detail: nil)
        case .ended(let ending):
            switch ending {
            case .hungUp, .theyHungUp: .text("Call Ended")
            case .noAnswer: .text("No Answer")
            case .declined: .text("Declined")
            case .missed: .text("Missed Call")
            case .answeredElsewhere: .text("Answered on Another Device")
            case .declinedElsewhere: .text("Declined on Another Device")
            case .couldNotConnect: .failure("Couldn’t connect.")
            case .failed(let message): .failure(message)
            }
        }
    }
}

/// Element Call's call in a room: the room, and how many are in the call there.
private struct ElementCallStrip: View {
    let session: CallSession

    var body: some View { WithPerceptionTracking {
        let room = session.account.allRooms.first { $0.id == session.roomID }
        CallStripLayout(call: session, status: status(in: room), peerIsMuted: false,
                        isMuted: session.isMuted, canMute: session.canMute, isEnded: false,
                        toggleMute: session.toggleMute) {
            AvatarView(media: session.account.media, url: room?.avatarURL, name: room?.name ?? session.title,
                       seed: session.roomID, size: 32)
        }
    } }

    private func status(in room: RoomSummary?) -> CallStripStatus {
        if let failure = session.failure { return .failure(failure) }
        guard let joined = session.joined else { return .text("Joining…") }
        // Who else is there matters in a room; in a chat of two it goes without saying.
        let count = room?.callParticipantCount ?? 0
        return .connected(since: joined, detail: room?.isOneToOne == false && count > 0 ? "\(count) in call" : nil)
    }
}

private enum CallStripStatus {
    case text(String)
    case connected(since: Date, detail: String?)
    case failure(String)

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// The strip itself, whichever kind of call: who, how it's going, Mute and End (or Close, once it
/// has failed).
private struct CallStripLayout<Avatar: View>: View {
    let call: any HuddleCall
    let status: CallStripStatus
    let peerIsMuted: Bool
    let isMuted: Bool
    let canMute: Bool
    let isEnded: Bool
    let toggleMute: () -> Void
    @ViewBuilder let avatar: () -> Avatar

    @Environment(AccountStore.self) private var store

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 10) {
            Button {
                CallCenter.shared.show(call)
            } label: {
                HStack(spacing: 10) {
                    avatar()
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(call.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            if peerIsMuted {
                                Image(systemName: "mic.slash.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("\(call.title) is muted")
                                    .accessibilityLabel("\(call.title) is muted")
                            }
                        }
                        CallStripStatusText(status: status)
                    }
                }
                // All the room the buttons leave, so a long message wraps rather than pushes.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.accounts.count > 1
                  ? "Go to \(call.title), for \(call.account.displayName ?? call.account.userID)"
                  : "Go to \(call.title)")
            if status.isFailure {
                CallStripButton(title: "Close", systemImage: "xmark", style: .normal) { call.hangUp() }
            } else {
                CallStripButton(title: isMuted ? "Unmute" : "Mute",
                                systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                                style: isMuted ? .on : .normal, action: toggleMute)
                    .disabled(!canMute)
                CallStripButton(title: "End Call", systemImage: "phone.down.fill", style: .end) { call.hangUp() }
                    .disabled(isEnded)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Call with \(call.title)")
    } }
}

/// How the call is going: calling, how long it's been on (in green), how it ended, or what went
/// wrong.
private struct CallStripStatusText: View {
    let status: CallStripStatus

    var body: some View { WithPerceptionTracking {
        switch status {
        case .text(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failure(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        case .connected(let since, let detail):
            SwiftUI.TimelineView(.periodic(from: since, by: 1)) { context in WithPerceptionTracking {
                HStack(spacing: 4) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 8))
                    Text(Self.duration(from: since, to: context.date))
                        .monospacedDigit()
                    if let detail {
                        Text("· \(detail)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
            } }
        }
    } }

    private static func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }
}

/// A small round button: Mute (filled in while muted), End Call in red, or Close.
private struct CallStripButton: View {
    enum Style { case normal, on, end }

    let title: String
    let systemImage: String
    let style: Style
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View { WithPerceptionTracking {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(background, in: Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    } }

    private var foreground: Color {
        switch style {
        case .normal: .primary
        case .on: Color(nsColor: .windowBackgroundColor)
        case .end: .white
        }
    }

    private var background: Color {
        switch style {
        case .normal: Color.primary.opacity(0.1)
        case .on: .primary
        case .end: .red
        }
    }
}

/// The calls' web pages, out of sight in Huddle's window: their sound goes through them, and
/// WebKit lets a page use the microphone only while its window can be seen.
struct CallPages: View {
    var body: some View { WithPerceptionTracking {
        ZStack {
            ForEach(CallCenter.shared.calls.compactMap(CallPage.init)) { page in WithPerceptionTracking {
                CallPageView(view: page.view)
            } }
        }
        .frame(width: 1, height: 1)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } }
}

private struct CallPage: Identifiable {
    let id: ObjectIdentifier
    let view: WKWebView

    @MainActor init?(_ call: any HuddleCall) {
        guard let view = call.page else { return nil }
        id = ObjectIdentifier(call)
        self.view = view
    }
}

private struct CallPageView: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> WKWebView { view }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
