import Foundation
import MatrixRustSDK

/// The SDK streams lists (rooms, timeline items) as incremental diffs.
enum VectorDiff<T> {
    case append([T])
    case clear
    case pushFront(T)
    case pushBack(T)
    case popFront
    case popBack
    case insert(Int, T)
    case set(Int, T)
    case remove(Int)
    case truncate(Int)
    case reset([T])

    func mapValues<U>(_ transform: (T) -> U) -> VectorDiff<U> {
        switch self {
        case .append(let values): return .append(values.map(transform))
        case .reset(let values): return .reset(values.map(transform))
        case .clear: return .clear
        case .pushFront(let value): return .pushFront(transform(value))
        case .pushBack(let value): return .pushBack(transform(value))
        case .popFront: return .popFront
        case .popBack: return .popBack
        case .insert(let index, let value): return .insert(index, transform(value))
        case .set(let index, let value): return .set(index, transform(value))
        case .remove(let index): return .remove(index)
        case .truncate(let length): return .truncate(length)
        }
    }

    func map<U>(_ transform: (T) async -> U) async -> VectorDiff<U> {
        switch self {
        case .append(let values):
            var out: [U] = []
            for value in values { out.append(await transform(value)) }
            return .append(out)
        case .reset(let values):
            var out: [U] = []
            for value in values { out.append(await transform(value)) }
            return .reset(out)
        case .clear: return .clear
        case .pushFront(let value): return .pushFront(await transform(value))
        case .pushBack(let value): return .pushBack(await transform(value))
        case .popFront: return .popFront
        case .popBack: return .popBack
        case .insert(let index, let value): return .insert(index, await transform(value))
        case .set(let index, let value): return .set(index, await transform(value))
        case .remove(let index): return .remove(index)
        case .truncate(let length): return .truncate(length)
        }
    }
}

extension Array {
    mutating func apply(_ diff: VectorDiff<Element>) {
        switch diff {
        case .append(let values): append(contentsOf: values)
        case .clear: removeAll()
        case .pushFront(let value): insert(value, at: 0)
        case .pushBack(let value): append(value)
        case .popFront: if !isEmpty { removeFirst() }
        case .popBack: if !isEmpty { removeLast() }
        case .insert(let index, let value): insert(value, at: Swift.min(index, count))
        case .set(let index, let value): if index < count { self[index] = value }
        case .remove(let index): if index < count { remove(at: index) }
        case .truncate(let length): if length < count { removeSubrange(length...) }
        case .reset(let values): self = values
        }
    }
}

extension RoomListEntriesUpdate {
    var diff: VectorDiff<Room> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }
}

extension TimelineDiff {
    var diff: VectorDiff<TimelineItem> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }
}

extension ThreadListUpdate {
    var diff: VectorDiff<ThreadListItem> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }
}

// MARK: - Closure-backed SDK listeners

final class RoomEntriesListener: RoomListEntriesListener, @unchecked Sendable {
    private let handler: ([RoomListEntriesUpdate]) -> Void
    init(_ handler: @escaping ([RoomListEntriesUpdate]) -> Void) { self.handler = handler }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) { handler(roomEntriesUpdate) }
}

final class TimelineDiffListener: TimelineListener, @unchecked Sendable {
    private let handler: ([TimelineDiff]) -> Void
    init(_ handler: @escaping ([TimelineDiff]) -> Void) { self.handler = handler }
    func onUpdate(diff: [TimelineDiff]) { handler(diff) }
}

final class RoomInfoObserver: RoomInfoListener, @unchecked Sendable {
    private let handler: (RoomInfo) -> Void
    init(_ handler: @escaping (RoomInfo) -> Void) { self.handler = handler }
    func call(roomInfo: RoomInfo) { handler(roomInfo) }
}

final class SyncStateListener: SyncServiceStateObserver, @unchecked Sendable {
    private let handler: (SyncServiceState) -> Void
    init(_ handler: @escaping (SyncServiceState) -> Void) { self.handler = handler }
    func onUpdate(state: SyncServiceState) { handler(state) }
}

final class VerificationListener: VerificationStateListener, @unchecked Sendable {
    private let handler: (VerificationState) -> Void
    init(_ handler: @escaping (VerificationState) -> Void) { self.handler = handler }
    func onUpdate(status: VerificationState) { handler(status) }
}

final class RoomListLoadingListener: RoomListLoadingStateListener, @unchecked Sendable {
    private let handler: (RoomListLoadingState) -> Void
    init(_ handler: @escaping (RoomListLoadingState) -> Void) { self.handler = handler }
    func onUpdate(state: RoomListLoadingState) { handler(state) }
}

final class AuthErrorDelegate: ClientDelegate, @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func didReceiveAuthError(isSoftLogout: Bool) { handler() }
    func onBackgroundTaskErrorReport(taskName: String, error: BackgroundTaskFailureReason) {}
}

final class ThreadEntriesListener: ThreadListEntriesListener, @unchecked Sendable {
    private let handler: ([ThreadListUpdate]) -> Void
    init(_ handler: @escaping ([ThreadListUpdate]) -> Void) { self.handler = handler }
    func onUpdate(diff: [ThreadListUpdate]) { handler(diff) }
}

extension SpaceListUpdate {
    var diff: VectorDiff<SpaceRoom> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }
}

extension SpaceFilterUpdate {
    var diff: VectorDiff<SpaceFilter> {
        switch self {
        case .append(let values): .append(values)
        case .clear: .clear
        case .pushFront(let value): .pushFront(value)
        case .pushBack(let value): .pushBack(value)
        case .popFront: .popFront
        case .popBack: .popBack
        case .insert(let index, let value): .insert(Int(index), value)
        case .set(let index, let value): .set(Int(index), value)
        case .remove(let index): .remove(Int(index))
        case .truncate(let length): .truncate(Int(length))
        case .reset(let values): .reset(values)
        }
    }
}

final class SpaceListListener: SpaceServiceJoinedSpacesListener, @unchecked Sendable {
    private let handler: ([SpaceListUpdate]) -> Void
    init(_ handler: @escaping ([SpaceListUpdate]) -> Void) { self.handler = handler }
    func onUpdate(roomUpdates: [SpaceListUpdate]) { handler(roomUpdates) }
}

final class SpaceFiltersListener: SpaceServiceSpaceFiltersListener, @unchecked Sendable {
    private let handler: ([SpaceFilterUpdate]) -> Void
    init(_ handler: @escaping ([SpaceFilterUpdate]) -> Void) { self.handler = handler }
    func onUpdate(filterUpdates: [SpaceFilterUpdate]) { handler(filterUpdates) }
}

final class SpaceRoomsListener: SpaceRoomListEntriesListener, @unchecked Sendable {
    private let handler: ([SpaceListUpdate]) -> Void
    init(_ handler: @escaping ([SpaceListUpdate]) -> Void) { self.handler = handler }
    func onUpdate(rooms: [SpaceListUpdate]) { handler(rooms) }
}

final class SpacePaginationListener: SpaceRoomListPaginationStateListener, @unchecked Sendable {
    private let handler: (SpaceRoomListPaginationState) -> Void
    init(_ handler: @escaping (SpaceRoomListPaginationState) -> Void) { self.handler = handler }
    func onUpdate(paginationState: SpaceRoomListPaginationState) { handler(paginationState) }
}
