import AppKit

/// Постоянный мини-бар (как Flow Bar у Wispr):
///  - всегда на экране: тонкая полупрозрачная капсула
///  - при наведении проявляется, перетаскивается мышью (позиция запоминается)
///  - при записи раскрывается в пилл с живым waveform, потом сворачивается

private let nBars = 27

enum OverlayMode {
    case idle, record, locked, busy
}

final class WaveView: NSView {
    var mode: OverlayMode = .idle
    var onDragEnd: (() -> Void)?
    private var levels = [Float](repeating: 0, count: nBars)
    private var phase: Float = 0
    private let levelsLock = NSLock()
    private var tracking: NSTrackingArea?

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

    // ---- hover: проявление мини-бара
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard mode == .idle else { return }
        window?.animator().alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        guard mode == .idle else { return }
        window?.animator().alphaValue = 0.55
    }

    // ---- drag: перетаскивание всего бара
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        onDragEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        let ink = NSColor.labelColor
        phase += 0.25

        if mode == .idle {
            // статичная мини-волна по центру
            let heights: [CGFloat] = [0.35, 0.65, 1.0, 0.65, 0.35]
            let bw: CGFloat = 2.5, gap: CGFloat = 3.5
            let total = CGFloat(heights.count) * bw + CGFloat(heights.count - 1) * gap
            var x = (w - total) / 2
            ink.withAlphaComponent(0.5).setFill()
            for hf in heights {
                let bh = max(2, (h - 5) * hf)
                NSBezierPath(roundedRect: NSRect(x: x, y: (h - bh) / 2, width: bw, height: bh),
                             xRadius: bw / 2, yRadius: bw / 2).fill()
                x += bw + gap
            }
            return
        }

        // левый значок
        let iconCX: CGFloat = 20, iconCY = h / 2
        switch mode {
        case .locked:
            drawSymbol("lock.fill", color: ink, cx: iconCX, cy: iconCY)
        case .busy:
            drawSymbol("waveform", color: ink, cx: iconCX, cy: iconCY)
        case .record:
            let pulse = CGFloat(0.55 + 0.45 * abs(sin(phase * 0.5)))
            NSColor.systemRed.withAlphaComponent(pulse).setFill()
            NSBezierPath(ovalIn: NSRect(x: iconCX - 5, y: iconCY - 5, width: 10, height: 10)).fill()
        case .idle:
            break
        }

        // waveform
        let barsX0: CGFloat = 38
        let barsX1: CGFloat = w - 16
        let step = (barsX1 - barsX0) / CGFloat(nBars)
        let bw = max(2.0, step * 0.55)
        ink.withAlphaComponent(0.85).setFill()

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
            let bh = 2.5 + lv * (h - 14.0)
            let x = barsX0 + CGFloat(i) * step
            let y = (h - bh) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: bw, height: bh),
                         xRadius: bw / 2, yRadius: bw / 2).fill()
        }
    }

    private func drawSymbol(_ name: String, color: NSColor, cx: CGFloat, cy: CGFloat) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: cx - img.size.width / 2, y: cy - img.size.height / 2,
                               width: img.size.width, height: img.size.height))
    }
}

final class Overlay {
    static let idleW: CGFloat = 68, idleH: CGFloat = 12
    static let activeW: CGFloat = 240, activeH: CGFloat = 34

    private let panel: NSPanel
    private let blur: NSVisualEffectView
    let view: WaveView
    private var timer: Timer?
    private(set) var expanded = false

    // позиция: центр X и нижняя кромка (общая для мини и раскрытого)
    private var cx: CGFloat
    private var bottom: CGFloat

    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        cx = CGFloat(Config.shared.overlayCX ?? Double(screen.midX))
        bottom = CGFloat(Config.shared.overlayBottom ?? 88)
        // не даём улететь за экран
        cx = min(max(cx, screen.minX + 60), screen.maxX - 60)
        bottom = min(max(bottom, screen.minY), screen.maxY - 60)

        let frame = NSRect(x: cx - Overlay.idleW / 2, y: bottom,
                           width: Overlay.idleW, height: Overlay.idleH)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false          // hover + drag
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.alphaValue = 0.55

        blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Overlay.idleH / 2
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        blur.autoresizingMask = [.width, .height]

        view = WaveView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        panel.contentView = blur

        view.onDragEnd = { [weak self] in self?.savePosition() }
    }

    /// Показать мини-бар (при старте приложения).
    func showIdle() {
        view.mode = .idle
        panel.orderFrontRegardless()
    }

    /// Раскрыться в пилл с waveform.
    func expand(_ mode: OverlayMode) {
        view.mode = mode
        view.resetLevels()
        expanded = true
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.view.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        panel.orderFrontRegardless()
        blur.layer?.cornerRadius = Overlay.activeH / 2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
            panel.animator().setFrame(activeFrame(), display: true)
        }
    }

    func setMode(_ mode: OverlayMode) {
        view.mode = mode
    }

    /// Свернуться обратно в мини-бар.
    func collapse() {
        timer?.invalidate()
        timer = nil
        expanded = false
        view.mode = .idle
        blur.layer?.cornerRadius = Overlay.idleH / 2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.55
            panel.animator().setFrame(idleFrame(), display: true)
        }
    }

    /// Полностью скрыть/показать (настройка «Индикатор записи»).
    func setVisible(_ on: Bool) {
        if on { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func idleFrame() -> NSRect {
        NSRect(x: cx - Overlay.idleW / 2, y: bottom, width: Overlay.idleW, height: Overlay.idleH)
    }

    private func activeFrame() -> NSRect {
        NSRect(x: cx - Overlay.activeW / 2, y: bottom, width: Overlay.activeW, height: Overlay.activeH)
    }

    /// После перетаскивания: запомнить новую позицию.
    private func savePosition() {
        let f = panel.frame
        cx = f.midX
        bottom = f.minY
        Config.shared.overlayCX = Double(cx)
        Config.shared.overlayBottom = Double(bottom)
        Config.shared.save()
    }
}
