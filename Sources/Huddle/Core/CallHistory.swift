import Foundation
import MatrixRustSDK

/// One event of a one-to-one call of Matrix's own kind (m.call.*): its invite, answer, decline
/// or end. The invite gets a line in the conversation saying how the call went; the rest aren't
/// shown themselves (the SDK passes them on for this, patched: Scripts/sdk-patches).
struct CallEvent {
    enum Kind { case invite, answer, reject, hangup }

    let kind: Kind
    let callID: String?
    let sender: String
    let date: Date
    /// Why a call was ended: `invite_timeout` when nobody answered, `user_hangup`, and so on.
    let reason: String?
    /// How long an invite rings, as its sender set it.
    let lifetime: TimeInterval?

    /// The kind of call event an item is, if it is one.
    static func kind(of content: TimelineItemContent) -> Kind? {
        switch content {
        case .callInvite:
            return .invite
        case .msgLike(let content):
            guard case .other(let type) = content.kind else { return nil }
            switch type {
            case .callAnswer: return .answer
            case .callReject: return .reject
            case .callHangup: return .hangup
            default: return nil
            }
        default:
            return nil
        }
    }

    /// From the item's event as it came (decrypted, in an encrypted room): the timeline item
    /// itself doesn't carry the call's ID.
    init(kind: Kind, event: EventTimelineItem) {
        self.kind = kind
        sender = event.sender
        date = Date(matrixTimestamp: event.timestamp)
        let json = event.lazyProvider.debugInfo().originalJson
        let object = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let content = object?["content"] as? [String: Any]
        callID = content?["call_id"] as? String
        reason = content?["reason"] as? String
        lifetime = (content?["lifetime"] as? NSNumber).map { $0.doubleValue / 1000 }
    }
}

/// How a call went, from the events that followed its invite.
struct CallOutcome {
    var answered: Date?
    var declinedBy: String?
    var ended: CallEvent?
}

enum CallHistory {
    /// Each call's answer, decline and end, by call ID: the first of each.
    static func outcomes(of events: [CallEvent]) -> [String: CallOutcome] {
        var outcomes: [String: CallOutcome] = [:]
        for event in events where event.kind != .invite {
            guard let id = event.callID else { continue }
            var outcome = outcomes[id] ?? CallOutcome()
            switch event.kind {
            case .answer: if outcome.answered == nil { outcome.answered = event.date }
            case .reject: if outcome.declinedBy == nil { outcome.declinedBy = event.sender }
            case .hangup: if outcome.ended == nil { outcome.ended = event }
            case .invite: break
            }
            outcomes[id] = outcome
        }
        return outcomes
    }

    /// The line for a call's invite: who called, and how it went ("You called · No answer",
    /// "Bob called · 1 min, 23 sec", "Bob called · Missed").
    static func line(for invite: CallEvent, outcome: CallOutcome?, callerName: String, isOwn: Bool,
                     ownUserID: String, now: Date = .now) -> String {
        let called = "\(isOwn ? "You" : callerName) called"
        func declined(by userID: String) -> String {
            isOwn || userID != ownUserID ? "\(called) · Declined" : "\(called) · You declined"
        }
        if let answered = outcome?.answered {
            guard let ended = outcome?.ended, ended.date >= answered else { return called }
            return "\(called) · \(duration(ended.date.timeIntervalSince(answered)))"
        }
        if let declinedBy = outcome?.declinedBy { return declined(by: declinedBy) }
        if let ended = outcome?.ended {
            // Ended by the one called, unanswered: declined, as older clients decline.
            if ended.sender != invite.sender { return declined(by: ended.sender) }
            if !isOwn { return "\(called) · Missed" }
            return "\(called) · \(ended.reason == "invite_timeout" ? "No answer" : "Cancelled")"
        }
        // Nothing yet: still ringing, or it rang out with nobody saying so.
        if now < invite.date.addingTimeInterval(invite.lifetime ?? 60) {
            return isOwn ? "You’re calling" : "\(callerName) is calling"
        }
        return isOwn ? "\(called) · No answer" : "\(called) · Missed"
    }

    /// The line for an Element Call call's start, from what the SDK knows of it: declined, in
    /// progress (the newest call only), or over.
    static func line(callerName: String, isOwn: Bool, isOneToOne: Bool, declinedBy: [String],
                     activeMembers: [String], ownUserID: String) -> String {
        let who = isOwn ? "You" : callerName
        let started = isOneToOne ? "\(who) called" : "\(who) started a call"
        if !declinedBy.isEmpty {
            return isOwn || !declinedBy.contains(ownUserID) ? "\(started) · Declined" : "\(started) · You declined"
        }
        return activeMembers.isEmpty ? "\(started) · Ended" : "\(started) · In progress"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
