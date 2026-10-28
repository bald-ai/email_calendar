import Foundation
import Observation

@MainActor @Observable
final class ProposalAddState {
    private(set) var pending: Set<UUID> = []
    func begin(_ id: UUID) -> Bool { pending.insert(id).inserted }
    func finish(_ id: UUID) { pending.remove(id) }
}
