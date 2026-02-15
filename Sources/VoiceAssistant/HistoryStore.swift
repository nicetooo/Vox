import Foundation
import CSQLite

// MARK: - History Record

struct HistoryRecord {
    let id: Int64
    let type: HistoryType
    let inputText: String?      // original text (for translation), nil for voice
    let outputText: String      // transcribed or translated text
    let sourceLang: String?
    let targetLang: String?
    let timestamp: Date
    let duration: Double?       // recording duration in seconds (for voice)

    var displayText: String {
        if type == .translation, let input = inputText {
            return "\(input)\n→ \(outputText)"
        }
        return outputText
    }

    var copyText: String {
        return outputText
    }
}

enum HistoryType: String {
    case voice = "voice"
    case translation = "translation"
}

enum HistoryDateFilter: Int {
    case allTime = 0
    case today = 1
    case last7Days = 2
    case last30Days = 3

    var startDate: Date? {
        let cal = Calendar.current
        switch self {
        case .allTime: return nil
        case .today: return cal.startOfDay(for: Date())
        case .last7Days: return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))
        case .last30Days: return cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date()))
        }
    }
}

// MARK: - History Store (SQLite)

class HistoryStore {
    static let shared = HistoryStore()
    private var db: OpaquePointer?
    private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        openDatabase()
        createTable()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("VoiceAssistant")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let dbPath = appDir.appendingPathComponent("history.sqlite").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let err = db != nil ? String(cString: sqlite3_errmsg(db)!) : "unknown"
            log("HistoryStore: failed to open DB — \(err)")
        } else {
            log("HistoryStore: opened \(dbPath)")
        }
    }

    private func createTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                type TEXT NOT NULL,
                input_text TEXT,
                output_text TEXT NOT NULL,
                source_lang TEXT,
                target_lang TEXT,
                timestamp REAL NOT NULL,
                duration REAL
            );
            CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp);
            """
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let err = errMsg != nil ? String(cString: errMsg!) : "unknown"
            log("HistoryStore: create table failed — \(err)")
            sqlite3_free(errMsg)
        }
    }

    // MARK: - Insert

    func addVoice(text: String, duration: Double? = nil) {
        insert(type: .voice, inputText: nil, outputText: text,
               sourceLang: nil, targetLang: nil, duration: duration)
        log("HistoryStore: saved voice record")
    }

    func addTranslation(input: String, output: String, sourceLang: String?, targetLang: String?) {
        insert(type: .translation, inputText: input, outputText: output,
               sourceLang: sourceLang, targetLang: targetLang, duration: nil)
        log("HistoryStore: saved translation record")
    }

    private func insert(type: HistoryType, inputText: String?, outputText: String,
                        sourceLang: String?, targetLang: String?, duration: Double?) {
        let sql = """
            INSERT INTO history (type, input_text, output_text, source_lang, target_lang, timestamp, duration)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("HistoryStore: insert prepare failed")
            return
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, type.rawValue)
        bindText(stmt, 2, inputText)
        bindText(stmt, 3, outputText)
        bindText(stmt, 4, sourceLang)
        bindText(stmt, 5, targetLang)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        if let d = duration {
            sqlite3_bind_double(stmt, 7, d)
        } else {
            sqlite3_bind_null(stmt, 7)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            log("HistoryStore: insert step failed")
        }
    }

    // MARK: - Query

    func fetch(query: String? = nil, dateFilter: HistoryDateFilter = .allTime) -> [HistoryRecord] {
        var conditions: [String] = []
        var textParams: [String] = []
        var dateParam: Double?

        if let q = query, !q.isEmpty {
            conditions.append("(output_text LIKE ? OR input_text LIKE ?)")
            textParams.append("%\(q)%")
            textParams.append("%\(q)%")
        }
        if let startDate = dateFilter.startDate {
            conditions.append("timestamp >= ?")
            dateParam = startDate.timeIntervalSince1970
        }

        var sql = "SELECT id, type, input_text, output_text, source_lang, target_lang, timestamp, duration FROM history"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY timestamp DESC LIMIT 500"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("HistoryStore: fetch prepare failed")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var paramIdx: Int32 = 1
        for tp in textParams {
            bindText(stmt, paramIdx, tp)
            paramIdx += 1
        }
        if let dp = dateParam {
            sqlite3_bind_double(stmt, paramIdx, dp)
        }

        var records: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let typeStr = columnText(stmt, 1) ?? "voice"
            let type = HistoryType(rawValue: typeStr) ?? .voice
            let inputText = columnText(stmt, 2)
            let outputText = columnText(stmt, 3) ?? ""
            let sourceLang = columnText(stmt, 4)
            let targetLang = columnText(stmt, 5)
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let duration: Double? = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                ? sqlite3_column_double(stmt, 7) : nil

            records.append(HistoryRecord(
                id: id, type: type, inputText: inputText, outputText: outputText,
                sourceLang: sourceLang, targetLang: targetLang,
                timestamp: timestamp, duration: duration
            ))
        }
        return records
    }

    // MARK: - Delete

    func delete(id: Int64) {
        let sql = "DELETE FROM history WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
        log("HistoryStore: deleted record \(id)")
    }

    func deleteAll() {
        sqlite3_exec(db, "DELETE FROM history", nil, nil, nil)
        log("HistoryStore: deleted all records")
    }

    var count: Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - SQLite Helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_PTR)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}
