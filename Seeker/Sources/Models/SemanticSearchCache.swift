import Foundation
import SQLite3

actor SemanticSearchCache {
    static let shared = SemanticSearchCache()

    struct CachedEmbedding: Sendable {
        let values: [Float]
        let hit: Bool
    }

    private struct FileIdentity {
        let path: String
        let size: Int64
        let modificationTime: Double
    }

    private var database: OpaquePointer?
    nonisolated let databaseURL: URL

    init() {
        let fm = FileManager.default
        let caches = (try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.marvel.Seeker"
        let directory = caches.appendingPathComponent(bundleID, isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("semantic-search.sqlite3")
        databaseURL = url
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            database = nil
            return
        }
        Self.execute(database, "PRAGMA journal_mode=WAL")
        Self.execute(database, "PRAGMA synchronous=NORMAL")
        Self.execute(database, """
            CREATE TABLE IF NOT EXISTS embeddings (
                model_id TEXT NOT NULL,
                path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                modification_time REAL NOT NULL,
                dimension INTEGER NOT NULL,
                vector BLOB NOT NULL,
                PRIMARY KEY (model_id, path)
            )
            """)
        Self.execute(database, """
            CREATE TABLE IF NOT EXISTS ocr_text (
                path TEXT PRIMARY KEY,
                file_size INTEGER NOT NULL,
                modification_time REAL NOT NULL,
                text TEXT NOT NULL
            )
            """)
    }

    func embedding(for url: URL, modelID: String) -> [Float]? {
        guard let identity = identity(for: url), let database else { return nil }
        let sql = """
            SELECT dimension, vector FROM embeddings
            WHERE model_id = ? AND path = ? AND file_size = ? AND modification_time = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(modelID, at: 1, in: statement)
        bind(identity.path, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, identity.size)
        sqlite3_bind_double(statement, 4, identity.modificationTime)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let dimension = Int(sqlite3_column_int(statement, 0))
        let byteCount = Int(sqlite3_column_bytes(statement, 1))
        guard dimension > 0,
              byteCount == dimension * MemoryLayout<Float>.size,
              let bytes = sqlite3_column_blob(statement, 1) else { return nil }
        return Array(UnsafeBufferPointer(
            start: bytes.assumingMemoryBound(to: Float.self),
            count: dimension
        ))
    }

    func store(embedding: [Float], for url: URL, modelID: String) {
        guard !embedding.isEmpty,
              let identity = identity(for: url),
              let database else { return }
        let sql = """
            INSERT OR REPLACE INTO embeddings
            (model_id, path, file_size, modification_time, dimension, vector)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(modelID, at: 1, in: statement)
        bind(identity.path, at: 2, in: statement)
        sqlite3_bind_int64(statement, 3, identity.size)
        sqlite3_bind_double(statement, 4, identity.modificationTime)
        sqlite3_bind_int(statement, 5, Int32(embedding.count))
        embedding.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), Self.transient)
            _ = sqlite3_step(statement)
        }
    }

    func recognizedText(for url: URL) -> String? {
        guard let identity = identity(for: url), let database else { return nil }
        let sql = """
            SELECT text FROM ocr_text
            WHERE path = ? AND file_size = ? AND modification_time = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(identity.path, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, identity.size)
        sqlite3_bind_double(statement, 3, identity.modificationTime)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func store(recognizedText: String, for url: URL) {
        guard let identity = identity(for: url), let database else { return }
        let sql = """
            INSERT OR REPLACE INTO ocr_text
            (path, file_size, modification_time, text) VALUES (?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(identity.path, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, identity.size)
        sqlite3_bind_double(statement, 3, identity.modificationTime)
        bind(recognizedText, at: 4, in: statement)
        _ = sqlite3_step(statement)
    }

    func removeAll() {
        execute("DELETE FROM embeddings")
        execute("DELETE FROM ocr_text")
        execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func pruneMissingEntries(maxChecks: Int) {
        guard maxChecks > 0, let database else { return }
        let sql = """
            SELECT path FROM embeddings
            UNION SELECT path FROM ocr_text
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        sqlite3_bind_int(statement, 1, Int32(maxChecks))
        var missing: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0) else { continue }
            let value = String(cString: path)
            if !FileManager.default.fileExists(atPath: value) { missing.append(value) }
        }
        sqlite3_finalize(statement)
        guard !missing.isEmpty else { return }

        for path in missing {
            var deleteStatement: OpaquePointer?
            let deleteSQL = "DELETE FROM embeddings WHERE path = ?;"
            if sqlite3_prepare_v2(database, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK,
               let deleteStatement {
                bind(path, at: 1, in: deleteStatement)
                _ = sqlite3_step(deleteStatement)
                sqlite3_finalize(deleteStatement)
            }
            deleteStatement = nil
            if sqlite3_prepare_v2(database, "DELETE FROM ocr_text WHERE path = ?;", -1, &deleteStatement, nil) == SQLITE_OK,
               let deleteStatement {
                bind(path, at: 1, in: deleteStatement)
                _ = sqlite3_step(deleteStatement)
                sqlite3_finalize(deleteStatement)
            }
        }
    }

    func currentSizeBytes() -> Int64 {
        let fm = FileManager.default
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        return paths.reduce(0) { total, path in
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    private func identity(for url: URL) -> FileIdentity? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return FileIdentity(
            path: url.standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private func execute(_ sql: String) {
        Self.execute(database, sql)
    }

    private static func execute(_ database: OpaquePointer?, _ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
