import AppKit
import MatrixRustSDK
import Observation
import SwiftUI
import WebKit

/// The calls going on, shown at the foot of the room list (`CallStrip`) with their pages out of
/// sight in Huddle's window (`CallPages`), and one ringing in, in a panel of its own.
@MainActor @Observable
final class CallCenter {
    static let shared = CallCenter()

    /// The calls going on, the newest last: one at a time, except in Dev with
    /// HUDDLE_DEV_CALL_PER_ACCOUNT, where two accounts can call each other in the one app.
    private(set) var calls: [any HuddleCall] = []
    private(set) var incoming: IncomingCall?

    @ObservationIgnored private var incomingPanel: NSPanel?
    @ObservationIgnored private var ringTask: Task<Void, Never>?
    @ObservationIgnored private var declineHandle: TaskHandle?
    /// Rooms a call is being placed in, while it's worked out which kind.
    @ObservationIgnored private var placing: Set<String> = []
    /// Whether each account's server runs Element Call's backend, and when that was found out.
    @ObservationIgnored private var matrixRTCSupport: [ObjectIdentifier: (supported: Bool, checked: Date)] = [:]

    var current: (any HuddleCall)? { calls.last }

    private func call(for account: AccountSession, roomID: String) -> (any HuddleCall)? {
        calls.first { $0.account === account && $0.roomID == roomID }
    }

    /// Whether a call is going on in this room, here.
    func isInCall(account: AccountSession, roomID: String) -> Bool {
        call(for: account, roomID: roomID) != nil
    }

    /// Starts a call in a room, or joins the one going on there: a voice call in a direct chat
    /// rings the other person. One call at a time: another going on is left first.
    ///
    /// With just two people in the room and no call going on there, it's the older kind of
    /// one-to-one call when Element Call can't be had: the server doesn't run its backend, or the
    /// room doesn't let members join calls. Element Web makes that kind in a direct chat too.
    func call(account: AccountSession, roomID: String, title: String, voiceOnly: Bool = true) {
        if let existing = call(for: account, roomID: roomID) { return show(existing) }
        let key = "\(account.id)|\(roomID)"
        guard placing.insert(key).inserted else { return }
        Task {
            let legacy = await usesLegacyCall(account: account, roomID: roomID)
            placing.remove(key)
            guard call(for: account, roomID: roomID) == nil else { return }
            leaveOtherCalls(for: account)
            if incoming?.roomID == roomID { dismissIncoming() }
            if legacy {
                let summary = account.allRooms.first { $0.id == roomID }
                let call = LegacyCall(calling: account, roomID: roomID, title: title,
                                      peerID: summary?.directUserID, peerAvatarURL: summary?.avatarURL)
                add(call)
                Task { await call.start() }
            } else {
                let session = CallSession(account: account, roomID: roomID, title: title, isVoiceOnly: voiceOnly)
                add(session)
                Task { await session.start() }
            }
        }
    }

    private func leaveOtherCalls(for account: AccountSession) {
        for other in calls where !(DevHooks.callPerAccount && other.account !== account) {
            other.hangUp()
        }
    }

    private func add(_ call: any HuddleCall) {
        call.onEnded = { [weak self, weak call] in
            guard let self, let call else { return }
            self.ended(call)
        }
        calls.append(call)
    }

    private func usesLegacyCall(account: AccountSession, roomID: String) async -> Bool {
        guard let room = account.room(id: roomID),
              account.allRooms.first(where: { $0.id == roomID })?.isOneToOne == true,
              !room.hasActiveRoomCall() else { return false }
        if DevHooks.legacyCalls { return true }
        if let levels = try? await room.getPowerLevels(), !levels.canOwnUserSendState(stateEvent: .callMember) {
            return true
        }
        return !(await supportsMatrixRTC(account))
    }

    private func supportsMatrixRTC(_ account: AccountSession) async -> Bool {
        let key = ObjectIdentifier(account)
        if let known = matrixRTCSupport[key], known.checked.timeIntervalSinceNow > -600 { return known.supported }
        // Not found out (offline, say): the older kind, which needs nothing more than messages do.
        guard let supported = try? await account.client.isLivekitRtcSupported() else { return false }
        matrixRTCSupport[key] = (supported, .now)
        return supported
    }

    /// Leaves this room's call.
    func hangUp(account: AccountSession, roomID: String) {
        call(for: account, roomID: roomID)?.hangUp()
    }

    /// Goes to a call's room, in Huddle's window, brought forward.
    func show(_ call: any HuddleCall) {
        show(account: call.account, roomID: call.roomID)
    }

    private func show(account: AccountSession, roomID: String) {
        Notifier.shared.show(accountID: account.id, roomID: roomID, thread: nil)
        guard !DevHooks.assumesActive else { return }
        MainWindow.show()
        // In sight even if Huddle can't be brought forward (answered from the ring panel with
        // another app in front): WebKit lets the call's page have the microphone only then.
        MainWindow.window?.orderFrontRegardless()
        NSApp.activate()
    }

    /// Leaves every call, as the app quits: Element Call's leave goes out if it can in a moment,
    /// and the leave the server holds for a client that goes away covers the rest.
    func hangUpAll() {
        for session in calls { session.hangUp() }
    }

    private func ended(_ call: any HuddleCall) {
        calls.removeAll { $0 === call }
        if let legacy = call as? LegacyCall, incoming?.legacy === legacy { dismissIncoming() }
    }

    // MARK: Ringing

    /// Someone else rings this account in a room: a panel to answer or decline, and a ring, until
    /// one of those, the ring running out, or the caller giving up.
    func ring(_ call: IncomingCall) {
        guard !isInCall(account: call.account, roomID: call.roomID), incoming?.eventID != call.eventID else {
            call.legacy?.abandon()
            return
        }
        dismissIncoming()
        incoming = call
        showIncomingPanel(for: call)
        let room = call.account.room(id: call.roomID)
        let ownID = call.account.userID
        if let legacy = call.legacy {
            legacy.onEnded = { [weak self, weak legacy] in
                guard let self, let legacy else { return }
                // The caller gave up, or it rang out, before anyone answered: a missed call.
                if self.incoming?.legacy === legacy, legacy.state == .ended(.missed) {
                    Notifier.shared.announceMissedCall(call)
                }
                self.ended(legacy)
            }
            legacy.startRinging()
        } else {
            // Declined on another of this account's devices: no more ringing here.
            declineHandle = try? room?.subscribeToCallDeclineEvents(
                rtcNotificationEventId: call.eventID,
                listener: CallDeclineObserver { [weak self] decliner in
                    guard decliner == ownID else { return }
                    Task { @MainActor in
                        if self?.incoming?.eventID == call.eventID { self?.dismissIncoming() }
                    }
                })
        }
        ringTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled, Date() < call.expires {
                // The first look is skipped, the call being just begun. After that: once the room
                // has no call any more, the caller has given up; once this account is in it, it
                // was answered on another device. (The older kind of call says so itself.)
                if let legacy = call.legacy {
                    if !legacy.isRinging { break }
                } else if !first, let room {
                    if !room.hasActiveRoomCall() || room.activeRoomCallParticipants().contains(ownID) { break }
                }
                first = false
                if !DevHooks.mutesAudio { NSSound(named: "Submarine")?.play() }
                try? await Task.sleep(for: .seconds(2.5))
            }
            guard !Task.isCancelled, let self else { return }
            // Rung out, or given up on, with no answer here or on another device: a missed call.
            let missed = if let legacy = call.legacy {
                legacy.isRinging
            } else {
                !(room?.activeRoomCallParticipants().contains(ownID) ?? false)
            }
            self.dismissIncoming()
            if missed { Notifier.shared.announceMissedCall(call) }
        }
    }

    /// The older kind of call ringing in, from its invite event. False if it can't ring: it has
    /// run out, or isn't for this account.
    @discardableResult
    func ringLegacy(invite raw: String, account: AccountSession, roomID: String, callerName: String,
                    callerAvatarURL: String?, callerID: String, roomName: String?) -> Bool {
        guard let legacy = LegacyCall(invite: raw, account: account, roomID: roomID, title: roomName ?? callerName,
                                      callerID: callerID, callerAvatarURL: callerAvatarURL),
              let eventID = legacy.inviteEventID else { return false }
        ring(IncomingCall(account: account, roomID: roomID, eventID: eventID, callerName: callerName,
                          callerAvatarURL: callerAvatarURL, callerID: callerID, roomName: roomName,
                          isVoice: !legacy.offersVideo, expires: legacy.expires, legacy: legacy))
        return true
    }

    func answer(_ call: IncomingCall) {
        dismissIncoming(keepingCall: true)
        if let legacy = call.legacy {
            guard legacy.isRinging else { return }
            leaveOtherCalls(for: call.account)
            add(legacy)
            show(legacy)
            legacy.answer()
        } else {
            show(account: call.account, roomID: call.roomID)
            self.call(account: call.account, roomID: call.roomID, title: call.title, voiceOnly: call.isVoice)
        }
    }

    func decline(_ call: IncomingCall) {
        dismissIncoming(keepingCall: true)
        if let legacy = call.legacy {
            legacy.reject()
            return
        }
        guard let room = call.account.room(id: call.roomID) else { return }
        Task { try? await room.declineCall(rtcNotificationEventId: call.eventID) }
    }

    /// Takes the ringing panel down. An older-kind call left ringing there stops listening, saying
    /// nothing, unless it's being answered or declined.
    func dismissIncoming(keepingCall: Bool = false) {
        ringTask?.cancel()
        ringTask = nil
        declineHandle?.cancel()
        declineHandle = nil
        let legacy = incoming?.legacy
        incoming = nil
        incomingPanel?.close()
        incomingPanel = nil
        if !keepingCall { legacy?.abandon() }
    }

    private func showIncomingPanel(for call: IncomingCall) {
        let content = NSHostingView(rootView: IncomingCallView(call: call, center: self))
        let size = content.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        // Its rounded, translucent card is drawn by its content; the window itself is clear.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        // At the top right of the screen, where notifications appear.
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - panel.frame.height - 16))
        }
        if DevHooks.assumesActive { panel.orderBack(nil) } else { panel.orderFrontRegardless() }
        incomingPanel = panel
    }
}

/// Hears a ring declined, on any device of anyone rung.
private final class CallDeclineObserver: CallDeclineListener, @unchecked Sendable {
    private let onDecline: (String) -> Void

    init(_ onDecline: @escaping (String) -> Void) {
        self.onDecline = onDecline
    }

    func call(declinerUserId: String) {
        onDecline(declinerUserId)
    }
}

/// A call ringing in.
struct IncomingCall: Equatable {
    let account: AccountSession
    let roomID: String
    /// The ring's event, which declining answers.
    let eventID: String
    let callerName: String
    let callerAvatarURL: String?
    let callerID: String
    /// The room's name where it isn't a direct chat.
    let roomName: String?
    let isVoice: Bool
    let expires: Date
    /// The older kind of one-to-one call, which listens for its own events while it rings.
    var legacy: LegacyCall? = nil

    var title: String { roomName ?? callerName }

    static func == (lhs: IncomingCall, rhs: IncomingCall) -> Bool { lhs.eventID == rhs.eventID }
}

/// Who is calling, with Decline and Answer.
private struct IncomingCallView: View {
    let call: IncomingCall
    let center: CallCenter

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(media: call.account.media, url: call.callerAvatarURL, name: call.callerName,
                       seed: call.callerID, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.callerName)
                    .font(.headline)
                    .lineLimit(1)
                Text(call.roomName.map { "Calling in \($0)" } ?? (call.isVoice ? "Voice call" : "Call"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                center.decline(call)
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.red, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Decline")
            .accessibilityLabel("Decline")
            Button {
                center.answer(call)
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.green, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Answer")
            .accessibilityLabel("Answer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340)
        // A rounded, translucent card, as macOS's own notifications are.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Call from \(call.callerName)")
    }
}
