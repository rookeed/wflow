import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-хранилище, схема 1:1 с v1 (~/.flow-local/flow.db).
final class Store {
    var dbHandle: OpaquePointer?
    let storeQueue = DispatchQueue(label: "flow.store")

    struct DictEntry { let word: String; let misheard: String }
    struct Snippet { let trigger: String; let expansion: String }

    init() {
        Paths.ensureDirs()
        storeQueue.sync {
            guard sqlite3_open(Paths.dbFile, &dbHandle) == SQLITE_OK else {
                log("store: open failed"); return
            }
            exec("PRAGMA journal_mode=WAL")
            exec("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                text TEXT NOT NULL,
                words INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                wpm REAL NOT NULL DEFAULT 0,
                model TEXT DEFAULT '',
                app TEXT DEFAULT ''
            )
            """)
            exec("CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts DESC)")
            exec("""
            CREATE TABLE IF NOT EXISTS dictionary (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                word TEXT NOT NULL UNIQUE,
                misheard TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL
            )
            """)
            exec("""
            CREATE TABLE IF NOT EXISTS snippets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trigger TEXT NOT NULL UNIQUE,
                expansion TEXT NOT NULL,
                created REAL NOT NULL
            )
            """)
        }
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(dbHandle, sql, nil, nil, &err) != SQLITE_OK {
            if let err { log("store: \(String(cString: err))"); sqlite3_free(err) }
        }
    }

    static func countWords(_ text: String) -> Int {
        let re = try? NSRegularExpression(pattern: "\\w+")
        let range = NSRange(text.startIndex..., in: text)
        return re?.numberOfMatches(in: text, range: range) ?? 0
    }

    func addHistory(text: String, duration: Double, model: String, app: String) {
        let words = Store.countWords(text)
        let wpm = duration > 0.5 ? Double(words) / (duration / 60.0) : 0.0
        let ts = Date().timeIntervalSince1970
        storeQueue.async { [self] in
            var stmt: OpaquePointer?
            let sql = "INSERT INTO history (ts, text, words, duration, wpm, model, app) VALUES (?,?,?,?,?,?,?)"
            guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(words))
            sqlite3_bind_double(stmt, 4, duration)
            sqlite3_bind_double(stmt, 5, wpm)
            sqlite3_bind_text(stmt, 6, model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, app, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            notifyChanged()   // живое обновление дашборда
        }
    }

    func dictionary() -> [DictEntry] {
        storeQueue.sync {
            var out: [DictEntry] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, "SELECT word, misheard FROM dictionary", -1, &stmt, nil) == SQLITE_OK
            else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let word = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let mis = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                out.append(DictEntry(word: word, misheard: mis))
            }
            return out
        }
    }

    func snippets() -> [Snippet] {
        storeQueue.sync {
            var out: [Snippet] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(dbHandle, "SELECT trigger, expansion FROM snippets", -1, &stmt, nil) == SQLITE_OK
            else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let trig = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let exp = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                out.append(Snippet(trigger: trig, expansion: exp))
            }
            return out
        }
    }
}

// ------------------------------------------------------------- постобработка

/// Слова из словаря — подсказка (initial_prompt) для Whisper.
func dictionaryPrompt(_ store: Store) -> String? {
    let words = store.dictionary().map { $0.word }
    guard !words.isEmpty else { return nil }
    return "Словарь: " + words.prefix(60).joined(separator: ", ") + "."
}

private func normPhrase(_ s: String) -> String {
    let stripped = s.unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "_"
    }
    return String(String.UnicodeScalarView(stripped))
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Автозамены «ослышек» из словаря + подстановка сниппетов.
func postprocess(_ input: String, store: Store) -> String {
    var text = input
    for entry in store.dictionary() {
        let variants = entry.misheard.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for v in variants {
            let pattern = NSRegularExpression.escapedPattern(for: v)
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                text = re.stringByReplacingMatches(
                    in: text, range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.word))
            }
        }
    }
    let tnorm = normPhrase(text)
    for sn in store.snippets() {
        let trig = normPhrase(sn.trigger)
        if !trig.isEmpty && trig == tnorm { return sn.expansion }
    }
    return text
}
