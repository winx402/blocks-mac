import Foundation
import SQLite3
import Darwin

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteConnectionError: Error, LocalizedError {
    case openFailed(path: String, message: String)
    case executeFailed(sql: String, message: String)
    case prepareFailed(sql: String, message: String)
    case bindFailed(message: String)
    case stepFailed(message: String)
    case closed
    case backupFailed(String)
    case suspendedForApplicationUpdate

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
        case let .backupFailed(message):
            return "SQLite backup failed: \(message)"
        case .suspendedForApplicationUpdate:
            return "Database operations are paused while the application prepares to update."
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
    private final class WeakConnection {
        weak var value: SQLiteConnection?
        init(_ value: SQLiteConnection) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var registry: [WeakConnection] = []
    private static var openingSuspended = false
    private static var fencedConnections: [SQLiteConnection] = []
    private static var updateBackupURLs: [URL] = []
    public let url: URL
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var transactionDepth = 0
    private var updateSuspended = false

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        Self.registryLock.lock()
        defer { Self.registryLock.unlock() }
        guard !Self.openingSuspended else { throw SQLiteConnectionError.suspendedForApplicationUpdate }
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteConnectionError.openFailed(path: url.path, message: message)
        }
        handle = database

        try execute("PRAGMA busy_timeout=5000")
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA synchronous=NORMAL")
        }
        Self.registry.removeAll { $0.value == nil }
        Self.registry.append(WeakConnection(self))
    }

    deinit {
        close()
    }

    public func close() {
        lock.withLock {
            if let handle {
                // A live statement must not make us forget an unclosed handle.
                // close_v2 defers physical closure until outstanding statements
                // finish, rather than silently leaking a SQLITE_BUSY handle.
                if sqlite3_close_v2(handle) == SQLITE_OK {
                    self.handle = nil
                }
            }
        }
    }

    /// Call only after every business producer has closed admission and drained.
    /// This is the final storage barrier, not a substitute for producer drains.
    /// It closes admission on every live connection before taking snapshots.
    public static func prepareForApplicationUpdate(createBackups: Bool = true) throws -> [URL] {
        let connections: [SQLiteConnection] = try registryLock.withLock {
            guard !openingSuspended else { throw SQLiteConnectionError.suspendedForApplicationUpdate }
            openingSuspended = true
            return registry.compactMap(\.value)
        }
        do {
            var live: [SQLiteConnection] = []
            for connection in connections {
                connection.lock.withLock {
                    if connection.handle != nil {
                        connection.updateSuspended = true
                        live.append(connection)
                    }
                }
            }
            var paths: Set<String> = []
            var backups: [URL] = []
            for connection in live where createBackups && paths.insert(connection.url.standardizedFileURL.path).inserted {
                let directory = connection.url.deletingLastPathComponent()
                    .appendingPathComponent("UpdateBackups", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let destination = directory.appendingPathComponent(connection.url.lastPathComponent)
                try connection.backup(to: destination)
                backups.append(destination)
            }
            registryLock.withLock {
                fencedConnections = live
                updateBackupURLs = backups
            }
            return backups
        } catch {
            for connection in connections { connection.lock.withLock { connection.updateSuspended = false } }
            registryLock.withLock { openingSuspended = false }
            throw error
        }
    }

    public static func resumeAfterCancelledApplicationUpdate() {
        let connections = registryLock.withLock { fencedConnections }
        for connection in connections { connection.lock.withLock { connection.updateSuspended = false } }
        registryLock.withLock {
            fencedConnections.removeAll()
            updateBackupURLs.removeAll()
            openingSuspended = false
        }
    }

    public static func closePreparedApplicationConnections() {
        let connections = registryLock.withLock { fencedConnections }
        for connection in connections { connection.close() }
        registryLock.withLock { fencedConnections.removeAll() }
    }

    /// SQLite's backup API copies a committed snapshot, including WAL contents.
    /// Never replace a user's existing backup or copy an active database file.
    public func backup(to destination: URL) throws {
        try lock.withLock {
            guard let handle else { throw SQLiteConnectionError.closed }
            guard transactionDepth == 0 else {
                throw SQLiteConnectionError.backupFailed("cannot back up an active write transaction")
            }
            let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw SQLiteConnectionError.backupFailed("destination must be a new writable file")
            }
            Darwin.close(descriptor)
            var completed = false
            defer {
                if !completed { try? FileManager.default.removeItem(at: destination) }
            }
            var target: OpaquePointer?
            let openResult = sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard openResult == SQLITE_OK, let target else {
                if let target { sqlite3_close_v2(target) }
                throw SQLiteConnectionError.backupFailed("cannot open the reserved destination")
            }
            defer { sqlite3_close_v2(target) }
            guard let backup = sqlite3_backup_init(target, "main", handle, "main") else {
                throw SQLiteConnectionError.backupFailed(String(cString: sqlite3_errmsg(target)))
            }
            var result: Int32
            var busyAttempts = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            repeat {
                result = sqlite3_backup_step(backup, 128)
                if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                    busyAttempts += 1
                    if busyAttempts < 50 { sqlite3_sleep(10) }
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
                && (result == SQLITE_OK || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && busyAttempts < 50))
            let finishResult = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
                throw SQLiteConnectionError.backupFailed("snapshot did not complete (\(result), \(finishResult))")
            }
            // The source header may select WAL. Normalize the independent
            // snapshot to a standalone rollback-journal database before close.
            guard sqlite3_exec(target, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteConnectionError.backupFailed("cannot finalize standalone snapshot")
            }
            completed = true
        }
    }

    func execute(_ sql: String) throws {
        try lock.withLock {
            guard !updateSuspended else { throw SQLiteConnectionError.suspendedForApplicationUpdate }
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
            guard !updateSuspended else { throw SQLiteConnectionError.suspendedForApplicationUpdate }
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
