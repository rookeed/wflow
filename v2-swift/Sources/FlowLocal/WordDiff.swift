import Foundation

/// Пара-кандидат для словаря: «как услышал» → «как надо».
struct CorrectionCandidate: Identifiable, Equatable {
    var id: String { misheard + "→" + word }
    let misheard: String   // старый фрагмент (ослышка)
    let word: String       // новый фрагмент (правильно)
}

/// Дифф по словам (LCS) + фильтры, чтобы предлагать только похожее на
/// исправление ослышки, а не смысловую правку.
enum WordDiff {

    static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Замен-«прогоны»: подряд удалённые слова → подряд вставленные.
    /// Возвращает кандидатов после фильтрации. Пусто = ничего похожего
    /// на исправление распознавания.
    static func candidates(old oldText: String, new newText: String,
                           limitTo pastedWords: Set<String>? = nil) -> [CorrectionCandidate] {
        let a = tokenize(oldText)
        let b = tokenize(newText)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // защита от огромных документов (AX отдаёт весь текст поля)
        guard a.count <= 1500, b.count <= 1500 else { return [] }
        if a == b { return [] }

        // LCS DP
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                        : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        // проход: собираем прогоны замен
        var pairs: [(old: [String], new: [String])] = []
        var i = 0, j = 0
        var delRun: [String] = [], insRun: [String] = []
        func flush() {
            if !delRun.isEmpty || !insRun.isEmpty {
                pairs.append((delRun, insRun))
                delRun = []; insRun = []
            }
        }
        while i < n && j < m {
            if a[i] == b[j] {
                flush(); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                delRun.append(a[i]); i += 1
            } else {
                insRun.append(b[j]); j += 1
            }
        }
        delRun.append(contentsOf: a[i...])
        insRun.append(contentsOf: b[j...])
        flush()

        // сильно переписан текст → это смысловая правка, не ослышка
        let replacedWords = pairs.reduce(0) { $0 + $1.old.count }
        if replacedWords > max(4, Int(Double(a.count) * 0.4)) { return [] }

        var out: [CorrectionCandidate] = []
        for p in pairs {
            guard !p.old.isEmpty, !p.new.isEmpty else { continue }        // чистые вставки/удаления — не ослышки
            guard p.old.count <= 4, p.new.count <= 4 else { continue }
            let oldS = p.old.joined(separator: " ")
            let newS = p.new.joined(separator: " ")
            guard oldS.count <= 40, newS.count <= 40 else { continue }
            guard norm(oldS) != norm(newS) else { continue }              // только регистр/пунктуация — шум
            // если известен вставленный текст — правка должна касаться его слов
            if let pw = pastedWords {
                let oldNorm = p.old.map(norm)
                guard oldNorm.contains(where: { pw.contains($0) }) else { continue }
            }
            out.append(CorrectionCandidate(misheard: oldS.trimmingCharacters(in: .punctuationCharacters),
                                           word: newS))
            if out.count >= 3 { break }
        }
        return out
    }

    /// Похожесть двух текстов по словам (0…1) — для детекта передиктовки.
    static func similarity(_ s1: String, _ s2: String) -> Double {
        let a = tokenize(s1).map(norm)
        let b = tokenize(s2).map(norm)
        guard !a.isEmpty, !b.isEmpty, a.count <= 400, b.count <= 400 else { return 0 }
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1
                                        : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        return Double(2 * dp[0][0]) / Double(n + m)
    }
}
