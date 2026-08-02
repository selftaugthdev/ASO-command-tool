import Foundation
import SQLite3

/// SQLite needs to know whether it may keep a pointer to the bound bytes.
/// Passing a Swift String directly requires the TRANSIENT flag so it copies.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum DatabaseError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not open database: \(message)"
        case .prepare(let message, let sql): return "SQL error: \(message)\n\(sql)"
        case .step(let message): return "SQL execution failed: \(message)"
        }
    }
}

public enum SQLValue: Sendable {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

/// A prepared statement's current row.
public struct Row {
    private let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }

    public func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: cString)
    }

    public func int(_ index: Int32) -> Int64? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(handle, index)
    }

    public func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(handle, index)
    }

    public func date(_ index: Int32) -> Date? {
        int(index).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// Minimal synchronous SQLite wrapper.
///
/// Serialised behind a lock rather than an actor so callers can compose
/// multi-statement transactions without interleaving.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.open(message)
        }
        self.handle = handle
        // WAL keeps the scheduled background refresh from blocking the UI's reads.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 5000;")
    }

    /// An in-memory database, used by tests.
    public convenience init() throws {
        try self.init(path: ":memory:")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw DatabaseError.prepare(message, sql: sql)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw DatabaseError.step(errorMessage)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    public func query<T>(_ sql: String,
                         _ parameters: [SQLValue] = [],
                         map: (Row) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW {
                results.append(map(Row(handle: statement)))
            } else if status == SQLITE_DONE {
                break
            } else {
                throw DatabaseError.step(errorMessage)
            }
        }
        return results
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseError.prepare(errorMessage, sql: sql)
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .int(let value):
                sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}

// Convenience wrappers so call sites read cleanly.
extension SQLValue {
    public static func text(_ value: String?) -> SQLValue {
        value.map { SQLValue.text($0 as String) } ?? .null
    }
    public static func int(_ value: Int?) -> SQLValue {
        value.map { SQLValue.int(Int64($0)) } ?? .null
    }
    public static func double(_ value: Double?) -> SQLValue {
        value.map { SQLValue.double($0 as Double) } ?? .null
    }
    public static func date(_ value: Date?) -> SQLValue {
        value.map { SQLValue.int(Int64($0.timeIntervalSince1970)) } ?? .null
    }
}
