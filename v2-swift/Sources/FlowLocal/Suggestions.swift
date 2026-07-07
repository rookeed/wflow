import AppKit
import SwiftUI
import ApplicationServices

// ============================================================ панель

/// Плавающая панелька в правом верхнем углу: «Добавить в словарь?».
/// Не активирует приложение, закрывается сама через 25 с.
final class SuggestionCenter: ObservableObject {
    private let store: Store
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    @Published var items: [CorrectionCandidate] = []

    init(store: Store) {
        self.store = store
    }

    /// Только с main thread.
    func show(_ candidates: [CorrectionCandidate]) {
        guard !candidates.isEmpty else { return }
        // не дублируем уже показанное и уже существующее в словаре
        let existing = Set(store.dictionary().map { $0.word.lowercased() })
        var fresh = candidates.filter { !existing.contains($0.word.lowercased()) }
        fresh.removeAll { c in items.contains(c) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        if items.count > 3 { items = Array(items.suffix(3)) }
        log("suggestions: \(items.map { "\($0.misheard)→\($0.word)" }.joined(separator: "; "))")
        presentPanel()
        scheduleDismiss()
    }

    func accept(_ c: CorrectionCandidate) {
        store.addDict(word: c.word, misheard: c.misheard)
        store.notifyChanged()
        playSound("Glass")
        dismissItem(c)
    }

    func dismissItem(_ c: CorrectionCandidate) {
        items.removeAll { $0 == c }
        if items.isEmpty { close() }
    }

    func close() {
        dismissTimer?.invalidate(); dismissTimer = nil
        panel?.orderOut(nil)
        items.removeAll()
    }

    private func presentPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces]
            p.contentView = NSHostingView(rootView: SuggestionView(center: self))
            panel = p
        }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: f.maxX - 380 - 12, y: f.maxY - 160 - 8))
        }
        panel?.orderFrontRegardless()
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer(timeInterval: 25, repeats: false) { [weak self] _ in
            self?.close()
        }
        RunLoop.main.add(dismissTimer!, forMode: .common)
    }
}

struct SuggestionView: View {
    @ObservedObject var center: SuggestionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "character.book.closed").foregroundColor(.secondary)
                Text("Добавить в словарь?").font(.headline)
                Spacer()
                Button { center.close() } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            ForEach(center.items) { c in
                HStack(spacing: 6) {
                    Text("«\(c.misheard)»").strikethrough().foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                    Text("«\(c.word)»").bold().lineLimit(1)
                    Spacer()
                    Button("Добавить") { center.accept(c) }
                        .controlSize(.small)
                    Button { center.dismissItem(c) } label: {
                        Image(systemName: "xmark.circle").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 380, height: 160, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.25)))
    }
}

// ============================================================ AX-наблюдение

/// После вставки следит за полем ввода: если пользователь правит текст —
/// диффует и отдаёт кандидатов для словаря.
final class AXCorrectionWatcher {
    private let onCandidates: ([CorrectionCandidate]) -> Void
    private var generation = 0

    init(onCandidates: @escaping ([CorrectionCandidate]) -> Void) {
        self.onCandidates = onCandidates
    }

    /// Вызывать с main через ~1 с после Cmd+V (когда текст уже в поле).
    func watch(pastedText: String) {
        generation += 1
        let gen = generation
        guard let element = focusedElement(),
              let baseline = value(of: element),
              baseline.contains(WordDiff.tokenize(pastedText).first ?? "")
        else { return }
        let pastedWords = Set(WordDiff.tokenize(pastedText).map {
            $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
        })
        check(element: element, baseline: baseline, pastedWords: pastedWords,
              delays: [8.0, 20.0], gen: gen)
    }

    private func check(element: AXUIElement, baseline: String,
                       pastedWords: Set<String>, delays: [Double], gen: Int) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }   // новая диктовка — отмена
            guard let current = self.value(of: element), current != baseline else {
                self.check(element: element, baseline: baseline,
                           pastedWords: pastedWords,
                           delays: Array(delays.dropFirst()), gen: gen)
                return
            }
            let found = WordDiff.candidates(old: baseline, new: current,
                                            limitTo: pastedWords)
            if !found.isEmpty {
                self.onCandidates(found)
            } else {
                self.check(element: element, baseline: current,
                           pastedWords: pastedWords,
                           delays: Array(delays.dropFirst()), gen: gen)
            }
        }
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private func value(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let s = ref as? String, !s.isEmpty, s.count < 100_000 else { return nil }
        return s
    }
}
