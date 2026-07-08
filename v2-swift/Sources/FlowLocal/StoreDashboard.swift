import Foundation
import SQLite3

// Расширения Store для дашборда: история, статистика, CRUD, черновик.

extension Notification.Name {
    static let flowHistoryChanged = Notification.Name("flowHistoryChanged")
}

private let SQLITE_TRANSIENT2 = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HistoryRow: Identifiable {
    let id: Int64
    let ts: Double
    let text: String
    let words: Int
    let duration: Double
    let wpm: Double
    let app: String
}

struct DayStat: Identifiable {
    var id: String { day }
    let day: String      // "дд.мм"
    let words: Int
}

struct AppStat: Identifiable {
    var id: String { app }
    let app: String
    let words: Int
}

struct Totals {
    var dictations = 0
    var words = 0
    var avgWpm = 0.0
    var streakDays = 0
}

struct DictRow: Identifiable {
    let id: Int64
    let word: String
    let misheard: String
}

struct SnippetRow: Identifiable {
    let id: Int64
    let trigger: String
    let expansion: String
}

extension Store {

    // MARK: история

    func history(search: String, limit: Int = 200) -> [HistoryRow] {
        storeQueue.sync {
            var out: [HistoryRow] = []
            var stmt: OpaquePointer?
            let sql: String
            if search.isEmpty {
                sql = "SELECT id, ts, text, words, duration, wpm, app FROM history ORDER BY ts DESC LIMIT \(limit)"
            } else {
                sql = "SELECT id, ts, text, words, duration, wpm, app FROM history WHERE text LIKE ? ORDER BY ts DESC LIMIT \(limit)"
            }
            guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
            defer { sqlite3_finalize(stmt) }
            if !search.isEmpty {
                sqlite3_bind_text(stmt, 1, "%\(search)%", -1, SQLITE_TRANSIENT2)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(HistoryRow(
                    id: sqlite3_column_int64(stmt, 0),
                    ts: sqlite3_column_double(stmt, 1),
                    text: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                    words: Int(sqlite3_column_int(stmt, 3)),
                    duration: sqlite3_column_double(stmt, 4),
                    wpm: sqlite3_column_double(stmt, 5),
                    app: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""))
            }
            return out
        }
    }

    func deleteHistory(id: Int64) {
        storeQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, "DELETE FROM history WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
        notifyChanged()
    }

    func updateHistoryText(id: Int64, text: String) {
        let words = Store.countWords(text)
        storeQueue.sync {
            var stmt: OpaquePointer?
            let sql = """
            UPDATE history SET text = ?, words = ?,
                   wpm = CASE WHEN duration > 0.5 THEN ? / (duration / 60.0) ELSE 0 END
            WHERE id = ?
            """
            guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_int(stmt, 2, Int32(words))
            sqlite3_bind_double(stmt, 3, Double(words))
            sqlite3_bind_int64(stmt, 4, id)
            sqlite3_step(stmt)
        }
        notifyChanged()
    }

    // MARK: статистика

    func totals() -> Totals {
        storeQueue.sync {
            var t = Totals()
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(dbHandle,
                "SELECT COUNT(*), COALESCE(SUM(words),0), COALESCE(AVG(NULLIF(wpm,0)),0) FROM history",
                -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    t.dictations = Int(sqlite3_column_int(stmt, 0))
                    t.words = Int(sqlite3_column_int(stmt, 1))
                    t.avgWpm = sqlite3_column_double(stmt, 2)
                }
                sqlite3_finalize(stmt)
            }
            // серия дней подряд с диктовками (включая сегодня/вчера как старт)
            var days = Set<String>()
            var stmt2: OpaquePointer?
            if sqlite3_prepare_v2(dbHandle,
                "SELECT DISTINCT date(ts, 'unixepoch', 'localtime') FROM history",
                -1, &stmt2, nil) == SQLITE_OK {
                while sqlite3_step(stmt2) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt2, 0) { days.insert(String(cString: c)) }
                }
                sqlite3_finalize(stmt2)
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            var cursor = Date()
            if !days.contains(fmt.string(from: cursor)) {
                cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
            }
            var streak = 0
            while days.contains(fmt.string(from: cursor)) {
                streak += 1
                cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor)!
            }
            t.streakDays = streak
            return t
        }
    }

    func last14Days() -> [DayStat] {
        storeQueue.sync {
            var byDay: [String: Int] = [:]
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(dbHandle, """
                SELECT date(ts, 'unixepoch', 'localtime') d, SUM(words)
                FROM history WHERE ts > strftime('%s','now') - 14*86400
                GROUP BY d
                """, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) {
                        byDay[String(cString: c)] = Int(sqlite3_column_int(stmt, 1))
                    }
                }
                sqlite3_finalize(stmt)
            }
            let keyFmt = DateFormatter(); keyFmt.dateFormat = "yyyy-MM-dd"
            let labelFmt = DateFormatter(); labelFmt.dateFormat = "dd.MM"
            var out: [DayStat] = []
            for offset in stride(from: 13, through: 0, by: -1) {
                let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
                out.append(DayStat(day: labelFmt.string(from: d),
                                   words: byDay[keyFmt.string(from: d)] ?? 0))
            }
            return out
        }
    }

    func topApps(limit: Int = 8) -> [AppStat] {
        storeQueue.sync {
            var out: [AppStat] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(dbHandle, """
                SELECT COALESCE(NULLIF(app,''),'—'), SUM(words) w FROM history
                GROUP BY 1 ORDER BY w DESC LIMIT \(limit)
                """, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    out.append(AppStat(
                        app: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "—",
                        words: Int(sqlite3_column_int(stmt, 1))))
                }
                sqlite3_finalize(stmt)
            }
            return out
        }
    }

    // MARK: словарь

    func dictRows() -> [DictRow] {
        storeQueue.sync {
            var out: [DictRow] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, "SELECT id, word, misheard FROM dictionary ORDER BY word", -1, &stmt, nil) == SQLITE_OK else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DictRow(
                    id: sqlite3_column_int64(stmt, 0),
                    word: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                    misheard: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""))
            }
            return out
        }
    }

    func addDict(word: String, misheard: String) {
        storeQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle,
                "INSERT OR REPLACE INTO dictionary (word, misheard, created) VALUES (?,?,?)",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_text(stmt, 2, misheard, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func updateDict(id: Int64, word: String, misheard: String) {
        storeQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle,
                "UPDATE dictionary SET word = ?, misheard = ? WHERE id = ?",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_text(stmt, 2, misheard, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    func deleteDict(id: Int64) {
        storeQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, "DELETE FROM dictionary WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: сниппеты

    func snippetRows() -> [SnippetRow] {
        storeQueue.sync {
            var out: [SnippetRow] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, "SELECT id, trigger, expansion FROM snippets ORDER BY trigger", -1, &stmt, nil) == SQLITE_OK else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(SnippetRow(
                    id: sqlite3_column_int64(stmt, 0),
                    trigger: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                    expansion: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""))
            }
            return out
        }
    }

    func addSnippet(trigger: String, expansion: String) {
        storeQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle,
                "INSERT OR REPLACE INTO snippets (trigger, expansion, created) VALUES (?,?,?)",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, trigger, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_text(stmt, 2, expansion, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func updateSnippet(id: Int64, trigger: String, expansion: String) {
        storeQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle,
                "UPDATE snippets SET trigger = ?, expansion = ? WHERE id = ?",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, trigger, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_text(stmt, 2, expansion, -1, SQLITE_TRANSIENT2)
            sqlite3_bind_int64(stmt, 3, id)
            sqlite3_step(stmt)
        }
    }

    func deleteSnippet(id: Int64) {
        storeQueue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, "DELETE FROM snippets WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: черновик

    static var scratchpadPath: String { Paths.configDir + "/scratchpad.txt" }

    func loadScratchpad() -> String {
        (try? String(contentsOfFile: Store.scratchpadPath, encoding: .utf8)) ?? ""
    }

    func saveScratchpad(_ text: String) {
        try? text.write(toFile: Store.scratchpadPath, atomically: true, encoding: .utf8)
    }

    // MARK: уведомление об изменениях

    func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .flowHistoryChanged, object: nil)
        }
    }
}
