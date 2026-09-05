import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteConnectionError: Error, LocalizedError {
    case openFailed(path: String, message: String)
    case executeFailed(sql: String, message: String)
    case prepareFailed(sql: String, message: String)
    case bindFailed(message: String)
    case stepFailed(message: String)
    case closed

    public var errorDescription: String? {
        switch self {
        case let .openFailed(path, message):
            return "SQLite open failed for \(path): \(message)"
        case let .executeFailed(sql, message):
            return "SQLite execute failed: \(message) SQL: \(sql)"
        case let .prepareFailed(sql, message):
            return "SQLite prepare failed: \(message) SQL: \(sql)"
        case let .bindFailed(message):
            return "SQLite bind failed: \(message)"
        case let .stepFailed(message):
            return "SQLite step failed: \(message)"
        case .closed:
            return "SQLite connection is closed."
        }
    }
}

enum SQLiteBinding {
    case null
    case int(Int)
    case int64(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case bool(Bool)
}

public final class SQLiteConnection: @unchecked Sendable {
    public let url: URL
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var transactionDepth = 0

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteConnectionError.openFailed(path: url.path, message: message)
        }
        handle = database

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=5000")
        try execute("PRAGMA synchronous=NORMAL")
    }

    deinit {
        close()
    }

    public func close() {
        lock.withLock {
            if let handle {
                sqlite3_close(handle)
                self.handle = nil
            }
        }
    }

    func execute(_ sql: String) throws {
        try lock.withLock {
            guard let handle else {
                throw SQLiteConnectionError.closed
            }
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
            guard result == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
                if let errorMessage {
                    sqlite3_free(errorMessage)
                }
                throw SQLiteConnectionError.executeFailed(sql: sql, message: message)
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if transactionDepth > 0 {
                transactionDepth += 1
                defer { transactionDepth -= 1 }
                return try body()
            }

            try execute("BEGIN IMMEDIATE")
            transactionDepth = 1
            do {
                let value = try body()
                transactionDepth = 0
                try execute("COMMIT")
                return value
            } catch {
                transactionDepth = 0
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    func withStatement<T>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        _ body: (SQLiteStatement) throws -> T
    ) throws -> T {
        try lock.withLock {
            let statement = try prepare(sql)
            defer { statement.finalize() }
            try statement.bind(bindings)
            return try body(statement)
        }
    }

    func firstString(_ sql: String, bindings: [SQLiteBinding] = []) throws -> String? {
        try withStatement(sql, bindings: bindings) { statement in
            guard try statement.step() else {
                return nil
            }
            return statement.columnString(0)
        }
    }

    func firstInt(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Int? {
        try withStatement(sql, bindings: bindings) { statement in
            guard try statement.step() else {
                return nil
            }
            return statement.columnInt(0)
        }
    }

    func firstDouble(_ sql: String, bindings: [SQLiteBinding] = []) throws -> Double? {
        try withStatement(sql, bindings: bindings) { statement in
            guard try statement.step() else {
                return nil
            }
            return statement.columnDouble(0)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try lock.withLock {
            guard let handle else {
                throw SQLiteConnectionError.closed
            }
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard result == SQLITE_OK, let statement else {
                throw SQLiteConnectionError.prepareFailed(sql: sql, message: lastErrorMessage)
            }
            return SQLiteStatement(connection: self, statement: statement)
        }
    }

    var lastErrorMessage: String {
        lock.withLock {
            guard let handle else {
                return "closed"
            }
            return String(cString: sqlite3_errmsg(handle))
        }
    }
}

final class SQLiteStatement {
    private unowned let connection: SQLiteConnection
    private var statement: OpaquePointer?

    init(connection: SQLiteConnection, statement: OpaquePointer) {
        self.connection = connection
        self.statement = statement
    }

    deinit {
        finalize()
    }

    func finalize() {
        if let statement {
            sqlite3_finalize(statement)
            self.statement = nil
        }
    }

    func bind(_ bindings: [SQLiteBinding]) throws {
        for (index, binding) in bindings.enumerated() {
            try bind(binding, at: Int32(index + 1))
        }
    }

    func step() throws -> Bool {
        guard let statement else {
            throw SQLiteConnectionError.closed
        }
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteConnectionError.stepFailed(message: connection.lastErrorMessage)
        }
    }

    func columnString(_ index: Int32) -> String? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    func columnInt(_ index: Int32) -> Int {
        guard let statement else {
            return 0
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    func columnInt64(_ index: Int32) -> Int64 {
        guard let statement else {
            return 0
        }
        return sqlite3_column_int64(statement, index)
    }

    func columnDouble(_ index: Int32) -> Double {
        guard let statement else {
            return 0
        }
        return sqlite3_column_double(statement, index)
    }

    func columnBool(_ index: Int32) -> Bool {
        columnInt(index) != 0
    }

    func columnData(_ index: Int32) -> Data? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0 else {
            return Data()
        }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private func bind(_ binding: SQLiteBinding, at index: Int32) throws {
        guard let statement else {
            throw SQLiteConnectionError.closed
        }

        let result: Int32
        switch binding {
        case .null:
            result = sqlite3_bind_null(statement, index)
        case let .int(value):
            result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case let .int64(value):
            result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        case let .double(value):
            result = sqlite3_bind_double(statement, index, value)
        case let .string(value):
            result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        case let .data(value):
            result = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), sqliteTransient)
            }
        case let .bool(value):
            result = sqlite3_bind_int(statement, index, value ? 1 : 0)
        }

        guard result == SQLITE_OK else {
            throw SQLiteConnectionError.bindFailed(message: connection.lastErrorMessage)
        }
    }
}
