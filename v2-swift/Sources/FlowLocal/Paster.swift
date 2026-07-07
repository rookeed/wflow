import AppKit
import CoreGraphics

/// Вставка текста в курсор: буфер обмена + синтетический Cmd+V.
/// Старое содержимое буфера восстанавливается через ~1 с.
enum Paster {
    /// Метка наших синтетических событий, чтобы HotkeyTap их игнорировал.
    static let eventMarker: Int64 = 0x464C_4F57  // "FLOW"

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChangeCount = pb.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .hidSystemState)
            src?.userData = eventMarker
            for down in [true, false] {
                if let ev = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down) { // 9 = 'v'
                    ev.flags = .maskCommand
                    ev.post(tap: .cghidEventTap)
                }
                usleep(20_000)
            }
            if let old {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let pb2 = NSPasteboard.general
                    // Не трогаем буфер, если пользователь уже скопировал своё.
                    guard pb2.changeCount == ourChangeCount else { return }
                    pb2.clearContents()
                    pb2.setString(old, forType: .string)
                }
            }
        }
    }
}

func frontmostAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
}

func playSound(_ name: String) {
    guard Config.shared.sounds else { return }
    // Всегда с main: playSound могут звать с tap-потока, а он должен быть быстрым.
    DispatchQueue.main.async { NSSound(named: name)?.play() }
}
