import Foundation
import MatrixRustSDK

/// Makes the whole history of encrypted rooms searchable. The server can't search those, and
/// the SDK's own background pass stops at about three months, so this goes through each
/// encrypted room back to its very first message, one room at a time and pausing between
/// pages. Everything loaded goes into this Mac's search index on its way through the SDK's
/// event cache. Rooms that reach their start are remembered, so a later launch carries on
/// with the rest. If the server doesn't search messages itself, unencrypted rooms get the
/// same treatment afterwards.
@MainActor @Observable
final class HistoryIndexer {
    /// Settings ▸ Privacy can turn it off; on unless it has been.
    static let defaultsKey = "indexFullHistory"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private(set) var isRunning = false
    /// Rooms whose whole history is indexed, of those being gone through.
    private(set) var roomsDone = 0
    private(set) var roomsTotal = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var account: AccountSession?

    /// Rooms are gone through this many messages at a time, with this long between pages.
    private static let pageSize: UInt16 = 100
    private static let pause = Duration.milliseconds(DevHooks.indexPauseMilliseconds ?? 300)

    func start(for account: AccountSession) {
        self.account = account
        guard task == nil, Self.isEnabled else { return }
        task = Task { [weak self] in
            // After the SDK's own first pass over recent weeks has had a head start.
            try? await Task.sleep(for: .seconds(15))
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private var completedKey: String? { account.map { "indexedHistory.\($0.id)" } }

    private var completed: Set<String> {
        get { Set(completedKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []) }
        set { if let completedKey { UserDefaults.standard.set(Array(newValue), forKey: completedKey) } }
    }

    private func run() async {
        defer {
            isRunning = false
            task = nil
        }
        guard let account else { return }
        let encrypted = await rooms(of: account, encrypted: true)
        await index(encrypted)
        guard !Task.isCancelled, Self.isEnabled else { return }
        // Where the server can't search unencrypted rooms either, this Mac has to.
        if await !ServerSearch(client: account.client).isSupported() {
            await index(await rooms(of: account, encrypted: false))
        }
    }

    /// The account's rooms, most recently active first, encrypted or not.
    private func rooms(of account: AccountSession, encrypted: Bool) async -> [String] {
        var result: [String] = []
        for summary in account.allRooms where !summary.isInvite && !summary.isSpace {
            guard let room = account.room(id: summary.id) else { continue }
            var state = room.encryptionState()
            if state == .unknown { state = (try? await room.latestEncryptionState()) ?? .unknown }
            if (state == .encrypted) == encrypted { result.append(summary.id) }
        }
        return result
    }

    private func index(_ roomIDs: [String]) async {
        var completed = completed
        roomsTotal = roomIDs.count
        roomsDone = roomIDs.filter(completed.contains).count
        isRunning = roomsDone < roomsTotal
        for roomID in roomIDs where !completed.contains(roomID) {
            guard !Task.isCancelled, Self.isEnabled else { return }
            if await indexWholeHistory(of: roomID) {
                #if DEBUG
                print("DEV_HISTORY_INDEXED \(account?.userID ?? "") \(roomID)")
                fflush(stdout)
                #endif
                completed.insert(roomID)
                self.completed = completed
                roomsDone += 1
            }
            // A breath between rooms too, as between pages.
            try? await Task.sleep(for: Self.pause)
        }
        isRunning = false
    }

    /// Pages back through a room to its first message. False if it stopped short (an error,
    /// or turned off), to be carried on with next time.
    private func indexWholeHistory(of roomID: String) async -> Bool {
        guard let room = account?.room(id: roomID),
              let timeline = try? await room.timeline() else { return false }
        while !Task.isCancelled, Self.isEnabled {
            // Waits out a lost connection rather than counting it as the end.
            while account?.syncState != .running {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return false }
            }
            do {
                if try await timeline.paginateBackwards(numEvents: Self.pageSize) { return true }
            } catch {
                return false
            }
            try? await Task.sleep(for: Self.pause)
        }
        return false
    }
}
