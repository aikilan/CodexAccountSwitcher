import Foundation
import SQLite3

enum SQLiteLogSignalKind: Equatable, Sendable {
    case rateLimitsUpdated
    case authReloadStarted
    case authReloadCompleted
    case authErrorRefreshTokenReused
    case authError
}

struct SQLiteLogCursor: Equatable, Sendable {
    let seconds: Int64
    let nanoseconds: Int64

    init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    init(date: Date) {
        let timeInterval = date.timeIntervalSince1970
        let seconds = Int64(timeInterval.rounded(.down))
        let fractional = max(0, timeInterval - Double(seconds))
        let nanoseconds = Int64((fractional * 1_000_000_000).rounded(.down))
        self.init(seconds: seconds, nanoseconds: nanoseconds)
    }
}

struct SQLiteLogSignal: Equatable, Sendable {
    let cursor: SQLiteLogCursor
    let message: String
    let kind: SQLiteLogSignalKind

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(cursor.seconds) + (TimeInterval(cursor.nanoseconds) / 1_000_000_000))
    }
}

final class SQLiteLogReader: @unchecked Sendable {
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func latestRelevantSignal(after date: Date) -> SQLiteLogSignal? {
        latestRelevantSignal(after: SQLiteLogCursor(date: date))
    }

    func latestRelevantSignal(after cursor: SQLiteLogCursor) -> SQLiteLogSignal? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        let sql = """
        SELECT ts, ts_nanos, message
        FROM logs
        WHERE (
            ts > ?
            OR (ts = ? AND ts_nanos > ?)
        )
          AND (
            message LIKE '%account/rateLimits/updated%'
            OR message LIKE '%Reloaded auth%'
            OR message LIKE '%Reloading auth%'
          )
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1;
        """

        return withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, cursor.seconds)
            sqlite3_bind_int64(statement, 2, cursor.seconds)
            sqlite3_bind_int64(statement, 3, cursor.nanoseconds)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            let timestamp = sqlite3_column_int64(statement, 0)
            let nanoseconds = sqlite3_column_int64(statement, 1)
            let message = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            return SQLiteLogSignal(
                cursor: SQLiteLogCursor(seconds: timestamp, nanoseconds: nanoseconds),
                message: message,
                kind: classifyRelevantSignal(message)
            )
        }
    }

    func latestAuthError(after date: Date) -> SQLiteLogSignal? {
        latestAuthError(after: SQLiteLogCursor(date: date))
    }

    func latestAuthError(after cursor: SQLiteLogCursor) -> SQLiteLogSignal? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }

        let sql = """
        SELECT ts, ts_nanos, message
        FROM logs
        WHERE (
            ts > ?
            OR (ts = ? AND ts_nanos > ?)
        )
          AND target = 'codex_core::auth'
          AND level = 'ERROR'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1;
        """

        return withDatabase { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, cursor.seconds)
            sqlite3_bind_int64(statement, 2, cursor.seconds)
            sqlite3_bind_int64(statement, 3, cursor.nanoseconds)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            let timestamp = sqlite3_column_int64(statement, 0)
            let nanoseconds = sqlite3_column_int64(statement, 1)
            let message = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            return SQLiteLogSignal(
                cursor: SQLiteLogCursor(seconds: timestamp, nanoseconds: nanoseconds),
                message: message,
                kind: classifyAuthError(message)
            )
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) -> T?) -> T? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            return nil
        }
        defer { sqlite3_close(database) }
        return body(database)
    }

    private func classifyRelevantSignal(_ message: String) -> SQLiteLogSignalKind {
        if message.contains("Reloaded auth") {
            return .authReloadCompleted
        }
        if message.contains("Reloading auth") {
            return .authReloadStarted
        }
        return .rateLimitsUpdated
    }

    private func classifyAuthError(_ message: String) -> SQLiteLogSignalKind {
        let lowered = message.lowercased()
        if lowered.contains("refresh_token_reused") || lowered.contains("refresh token was already used") {
            return .authErrorRefreshTokenReused
        }
        return .authError
    }
}
