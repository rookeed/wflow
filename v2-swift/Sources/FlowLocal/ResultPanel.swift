import AppKit
import SwiftUI
import ApplicationServices

// ============================================================ проверка фокуса

enum FocusCheck {
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea",
    ]

    /// Есть ли фокус в редактируемом поле (куда сработает Cmd+V).
    /// При недоступности AX отвечаем true — ведём себя как раньше (вставляем).
    static func focusIsEditable() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref else { return true }   // AX недоступен — не мешаем
        let el = ref as! AXUIElement

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            if editableRoles.contains(role) { return true }
        }
        // кастомные контролы: значение можно менять → считаем полем
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }
}

// ============================================================ плашка результата

/// Показывается, когда вставлять некуда: текст + «Скопировать».
final class ResultPanel: ObservableObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    @Published var text = ""
    @Published var copied = false

    /// Только с main thread.
    func show(_ t: String) {
        text = t
        copied = false
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces]
            p.contentView = NSHostingView(rootView: ResultView(panel: self))
            panel = p
        }
        // над мини-баром (его позиция в конфиге), не выходя за экран
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cx = CGFloat(Config.shared.overlayCX ?? Double(screen.midX))
        let bottom = CGFloat(Config.shared.overlayBottom ?? 88) + Overlay.activeH + 10
        var x = cx - 210
        x = min(max(x, screen.minX + 8), screen.maxX - 420 - 8)
        let y = min(bottom, screen.maxY - 170 - 8)
        panel?.setFrameOrigin(NSPoint(x: x, y: y))
        panel?.orderFrontRegardless()

        dismissTimer?.invalidate()
        dismissTimer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in self?.close() }
        RunLoop.main.add(dismissTimer!, forMode: .common)
    }

    func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        playSound("Glass")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.close() }
    }

    func close() {
        dismissTimer?.invalidate(); dismissTimer = nil
        panel?.orderOut(nil)
    }
}

struct ResultView: View {
    @ObservedObject var panel: ResultPanel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.cursor").foregroundColor(.secondary)
                Text("Курсор не в поле ввода — текст не вставлен")
                    .font(.subheadline).foregroundColor(.secondary)
                Spacer()
                Button { panel.close() } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            ScrollView {
                Text(panel.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 80)
            HStack {
                Spacer()
                Button {
                    panel.copy()
                } label: {
                    Label(panel.copied ? "Скопировано" : "Скопировать",
                          systemImage: panel.copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 420, height: 170, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
