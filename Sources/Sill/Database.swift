import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the system sqlite3 — one local file, inspectable with any
/// SQLite client (PRD §2). Synchronous writes; nothing buffered across a crash.
final class Database {
    enum Value {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
    }

    struct Row {
        private let columns: [String: Value]
        init(_ columns: [String: Value]) { self.columns = columns }

        func text(_ column: String) -> String? {
            if case .text(let value)? = columns[column] { return value }
            return nil
        }
        func int(_ column: String) -> Int64? {
            switch columns[column] {
            case .int(let value)?: return value
            case .real(let value)?: return Int64(value)
            default: return nil
            }
        }
        func real(_ column: String) -> Double? {
            switch columns[column] {
            case .real(let value)?: return value
            case .int(let value)?: return Double(value)
            default: return nil
            }
        }
    }

    private var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw SillError("cannot open database at \(path): \(message)")
        }
        if !readOnly {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA foreign_keys = ON")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SillError("sqlite exec failed: \(errorMessage) — \(sql)")
        }
    }

    func run(_ sql: String, _ parameters: [Value] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SillError("sqlite step failed: \(errorMessage) — \(sql)")
        }
    }

    func query(_ sql: String, _ parameters: [Value] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var columns: [String: Value] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: columns[name] = .int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: columns[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: columns[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                default: columns[name] = .null
                }
            }
            rows.append(Row(columns))
        }
        return rows
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SillError("sqlite prepare failed: \(errorMessage) — \(sql)")
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            }
        }
        return statement
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }
}

struct SillError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
