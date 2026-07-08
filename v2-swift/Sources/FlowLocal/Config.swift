import Foundation

/// Конфиг совместим с v1: тот же ~/.flow-local/config.json.
enum Paths {
    static let configDir = NSString(string: "~/.flow-local").expandingTildeInPath
    static let configFile = configDir + "/config.json"
    static let dbFile = configDir + "/flow.db"
    static let logFile = configDir + "/log-v2.txt"
    static let lockFile = configDir + "/app-v2.lock"
    static let modelsDir = configDir + "/models"

    static func ensureDirs() {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
    }
}

private let logLock = NSLock()

func log(_ msg: String) {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    let line = "\(df.string(from: Date())) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    logLock.lock(); defer { logLock.unlock() }
    if let h = FileHandle(forWritingAtPath: Paths.logFile) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: Paths.logFile))
    }
}

final class Config {
    // Значения по умолчанию (совпадают с v1, кроме модели: Q5-квант turbo)
    var hotkeyKeycode: Int64 = 63          // 63=Fn, 61=прав. Option, 54=прав. Cmd
    var model = "large-v3-turbo-q5"
    var language: String? = nil            // nil = авто (RU/EN)
    var sampleRate: Double = 16000
    var minDurationSec = 0.4
    var tapLockSec = 0.35                  // тап короче = замок (hands-free)
    var sounds = true
    var showOverlay = true
    var saveHistory = true
    var userName = ""
    // позиция мини-бара (центр X и нижняя кромка); nil = по умолчанию
    var overlayCX: Double?
    var overlayBottom: Double?

    static let shared = Config()

    private init() { load() }

    func load() {
        Paths.ensureDirs()
        guard let data = FileManager.default.contents(atPath: Paths.configFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { save(); return }
        if let v = obj["hotkey_keycode"] as? Int { hotkeyKeycode = Int64(v) }
        if let v = obj["model"] as? String { model = v }
        language = obj["language"] as? String            // null → nil
        if let v = obj["sample_rate"] as? Double { sampleRate = v }
        if let v = obj["min_duration_sec"] as? Double { minDurationSec = v }
        if let v = obj["tap_lock_sec"] as? Double { tapLockSec = v }
        if let v = obj["sounds"] as? Bool { sounds = v }
        if let v = obj["show_overlay"] as? Bool { showOverlay = v }
        if let v = obj["save_history"] as? Bool { saveHistory = v }
        if let v = obj["user_name"] as? String { userName = v }
        overlayCX = obj["overlay_cx"] as? Double
        overlayBottom = obj["overlay_bottom"] as? Double
    }

    func save() {
        let obj: [String: Any?] = [
            "hotkey_keycode": Int(hotkeyKeycode),
            "model": model,
            "language": language,
            "sample_rate": sampleRate,
            "min_duration_sec": minDurationSec,
            "tap_lock_sec": tapLockSec,
            "sounds": sounds,
            "show_overlay": showOverlay,
            "save_history": saveHistory,
            "user_name": userName,
            "overlay_cx": overlayCX,
            "overlay_bottom": overlayBottom,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: obj as [String: Any], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: Paths.configFile))
        }
    }

    var hotkeyName: String {
        switch hotkeyKeycode {
        case 63: return "Fn"
        case 58, 61: return "Option"
        case 54, 55: return "Cmd"
        case 56, 60: return "Shift"
        case 59, 62: return "Ctrl"
        default: return "клавиша"
        }
    }

    /// Кандидаты имён файлов ggml-модели; берём первый существующий.
    var modelFileCandidates: [String] {
        switch model {
        case "large-v3-turbo-q5": return ["ggml-large-v3-turbo-q5_0.bin"]
        case "large-v3-turbo":    return ["ggml-large-v3-turbo.bin", "ggml-large-v3-turbo-q5_0.bin"]
        case "large-v3":          return ["ggml-large-v3.bin"]
        case "medium-q5":         return ["ggml-medium-q5_0.bin"]
        case "medium":            return ["ggml-medium.bin", "ggml-medium-q5_0.bin"]
        case "small":             return ["ggml-small.bin"]
        default:                  return [model]   // прямое имя файла
        }
    }

    var modelPath: String? {
        for f in modelFileCandidates {
            let p = Paths.modelsDir + "/" + f
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }
}
