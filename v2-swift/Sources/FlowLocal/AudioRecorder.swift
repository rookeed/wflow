import AVFoundation
import Foundation

/// Запись микрофона: AVAudioEngine → конверсия в 16 кГц mono Float32.
/// Аудио копится в памяти, на диск не пишется.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let outFormat: AVAudioFormat

    /// Уровень 0..1 для waveform (вызывается с аудио-потока).
    var levelSink: ((Float) -> Void)?

    init(sampleRate: Double) {
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: sampleRate,
                                  channels: 1,
                                  interleaved: false)!
    }

    static func requestMicAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        default: done(false)
        }
    }

    enum RecError: Error, CustomStringConvertible {
        case noInput
        var description: String { "нет входного аудио-устройства" }
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecError.noInput }
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Останавливает запись и возвращает накопленные сэмплы (16 кГц mono).
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        guard n > 0 else { return }
        let ptr = ch[0]

        var sumSq: Float = 0
        for i in 0..<n { sumSq += ptr[i] * ptr[i] }
        let rms = (sumSq / Float(n)).squareRoot()
        levelSink?(min(1.0, rms * 14.0))

        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
        lock.unlock()
    }
}
