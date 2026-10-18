import Foundation
import CSQLite
import Darwin

final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL, readOnly: Bool = false) throws {
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else { throw CoreError.storage(Int32(errno)) }
        let path = String(cString: resolved) + "/" + url.lastPathComponent
        free(resolved)
        var pointer: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = sqlite3_open_v2(path, &pointer, flags | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard code == SQLITE_OK, let pointer else { if let pointer { sqlite3_close(pointer) }; throw CoreError.storage(code) }
        handle = pointer
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw CoreError.storage(code) }
    }
    func statement(_ sql: String, _ bindings: [SQLValue] = []) throws -> SQLiteStatement {
        let s = try SQLiteStatement(connection: self, sql: sql)
        for (index, value) in bindings.enumerated() { try s.bind(value, at: Int32(index + 1)) }
        return s
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}
enum SQLValue { case text(String), int(Int), real(Double), blob(Data), null }
final class SQLiteStatement {
    let handle: OpaquePointer
    private let connection: SQLiteConnection
    init(connection: SQLiteConnection, sql: String) throws {
        self.connection = connection
        var s: OpaquePointer?
        let code = sqlite3_prepare_v2(connection.handle, sql, -1, &s, nil)
        guard code == SQLITE_OK, let s else { throw CoreError.storage(code) }
        handle = s
    }
    deinit { sqlite3_finalize(handle) }
    func bind(_ value: SQLValue, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code: Int32
        switch value {
        case .text(let text): code = text.withCString { sqlite3_bind_text(handle, index, $0, Int32(text.utf8.count), transient) }
        case .int(let int): code = sqlite3_bind_int64(handle, index, Int64(int))
        case .real(let real): code = sqlite3_bind_double(handle, index, real)
        case .blob(let data): code = data.isEmpty ? sqlite3_bind_zeroblob(handle, index, 0) : data.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), transient) }
        case .null: code = sqlite3_bind_null(handle, index)
        }
        guard code == SQLITE_OK else { throw CoreError.storage(code) }
    }
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        if code == SQLITE_ROW { return true }
        guard code == SQLITE_DONE else { throw CoreError.storage(code) }
        return false
    }
    func text(_ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(handle, column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func real(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func data(_ column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        let length = Int(sqlite3_column_bytes(handle, column))
        guard let ptr = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: ptr, count: length)
    }
}
