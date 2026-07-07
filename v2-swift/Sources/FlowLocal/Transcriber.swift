import Foundation
import whisper

/// Обёртка над whisper.cpp (Metal на Apple Silicon).
final class Transcriber {
    private var ctx: OpaquePointer?
    var language: String?   // можно менять на лету из настроек

    enum TrError: Error, CustomStringConvertible {
        case modelNotFound(String)
        case initFailed(String)
        var description: String {
            switch self {
            case .modelNotFound(let m): return "модель не найдена: \(m). Запусти download_model.sh"
            case .initFailed(let p): return "не удалось загрузить модель \(p)"
            }
        }
    }

    init(language: String?) {
        self.language = language
    }

    func load() throws {
        guard let path = Config.shared.modelPath else {
            throw TrError.modelNotFound(Config.shared.model)
        }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        ctx = whisper_init_from_file_with_params(path, cparams)
        guard ctx != nil else { throw TrError.initFailed(path) }
        log("whisper loaded: \(path)")
    }

    /// samples: 16 кГц mono Float32. Блокирует поток — звать с фонового.
    func transcribe(_ samples: [Float], initialPrompt: String?) -> String {
        guard let ctx, !samples.isEmpty else { return "" }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.translate = false
        params.suppress_blank = true
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        // C-строки должны жить всё время whisper_full → strdup + free.
        let langC = strdup(language ?? "auto")
        params.language = UnsafePointer(langC)
        var promptC: UnsafeMutablePointer<CChar>?
        if let p = initialPrompt, !p.isEmpty {
            promptC = strdup(p)
            params.initial_prompt = UnsafePointer(promptC)
        }
        defer {
            free(langC)
            if let promptC { free(promptC) }
        }

        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else {
            log("whisper_full rc=\(rc)")
            return ""
        }

        var out = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let t = whisper_full_get_segment_text(ctx, i) {
                out += String(cString: t)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }
}
