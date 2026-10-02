import Foundation
import Testing
@testable import EmailCalendarCore

struct LocalStoreTests {
    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EmailCalendarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cache.sqlite")
    }

    @Test func accountsWithSameGoogleIDsStayIsolatedAcrossReopen() async throws {
        let url = try databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try LocalStore(url: url)
        let alice = SenderRule(accountID: "alice", key: "sender@example.com", decision: .approved)
        let bob = SenderRule(accountID: "bob", key: "sender@example.com", decision: .blocked, filterID: "remote-filter")
        try await first.save(alice, id: alice.key, collection: "senderRules", accountID: "alice")
        try await first.save(bob, id: bob.key, collection: "senderRules", accountID: "bob")
        let reopened = try LocalStore(url: url)
        #expect(try await reopened.load(SenderRule.self, id: alice.key, collection: "senderRules", accountID: "alice") == alice)
        #expect(try await reopened.load(SenderRule.self, id: bob.key, collection: "senderRules", accountID: "bob") == bob)
        try await reopened.remove(id: alice.key, collection: "senderRules", accountID: "alice")
        #expect(try await first.all(SenderRule.self, collection: "senderRules", accountID: "alice").isEmpty)
        #expect(try await first.all(SenderRule.self, collection: "senderRules", accountID: "bob") == [bob])
    }

    @Test func replacementAndHistoryMetadataSurviveRestart() async throws {
        let url = try databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try LocalStore(url: url)
        let due = BubbleRecord(accountID: "owner", threadID: "thread", dueAt: Date(timeIntervalSince1970: 1_900_000_000))
        try await first.save(due, id: due.threadID, collection: "bubbles", accountID: "owner", sortDate: due.dueAt)
        try await first.setMetadata("12345678901234567890", key: "mailHistoryID", accountID: "owner")
        try await first.save([LocalStore.Record(id: "a", value: "first"), .init(id: "b", value: "second")], collection: "cache", accountID: "owner")
        try await first.save([LocalStore.Record(id: "c", value: "replacement")], collection: "cache", accountID: "owner", replacing: true)
        let reopened = try LocalStore(url: url)
        #expect(try await reopened.all(String.self, collection: "cache", accountID: "owner") == ["replacement"])
        #expect(try await reopened.metadata(String.self, key: "mailHistoryID", accountID: "owner") == "12345678901234567890")
        #expect(try await reopened.load(BubbleRecord.self, id: "thread", collection: "bubbles", accountID: "owner") == due)
    }

    @Test func failedBatchReplacementRollsBackPreviousCache() async throws {
        struct SometimesEncodable: Codable, Sendable {
            var fails: Bool
            enum Fault: Error { case expected }
            func encode(to encoder: any Encoder) throws {
                if fails { throw Fault.expected }
                var container = encoder.singleValueContainer()
                try container.encode(false)
            }
            init(fails: Bool) { self.fails = fails }
            init(from decoder: any Decoder) throws { fails = try decoder.singleValueContainer().decode(Bool.self) }
        }
        let url = try databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalStore(url: url)
        try await store.save(SometimesEncodable(fails: false), id: "old", collection: "cache", accountID: "owner")
        do {
            try await store.save([LocalStore.Record(id: "new", value: SometimesEncodable(fails: true))], collection: "cache", accountID: "owner", replacing: true)
            Issue.record("Expected the batch encoder to fail")
        } catch SometimesEncodable.Fault.expected {}
        #expect(try await store.load(SometimesEncodable.self, id: "old", collection: "cache", accountID: "owner") != nil)
        #expect(try await store.load(SometimesEncodable.self, id: "new", collection: "cache", accountID: "owner") == nil)
    }
}
