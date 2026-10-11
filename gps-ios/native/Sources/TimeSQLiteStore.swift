import Foundation
import SQLite3

/// Persistencia incremental WAL. El JSON v1 queda intacto tras migrar.
struct TimeStoreHeader: Codable {
    var names: [String: String]
    var importedHashes: [String]
    var camera: CameraSave
    var missingSeconds: TimeInterval
    var savedVisitStart: Date?
    var trackingEnabled: Bool
    var manualBreaks: [Date]
    // Opcionales: las cabeceras de SQLite v0.3 no contienen estos campos.
    var places: [UserPlace]?
    var territoryCache: [String:TerritoryRecord]?
    var powerEvents: [GPSPowerEvent]?
    var shortIDs: [String:Int]?
    var gpsRest: GPSRestSession?

    init(_ state: SavedState) {
        names = state.names
        importedHashes = state.importedHashes
        camera = state.camera
        missingSeconds = state.missingSeconds
        savedVisitStart = state.savedVisitStart
        trackingEnabled = state.trackingEnabled
        manualBreaks = state.manualBreaks
        places = state.places
        territoryCache = state.territoryCache
        powerEvents = state.powerEvents
        shortIDs = state.shortIDs
        gpsRest = state.gpsRest
    }
}

enum TimeStoreError: Error {
    case sql(String)
}

final class TimeSQLiteStore {
    private var db: OpaquePointer?

    init(url: URL) throws {
        let rc = sqlite3_open_v2(url.path, &db,
                                 SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "No se pudo abrir la base"
            sqlite3_close(db)
            db = nil
            throw TimeStoreError.sql(reason)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("CREATE TABLE IF NOT EXISTS fixes (id TEXT PRIMARY KEY, date REAL NOT NULL, lat REAL, lon REAL, accuracy REAL, source TEXT)")
        try execute("CREATE INDEX IF NOT EXISTS idx_fixes_date ON fixes(date)")
        try execute("CREATE TABLE IF NOT EXISTS intervals (id TEXT PRIMARY KEY, start REAL, end REAL, cell_row INTEGER, cell_col INTEGER, quality TEXT, source TEXT)")
        try execute("CREATE INDEX IF NOT EXISTS idx_intervals_start ON intervals(start)")
        try execute("CREATE TABLE IF NOT EXISTS totals (cell TEXT PRIMARY KEY, seconds REAL NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
    }

    deinit { if db != nil { sqlite3_close(db) } }

    private func message() -> String {
        guard let db else { return "Base de datos no disponible" }
        return String(cString: sqlite3_errmsg(db))
    }
    private func execute(_ sql: String) throws {
        guard let db else { throw TimeStoreError.sql("SQLite cerrado") }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TimeStoreError.sql(message())
        }
    }
    private func prepared(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { throw TimeStoreError.sql(message()) }
        return stmt
    }
    private func text(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
    private func done(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw TimeStoreError.sql(message()) }
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func writeHeader(_ header: TimeStoreHeader) throws {
        let blob = try JSONEncoder().encode(header)
        let stmt = try prepared("INSERT OR REPLACE INTO meta(key,value) VALUES('header',?)")
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(bytes.count), transient)
            try done(stmt)
        }
    }
    private func insertFix(_ point: GPSPoint) throws {
        let stmt = try prepared("INSERT OR IGNORE INTO fixes VALUES(?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        text(stmt, 1, point.id.uuidString)
        sqlite3_bind_double(stmt, 2, point.date.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, point.latitude)
        sqlite3_bind_double(stmt, 4, point.longitude)
        sqlite3_bind_double(stmt, 5, point.accuracy)
        text(stmt, 6, point.source)
        try done(stmt)
    }
    private func insertInterval(_ interval: AssignedInterval) throws {
        let stmt = try prepared("INSERT OR REPLACE INTO intervals VALUES(?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        text(stmt, 1, interval.id.uuidString)
        sqlite3_bind_double(stmt, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, interval.end.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 4, sqlite3_int64(interval.cell.row))
        sqlite3_bind_int64(stmt, 5, sqlite3_int64(interval.cell.column))
        text(stmt, 6, interval.quality)
        text(stmt, 7, interval.source)
        try done(stmt)
    }

    var hasExistingState: Bool {
        guard let stmt = try? prepared("SELECT 1 FROM meta WHERE key='header' LIMIT 1") else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// La migración solo queda visible tras COMMIT. No borra el JSON original.
    func replaceAll(_ data: SavedState) throws {
        try transaction {
            try execute("DELETE FROM fixes")
            try execute("DELETE FROM intervals")
            try execute("DELETE FROM totals")
            for point in data.fixes { try insertFix(point) }
            for interval in data.intervals { try insertInterval(interval) }
            for (cell, seconds) in data.totals {
                try updateTotal(cell: cell, delta: seconds)
            }
            try writeHeader(TimeStoreHeader(data))
        }
    }

    private func updateTotal(cell: String, delta: TimeInterval) throws {
        let stmt = try prepared("INSERT INTO totals(cell,seconds) VALUES(?,?) ON CONFLICT(cell) DO UPDATE SET seconds=seconds+excluded.seconds")
        defer { sqlite3_finalize(stmt) }
        text(stmt, 1, cell)
        sqlite3_bind_double(stmt, 2, delta)
        try done(stmt)
    }

    /// Una sola transacción por lote; evita reescribir miles de muestras JSON.
    func append(fixes: [GPSPoint], intervals: [AssignedInterval],
                totals: [String: TimeInterval], header: TimeStoreHeader) throws {
        try transaction {
            for point in fixes { try insertFix(point) }
            for interval in intervals { try insertInterval(interval) }
            for (cell, delta) in totals { try updateTotal(cell: cell, delta: delta) }
            try writeHeader(header)
        }
    }
    func saveHeader(_ header: TimeStoreHeader) throws {
        try transaction { try writeHeader(header) }
    }

    func load() throws -> SavedState {
        var data = SavedState()
        if let s = try? prepared("SELECT value FROM meta WHERE key='header'") {
            defer { sqlite3_finalize(s) }
            if sqlite3_step(s) == SQLITE_ROW, let bytes = sqlite3_column_blob(s, 0) {
                let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))
                let header = try JSONDecoder().decode(TimeStoreHeader.self, from: blob)
                data.names = header.names
                data.importedHashes = header.importedHashes
                data.camera = header.camera
                data.missingSeconds = header.missingSeconds
                data.savedVisitStart = header.savedVisitStart
                data.trackingEnabled = header.trackingEnabled
                data.manualBreaks = header.manualBreaks
                data.places = header.places ?? []
                data.territoryCache = header.territoryCache ?? [:]
                data.powerEvents = header.powerEvents ?? []
                data.shortIDs = header.shortIDs ?? [:]
                data.gpsRest = header.gpsRest
            }
        }
        let fixes = try prepared("SELECT id,date,lat,lon,accuracy,source FROM fixes ORDER BY date")
        defer { sqlite3_finalize(fixes) }
        while sqlite3_step(fixes) == SQLITE_ROW {
            data.fixes.append(GPSPoint(id: uuid(fixes, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(fixes, 1)),
                latitude: sqlite3_column_double(fixes, 2),
                longitude: sqlite3_column_double(fixes, 3),
                accuracy: sqlite3_column_double(fixes, 4),
                source: string(fixes, 5)))
        }
        let intervals = try prepared("SELECT id,start,end,cell_row,cell_col,quality,source FROM intervals ORDER BY start")
        defer { sqlite3_finalize(intervals) }
        while sqlite3_step(intervals) == SQLITE_ROW {
            data.intervals.append(AssignedInterval(id: uuid(intervals, 0),
                start: Date(timeIntervalSince1970: sqlite3_column_double(intervals, 1)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(intervals, 2)),
                cell: Cell(row: Int(sqlite3_column_int64(intervals, 3)),
                           column: Int(sqlite3_column_int64(intervals, 4))),
                quality: string(intervals, 5), source: string(intervals, 6)))
        }
        let totals = try prepared("SELECT cell,seconds FROM totals")
        defer { sqlite3_finalize(totals) }
        while sqlite3_step(totals) == SQLITE_ROW {
            data.totals[string(totals, 0)] = sqlite3_column_double(totals, 1)
        }
        return data
    }
    private func string(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let value = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: value)
    }
    private func uuid(_ stmt: OpaquePointer, _ col: Int32) -> UUID {
        UUID(uuidString: string(stmt, col)) ?? UUID()
    }
}
