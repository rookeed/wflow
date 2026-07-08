import AppKit
import ApplicationServices

// Роли, в которые вставка точно не имеет смысла.
private let nonEditableRoles: Set<String> = [
    "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuItem",
    "AXMenuButton", "AXImage", "AXScrollArea", "AXOutline", "AXTable",
    "AXList", "AXRow", "AXCell", "AXToolbar", "AXDisclosureTriangle",
]

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
            // Electron-приложения (Cursor, VS Code, Telegram…) не отдают фокус
            // через system-wide AX — это не значит, что вставлять некуда.
            // Карточку показываем только на рабочем столе (Finder впереди).
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            let isDesktop = front == "com.apple.finder"
            log("focus check: no focused element (err=\(err.rawValue), front=\(front)) → \(isDesktop ? "panel" : "paste")")
            return !isDesktop
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
        // явные «не-поля» (кнопки, списки, рабочий стол) → карточка,
        // всё неизвестное → вставляем (сомнение в пользу вставки)
        let isNonEditable = nonEditableRoles.contains(role)
        log("focus check: role=\(role) → \(isNonEditable ? "panel" : "paste (unknown role)")")
        return !isNonEditable
    }
}
