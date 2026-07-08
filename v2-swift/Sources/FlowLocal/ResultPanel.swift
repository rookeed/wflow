import AppKit
import ApplicationServices

// Проверка: есть ли фокус в редактируемом поле (куда сработает Cmd+V).

enum FocusCheck {
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea",
    ]

    static func focusIsEditable() -> Bool {
        // Нет прав AX — проверить не можем, ведём себя как раньше (вставляем).
        guard AXIsProcessTrusted() else { return true }

        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref)
        guard err == .success, let ref else {
            // Сфокусированного элемента нет вовсе — вставлять точно некуда.
            log("focus check: no focused element (err=\(err.rawValue)) → panel")
            return false
        }
        let el = ref as! AXUIElement

        var role = "?"
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let r = roleRef as? String {
            role = r
            if editableRoles.contains(r) {
                log("focus check: role=\(r) → editable")
                return true
            }
        }
        // кастомные контролы: значение можно менять → считаем полем
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            log("focus check: role=\(role), value settable → editable")
            return true
        }
        log("focus check: role=\(role), not editable → panel")
        return false
    }
}
