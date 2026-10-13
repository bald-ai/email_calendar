import Foundation
import CSQLite

/// All local state is namespaced by account so reconnecting another account never leaks its cache.
actor LocalStore {
    struct Record<Value: Codable & Sendable>: Sendable {
        var id: String
        var value: Value
        var sortDate: Date? = nil
    }

    struct Snapshot<Value: Sendable>: Sendable {
        var revision: UInt64
        var values: [Value]
    }

    enum StoreError: LocalizedError {
        case database(String)
        var errorDescription: String? {
            switch self { case .database(let message): "Local database: \(message)" }
        }
    }

    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }

    private enum Value {
        case text(String), data(Data), number(Double), null
    }

    private let connection: Connection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private struct CollectionKey: Hashable { var accountID: String; var collection: String }
    private var revisions: [CollectionKey: UInt64] = [:]

    func revision(collection: String, accountID: String) -> UInt64 {
        revisions[CollectionKey(accountID: accountID, collection: collection), default: 0]
    }

    private func changed(collection: String, accountID: String) {
        revisions[CollectionKey(accountID: accountID, collection: collection), default: 0] &+= 1
    }

    init(url: URL? = nil) throws {
        let databaseURL: URL
        if let url {
            databaseURL = url
        } else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            databaseURL = base.appendingPathComponent("EmailCalendar", isDirectory: true).appendingPathComponent("cache.sqlite")
        }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let pointer { sqlite3_close(pointer) }
            throw StoreError.database(message)
        }
        connection = Connection(pointer)
        sqlite3_busy_timeout(pointer, 5_000)
        // Migration executes before this actor is published; no access can race initialization.
        let migration = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS records (
          account_id TEXT NOT NULL,
          collection TEXT NOT NULL,
          id TEXT NOT NULL,
          payload BLOB NOT NULL,
          sort_date REAL,
          PRIMARY KEY (account_id, collection, id)
        );
        CREATE INDEX IF NOT EXISTS records_sort ON records(account_id, collection, sort_date DESC);
        CREATE TABLE IF NOT EXISTS metadata (
          account_id TEXT NOT NULL,
          key TEXT NOT NULL,
          payload BLOB NOT NULL,
          PRIMARY KEY (account_id, key)
        );
        PRAGMA user_version = 1;
        """
        guard sqlite3_exec(pointer, migration, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.database(String(cString: sqlite3_errmsg(pointer)))
        }
    }

    func save<T: Codable & Sendable>(_ value: T, id: String, collection: String, accountID: String, sortDate: Date? = nil) throws {
        try execute("INSERT INTO records(account_id, collection, id, payload, sort_date) VALUES(?,?,?,?,?) ON CONFLICT(account_id, collection, id) DO UPDATE SET payload=excluded.payload, sort_date=excluded.sort_date", [
            .text(accountID), .text(collection), .text(id), .data(try encoder.encode(value)), sortDate.map { .number($0.timeIntervalSince1970) } ?? .null
        ])
        changed(collection: collection, accountID: accountID)
    }

    @discardableResult
    func save<T: Codable & Sendable>(_ records: [Record<T>], collection: String, accountID: String, replacing: Bool = false, removing ids: Set<String> = []) throws -> UInt64 {
        let oldRevision = revision(collection: collection, accountID: accountID)
        try execute("BEGIN IMMEDIATE")
        do {
            if replacing { try removeAll(collection: collection, accountID: accountID) }
            for id in ids { try remove(id: id, collection: collection, accountID: accountID) }
            for record in records {
                try save(record.value, id: record.id, collection: collection, accountID: accountID, sortDate: record.sortDate)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            revisions[CollectionKey(accountID: accountID, collection: collection)] = oldRevision
            throw error
        }
        return revision(collection: collection, accountID: accountID)
    }

    func load<T: Codable & Sendable>(_ type: T.Type, id: String, collection: String, accountID: String) throws -> T? {
        try query("SELECT payload FROM records WHERE account_id=? AND collection=? AND id=?", [.text(accountID), .text(collection), .text(id)]).first.map { try decoder.decode(type, from: $0) }
    }

    func all<T: Codable & Sendable>(_ type: T.Type, collection: String, accountID: String) throws -> [T] {
        try query("SELECT payload FROM records WHERE account_id=? AND collection=? ORDER BY sort_date DESC, id", [.text(accountID), .text(collection)]).map { try decoder.decode(type, from: $0) }
    }

    /// Read the revision and contents in one actor turn, or skip decoding an unchanged collection.
    func snapshot<T: Codable & Sendable>(_ type: T.Type, collection: String, accountID: String,
                                        ifChangedSince previous: UInt64? = nil) throws -> Snapshot<T>? {
        let revision = revision(collection: collection, accountID: accountID)
        guard previous != revision else { return nil }
        return Snapshot(revision: revision, values: try all(type, collection: collection, accountID: accountID))
    }

    func remove(id: String, collection: String, accountID: String) throws {
        try execute("DELETE FROM records WHERE account_id=? AND collection=? AND id=?", [.text(accountID), .text(collection), .text(id)])
        changed(collection: collection, accountID: accountID)
    }

    func removeAll(collection: String, accountID: String) throws {
        try execute("DELETE FROM records WHERE account_id=? AND collection=?", [.text(accountID), .text(collection)])
        changed(collection: collection, accountID: accountID)
    }

    func metadata<T: Codable & Sendable>(_ type: T.Type, key: String, accountID: String) throws -> T? {
        try query("SELECT payload FROM metadata WHERE account_id=? AND key=?", [.text(accountID), .text(key)]).first.map { try decoder.decode(type, from: $0) }
    }

    func setMetadata<T: Codable & Sendable>(_ value: T, key: String, accountID: String) throws {
        try execute("INSERT INTO metadata(account_id,key,payload) VALUES(?,?,?) ON CONFLICT(account_id,key) DO UPDATE SET payload=excluded.payload", [.text(accountID), .text(key), .data(try encoder.encode(value))])
    }

    func removeMetadata(key: String, accountID: String) throws {
        try execute("DELETE FROM metadata WHERE account_id=? AND key=?", [.text(accountID), .text(key)])
    }

    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let result: Int32
                switch value {
                case .text(let string): result = sqlite3_bind_text(statement, index, string, -1, transient)
                case .data(let data):
                    result = data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
                    }
                case .number(let number): result = sqlite3_bind_double(statement, index, number)
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw failure() }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func query(_ sql: String, _ values: [Value]) throws -> [Data] {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var results: [Data] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return results
            case SQLITE_ROW:
                let count = Int(sqlite3_column_bytes(statement, 0))
                if count == 0 { results.append(Data()) }
                else if let pointer = sqlite3_column_blob(statement, 0) { results.append(Data(bytes: pointer, count: count)) }
            default: throw failure()
            }
        }
    }

    private func failure() -> StoreError { .database(String(cString: sqlite3_errmsg(connection.pointer))) }
}
