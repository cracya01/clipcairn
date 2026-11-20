import Foundation

/// Thin wrapper over the SQLCipher C API. Used from the main actor only.
final class Database {
    enum DBError: Error, CustomStringConvertible {
        case sqlite(code: Int32, message: String)
        var description: String {
            switch self {
            case let .sqlite(code, message): return "SQLite error \(code): \(message)"
            }
        }
    }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (or creates) an encrypted database with a raw 32-byte key.
    init(path: String, key: Data) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        db = handle
        guard rc == SQLITE_OK else { throw error(rc) }
        // Raw key (hex) skips key derivation; SQLCipher keeps its default page format.
        let hex = key.map { String(format: "%02x", $0) }.joined()
        try exec("PRAGMA key = \"x'\(hex)'\";")
        // Fails with SQLITE_NOTADB if the key does not match an existing file.
        try exec("SELECT count(*) FROM sqlite_master;")
        // auto_vacuum only takes effect on a new, empty database; it lets deletes give space back.
        try exec("PRAGMA auto_vacuum = INCREMENTAL; PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
    }

    deinit { sqlite3_close_v2(db) }

    private func error(_ rc: Int32) -> DBError {
        let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        return .sqlite(code: rc, message: msg)
    }

    func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: Statements

    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null
    }

    final class Row {
        fileprivate let stmt: OpaquePointer
        fileprivate init(_ s: OpaquePointer) { stmt = s }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func blob(_ i: Int32) -> Data? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: n)
        }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else { throw error(rc) }
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let x): sqlite3_bind_int64(s, idx, x)
            case .double(let x): sqlite3_bind_double(s, idx, x)
            case .text(let x): sqlite3_bind_text(s, idx, x, -1, Database.transient)
            case .blob(let d):
                d.withUnsafeBytes { p in
                    _ = sqlite3_bind_blob(s, idx, p.baseAddress, Int32(d.count), Database.transient)
                }
            case .null: sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    func run(_ sql: String, _ args: [Value] = []) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
    }

    func query(_ sql: String, _ args: [Value] = [], _ each: (Row) throws -> Void) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        let row = Row(s)
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { try each(row); continue }
            if rc == SQLITE_DONE { break }
            throw error(rc)
        }
    }

    /// Number of rows changed by the last statement.
    var changes: Int { Int(sqlite3_changes(db)) }
}
