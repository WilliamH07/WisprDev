import Foundation
import SQLite3

public final class SemanticMemoryStore: @unchecked Sendable {
    public static let shared = SemanticMemoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.williamh07.wisper.semantic_memory.store", qos: .utility)
    private var lastInsertedText: String?

    public init(databaseURL: URL? = nil, inMemory: Bool = false) {
        if inMemory {
            openDatabase(atPath: ":memory:")
        } else {
            let targetURL = databaseURL ?? Self.defaultDatabaseURL()
            openDatabase(atPath: targetURL?.path ?? ":memory:")
        }
        createTablesIfNeeded()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private static func defaultDatabaseURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appName = AppName.displayName
        let dir = appSupport.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SemanticMemory.sqlite")
    }

    private func openDatabase(atPath path: String) {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
            print("[SemanticMemoryStore] Failed to open SQLite DB at \(path), falling back to in-memory")
            _ = sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        } else {
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        }
    }

    private func createTablesIfNeeded() {
        queue.sync {
            guard let db else { return }
            let sql = """
            CREATE TABLE IF NOT EXISTS memory_items (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                text TEXT NOT NULL,
                snippet TEXT NOT NULL,
                source_app TEXT NOT NULL,
                window_title TEXT,
                category TEXT NOT NULL,
                embedding BLOB
            );
            CREATE INDEX IF NOT EXISTS idx_memory_timestamp ON memory_items (timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_memory_category ON memory_items (category);
            CREATE INDEX IF NOT EXISTS idx_memory_text_cat ON memory_items (text, category);
            """
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    public func insert(_ item: SemanticMemoryItem, sync: Bool = false) {
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let work = { [weak self] in
            guard let self, let db = self.db else { return }

            // Deduplication of immediate consecutive text
            if self.lastInsertedText == trimmed {
                return
            }
            self.lastInsertedText = trimmed

            // Check if exact text with category already exists to avoid redundant rows
            var checkStmt: OpaquePointer?
            let checkSql = "SELECT id FROM memory_items WHERE text = ? AND category = ? LIMIT 1;"
            if sqlite3_prepare_v2(db, checkSql, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(checkStmt, 1, (trimmed as NSString).utf8String, -1, nil)
                sqlite3_bind_text(checkStmt, 2, (item.category.rawValue as NSString).utf8String, -1, nil)
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    sqlite3_finalize(checkStmt)
                    var updateStmt: OpaquePointer?
                    let updateSql = "UPDATE memory_items SET timestamp = ? WHERE text = ? AND category = ?;"
                    if sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK {
                        sqlite3_bind_double(updateStmt, 1, item.timestamp.timeIntervalSince1970)
                        sqlite3_bind_text(updateStmt, 2, (trimmed as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(updateStmt, 3, (item.category.rawValue as NSString).utf8String, -1, nil)
                        sqlite3_step(updateStmt)
                        sqlite3_finalize(updateStmt)
                    }
                    return
                }
                sqlite3_finalize(checkStmt)
            }

            let sql = """
            INSERT OR REPLACE INTO memory_items
            (id, timestamp, text, snippet, source_app, window_title, category, embedding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (item.id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 2, item.timestamp.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, (item.text as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (item.snippet as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (item.sourceAppName as NSString).utf8String, -1, nil)

                if let win = item.sourceWindowTitle {
                    sqlite3_bind_text(stmt, 6, (win as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }

                sqlite3_bind_text(stmt, 7, (item.category.rawValue as NSString).utf8String, -1, nil)

                if let emb = item.embedding {
                    let data = emb.withUnsafeBytes { Data($0) }
                    _ = data.withUnsafeBytes { rawPtr in
                        sqlite3_bind_blob(stmt, 8, rawPtr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 8)
                }

                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        if sync {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    public func fetchRecent(limit: Int = 50) -> [SemanticMemoryItem] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT id, timestamp, text, snippet, source_app, window_title, category, embedding
            FROM memory_items
            ORDER BY timestamp DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            var items: [SemanticMemoryItem] = []

            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let item = parseItem(from: stmt) {
                        items.append(item)
                    }
                }
            }
            sqlite3_finalize(stmt)
            return items
        }
    }

    public func loadAllForSearch(limit: Int = 1500) -> [SemanticMemoryItem] {
        fetchRecent(limit: limit)
    }

    public func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            let sql = "SELECT COUNT(*) FROM memory_items;"
            var stmt: OpaquePointer?
            var total = 0
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    total = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return total
        }
    }

    public func deleteOlderThan(days: Int) {
        guard days > 0 else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let cutoff = Date().addingTimeInterval(-Double(days * 86400)).timeIntervalSince1970
            let sql = "DELETE FROM memory_items WHERE timestamp < ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func clearAll() {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM memory_items;", nil, nil, nil)
            self.lastInsertedText = nil
        }
    }

    private func parseItem(from stmt: OpaquePointer?) -> SemanticMemoryItem? {
        guard let stmt else { return nil }

        guard let idCStr = sqlite3_column_text(stmt, 0),
              let idUUID = UUID(uuidString: String(cString: idCStr)) else {
            return nil
        }

        let timeVal = sqlite3_column_double(stmt, 1)
        let date = Date(timeIntervalSince1970: timeVal)

        let textCStr = sqlite3_column_text(stmt, 2)
        let text = textCStr != nil ? String(cString: textCStr!) : ""

        let snippetCStr = sqlite3_column_text(stmt, 3)
        let snippet = snippetCStr != nil ? String(cString: snippetCStr!) : ""

        let appCStr = sqlite3_column_text(stmt, 4)
        let app = appCStr != nil ? String(cString: appCStr!) : ""

        var windowTitle: String? = nil
        if let winCStr = sqlite3_column_text(stmt, 5) {
            windowTitle = String(cString: winCStr)
        }

        let catCStr = sqlite3_column_text(stmt, 6)
        let catRaw = catCStr != nil ? String(cString: catCStr!) : "clipboard"
        let category = SemanticMemoryCategory(rawValue: catRaw) ?? .clipboard

        var embedding: [Double]? = nil
        if let blob = sqlite3_column_blob(stmt, 7) {
            let bytesCount = Int(sqlite3_column_bytes(stmt, 7))
            if bytesCount > 0 && bytesCount % MemoryLayout<Double>.size == 0 {
                let count = bytesCount / MemoryLayout<Double>.size
                let buffer = blob.bindMemory(to: Double.self, capacity: count)
                embedding = Array(UnsafeBufferPointer(start: buffer, count: count))
            }
        }

        return SemanticMemoryItem(
            id: idUUID,
            timestamp: date,
            text: text,
            snippet: snippet,
            sourceAppName: app,
            sourceWindowTitle: windowTitle,
            category: category,
            embedding: embedding
        )
    }
}
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
