import Foundation

struct DraftRecovery: Codable, Sendable, Equatable {
    static let metadataKey = "draft.recovery"
    var title: String
    var buffer: DraftSession.Buffer
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
