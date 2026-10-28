import Foundation

struct DraftRecovery: Codable, Sendable, Equatable {
    static let metadataKey = "draft.recovery"
    var title: String
    var buffer: DraftSession.Buffer
}

/// An email closed while Gmail couldn't be reached. It stays on this Mac until a later refresh saves it to Gmail.
struct ParkedDraft: Codable, Sendable, Equatable {
    static let collection = "parkedDrafts"
    var id: String
    var recovery: DraftRecovery
}

/// Emails closed while Gmail couldn't be reached. Each is stored on this Mac until a later save reaches Gmail,
/// including after a relaunch, and several can wait at once without replacing each other.
@MainActor
final class ParkedDrafts {
    typealias Saver = @MainActor @Sendable (OutgoingMessage) async throws -> OutgoingMessage
    private struct Entry { var accountID: String; var title: String; var session: DraftSession }
    private let store: LocalStore
    private var entries: [String: Entry] = [:]

    init(store: LocalStore) { self.store = store }

    var count: Int { entries.count }
    func contains(_ session: DraftSession) -> Bool { entries.values.contains { $0.session === session } }

    /// Network trouble rather than a problem with the email itself, so saving later can work.
    static func isConnectivityFailure(_ error: any Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? GoogleAPIError else { return false }
        if case .authorization = error { return true }
        return error.statusCode.map { $0 >= 500 || $0 == 429 } ?? false
    }

    /// Stores the email on this Mac; from now on `save` keeps trying to put it in Gmail.
    func park(_ session: DraftSession, id: String, title: String, accountID: String, save: @escaping Saver) async throws {
        guard let buffer = session.recoveryBuffer else { session.cancel(); return }
        try await store.save(ParkedDraft(id: id, recovery: DraftRecovery(title: title, buffer: buffer)),
                             id: id, collection: ParkedDraft.collection, accountID: accountID)
        track(session, id: id, title: title, accountID: accountID, save: save)
    }

    /// After a relaunch or sign-in, stored emails go back to waiting for Gmail.
    func restore(accountID: String, delay: Duration = .seconds(2), save: @escaping Saver) async throws {
        for parked in try await store.all(ParkedDraft.self, collection: ParkedDraft.collection, accountID: accountID)
        where entries[parked.id] == nil {
            track(DraftSession(recovering: parked.recovery.buffer, delay: delay), id: parked.id,
                  title: parked.recovery.title, accountID: accountID, save: save)
        }
    }

    /// Tries every stored email of the account again. Returns those Gmail refused for a reason other than the network.
    func saveAll(accountID: String) async -> [(title: String, error: any Error)] {
        var refused: [(title: String, error: any Error)] = []
        for entry in entries.values where entry.accountID == accountID {
            do { try await entry.session.flush() }
            catch is CancellationError {}
            catch where !Self.isConnectivityFailure(error) { refused.append((entry.title, error)) }
            catch {}
        }
        return refused
    }

    /// Sign-out: stop trying in memory. The stored copies wait for the next sign-in.
    func drop() {
        for entry in entries.values { entry.session.cancel() }
        entries = [:]
    }

    private func track(_ session: DraftSession, id: String, title: String, accountID: String, save: @escaping Saver) {
        entries[id] = Entry(accountID: accountID, title: title, session: session)
        session.configure(save: { [weak self] outgoing in
            let saved = try await save(outgoing)
            // In Gmail now: the copy on this Mac is no longer needed.
            try? await self?.store.remove(id: id, collection: ParkedDraft.collection, accountID: accountID)
            self?.entries[id] = nil
            return saved
        }, send: { _ in throw CancellationError() })
    }
}

@MainActor
enum DraftTermination {
    /// Save a local checkpoint before waiting on the network. A failed Gmail save leaves it for relaunch.
    static func preserve(_ session: DraftSession, title: String, accountID: String, store: LocalStore) async throws {
        if let buffer = session.recoveryBuffer {
            try await store.setMetadata(DraftRecovery(title: title, buffer: buffer), key: DraftRecovery.metadataKey, accountID: accountID)
        }
        do { try await session.finishPendingWork() }
        catch {
            if let buffer = session.recoveryBuffer {
                // An in-flight autosave may have assigned a draft ID since the first checkpoint.
                try await store.setMetadata(DraftRecovery(title: title, buffer: buffer), key: DraftRecovery.metadataKey, accountID: accountID)
                return
            }
        }
        try await store.removeMetadata(key: DraftRecovery.metadataKey, accountID: accountID)
    }
}
