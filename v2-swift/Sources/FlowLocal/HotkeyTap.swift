import CoreGraphics
import Foundation

/// Слушатель горячей клавиши на CGEventTap.
/// Живёт на выделенном потоке с собственным run loop, чтобы главный поток
/// (модель, UI) не «морил» tap. Callback делает минимум работы.
final class HotkeyTap {
    private let keycode: Int64
    private let maskBit: CGEventFlags
    private var tap: CFMachPort?
    private var flagDown = false

    /// true = клавиша нажата, false = отпущена. Вызывается на потоке tap'а.
    var onHotkey: ((Bool) -> Void)?
    /// Другая клавиша/клик мыши (модификатор использован как шорткат).
    var onInterrupt: (() -> Void)?
    /// Не удалось создать tap (нет прав Input Monitoring).
    var onFailed: (() -> Void)?

    private static let masks: [Int64: CGEventFlags] = [
        63: .maskSecondaryFn,
        58: .maskAlternate, 61: .maskAlternate,
        55: .maskCommand, 54: .maskCommand,
        56: .maskShift, 60: .maskShift,
        59: .maskControl, 62: .maskControl,
    ]

    init(keycode: Int64) {
        self.keycode = keycode
        self.maskBit = HotkeyTap.masks[keycode] ?? .maskAlternate
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "flow.hotkey-tap"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func run() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                    me.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon)
        else {
            log("tap create FAILED (нет Input Monitoring)")
            onFailed?()
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("tap installed on dedicated thread (key=\(keycode))")
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // ВАЖНО: ничего тяжёлого — только флаги и колбэки.
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log("tap disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown, .rightMouseDown, .keyDown:
            // Игнорируем собственный синтетический Cmd+V (иначе вставка
            // результата отменяла бы уже начатую следующую запись).
            if event.getIntegerValueField(.eventSourceUserData) == Paster.eventMarker { return }
            onInterrupt?()
        case .flagsChanged:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            guard kc == keycode else { return }
            let down = event.flags.contains(maskBit)
            if down != flagDown {
                flagDown = down
                log("hotkey \(down ? "DOWN" : "UP") (kc=\(kc))")
                onHotkey?(down)
            }
        default:
            break
        }
    }

    /// Watchdog: реанимировать tap, если macOS его отключил.
    func reviveIfNeeded() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
