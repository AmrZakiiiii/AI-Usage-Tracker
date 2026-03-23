import Foundation
import SQLite3

enum SQLiteDatabaseError: Error, LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let message):
            return "SQLite open failed: \(message)"
        case .prepare(let message):
            return "SQLite prepare failed: \(message)"
        case .step(let message):
            return "SQLite step failed: \(message)"
        }
    }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(readOnly url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)

        guard result == SQLITE_OK else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteDatabaseError.open(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func fetchKeyValueMap(query: String) throws -> [String: String] {
        try prepareAndRun(query: query) { statement in
            var results: [String: String] = [:]

            while sqlite3_step(statement) == SQLITE_ROW {
                let key = stringValue(statement: statement, index: 0) ?? ""
                let value = stringValue(statement: statement, index: 1) ?? ""
                results[key] = value
            }

            let code = sqlite3_errcode(handle)
            guard code == SQLITE_OK || code == SQLITE_DONE else {
                throw SQLiteDatabaseError.step(errorMessage())
            }

            return results
        }
    }

    func fetchFirstString(query: String) throws -> String? {
        try prepareAndRun(query: query) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                return stringValue(statement: statement, index: 0)
            }

            return nil
        }
    }

    func fetchFirstInt(query: String) throws -> Int? {
        try prepareAndRun(query: query) { statement in
            if sqlite3_step(statement) == SQLITE_ROW {
                return Int(sqlite3_column_int64(statement, 0))
            }

            return nil
        }
    }

    private func prepareAndRun<T>(query: String, body: (OpaquePointer) throws -> T) throws -> T {
        guard let handle else {
            throw SQLiteDatabaseError.open("database handle was not available")
        }

        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, query, -1, &statement, nil)

        guard result == SQLITE_OK, let statement else {
            throw SQLiteDatabaseError.prepare(errorMessage())
        }

        defer {
            sqlite3_finalize(statement)
        }

        return try body(statement)
    }

    private func stringValue(statement: OpaquePointer, index: Int32) -> String? {
        let type = sqlite3_column_type(statement, index)

        switch type {
        case SQLITE_TEXT:
            guard let cString = sqlite3_column_text(statement, index) else {
                return nil
            }

            return String(cString: cString)
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(statement, index))
        default:
            return nil
        }
    }

    private func errorMessage() -> String {
        guard let handle else {
            return "unknown error"
        }

        return String(cString: sqlite3_errmsg(handle))
    }
}
