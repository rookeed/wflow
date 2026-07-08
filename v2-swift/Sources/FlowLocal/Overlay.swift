import AppKit

/// Плавающий пилл внизу экрана с живым waveform (аналог Flow Bar).
/// Все методы Overlay — только с main thread; pushLevel можно с любого.

private let nBars = 27

enum OverlayMode {
    case record, locked, busy
}

final class WaveView: NSView {
    var mode: OverlayMode = .record
    private var levels = [Float](repeating: 0, count: nBars)
    private var phase: Float = 0
    private let levelsLock = NSLock()

    func pushLevel(_ v: Float) {
        levelsLock.lock()
        levels.removeFirst()
        levels.append(v)
        levelsLock.unlock()
    }

    func resetLevels() {
        levelsLock.lock()
        levels = [Float](repeating: 0, count: nBars)
        levelsLock.unlock()
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        // фон рисует NSVisualEffectView под нами (liquid glass), здесь только контент
        phase += 0.25

        // левый значок
        let iconCX: CGFloat = 30, iconCY = h / 2
        switch mode {
        case .locked:
            drawText("🔒", x: iconCX - 10, y: iconCY - 9, size: 15)
        case .busy:
            drawText("✍️", x: iconCX - 10, y: iconCY - 9, size: 15)
        case .record:
            let pulse = CGFloat(0.55 + 0.45 * abs(sin(phase * 0.5)))
            NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: pulse).setFill()
            NSBezierPath(ovalIn: NSRect(x: iconCX - 6, y: iconCY - 6, width: 12, height: 12)).fill()
        }

        // waveform
        let barsX0: CGFloat = 52
        let barsX1: CGFloat = mode == .busy ? w - 16 : w - 96
        let step = (barsX1 - barsX0) / CGFloat(nBars)
        let bw = max(2.0, step * 0.55)
        NSColor(calibratedWhite: 0.95, alpha: 0.95).setFill()

        levelsLock.lock()
        let snapshot = levels
        levelsLock.unlock()

        for i in 0..<nBars {
            let lv: CGFloat
            if mode == .busy {
                lv = CGFloat(0.25 + 0.2 * abs(sin(phase * 0.6 + Float(i) * 0.5)))
            } else {
                lv = CGFloat(snapshot[i])
            }
            let bh = 3.0 + lv * (h - 18.0)
            let x = barsX0 + CGFloat(i) * step
            let y = (h - bh) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: bw, height: bh),
                         xRadius: bw / 2, yRadius: bw / 2).fill()
        }

        // подсказка справа
        switch mode {
        case .locked:
            drawText("\(Config.shared.hotkeyName) — стоп", x: w - 86, y: h / 2 - 7, size: 11, grey: true)
        case .record:
            drawText("тап = 🔒", x: w - 86, y: h / 2 - 7, size: 11, grey: true)
        case .busy:
            break
        }
    }

    private func drawText(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, grey: Bool = false) {
        let color = grey ? NSColor(calibratedWhite: 0.7, alpha: 0.9) : NSColor.white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
        ]
        (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
}

final class Overlay {
    static let width: CGFloat = 320
    static let height: CGFloat = 46

    private let panel: NSPanel
    let view: WaveView
    private var timer: Timer?

    init() {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = (screen.width - Overlay.width) / 2
        let y: CGFloat = 88
        panel = NSPanel(contentRect: NSRect(x: x, y: y, width: Overlay.width, height: Overlay.height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces]

        // Пилл из «жидкого стекла»: тёмный HUD-материал с блюром фона.
        let frame = NSRect(x: 0, y: 0, width: Overlay.width, height: Overlay.height)
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Overlay.height / 2
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        view = WaveView(frame: frame)
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        panel.contentView = blur
    }

    func show(_ mode: OverlayMode) {
        view.mode = mode
        view.resetLevels()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.view.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)   // анимация живёт и при открытом меню
            timer = t
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func setMode(_ mode: OverlayMode) {
        view.mode = mode
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }
}
