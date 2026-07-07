import AppKit
import SwiftUI
import Charts

// ============================================================= модель

final class DashboardModel: ObservableObject {
    let store: Store
    /// Пересоздать распознавание/хоткей нельзя на лету — нужен перезапуск.
    let restartAction: () -> Void
    /// Применить «живые» настройки (язык и т.п.) без перезапуска.
    let applyLive: () -> Void
    private let bootHotkey: Int64
    private let bootModel: String

    @Published var history: [HistoryRow] = []
    @Published var search = "" { didSet { reloadHistory() } }
    @Published var totals = Totals()
    @Published var days: [DayStat] = []
    @Published var apps: [AppStat] = []
    @Published var dict: [DictRow] = []
    @Published var snippets: [SnippetRow] = []
    @Published var scratchpad = ""

    // настройки
    @Published var hotkey: Int64 { didSet { save() } }
    @Published var model: String { didSet { save() } }
    @Published var language: String { didSet { save(); applyLive() } }
    @Published var sounds: Bool { didSet { save() } }
    @Published var showOverlay: Bool { didSet { save() } }
    @Published var saveHistory: Bool { didSet { save() } }
    @Published var userName: String { didSet { save() } }

    var needsRestart: Bool { hotkey != bootHotkey || model != bootModel }

    init(store: Store, applyLive: @escaping () -> Void, restart: @escaping () -> Void) {
        self.store = store
        self.applyLive = applyLive
        self.restartAction = restart
        let cfg = Config.shared
        bootHotkey = cfg.hotkeyKeycode
        bootModel = cfg.model
        hotkey = cfg.hotkeyKeycode
        model = cfg.model
        language = cfg.language ?? "auto"
        sounds = cfg.sounds
        showOverlay = cfg.showOverlay
        saveHistory = cfg.saveHistory
        userName = cfg.userName
        scratchpad = store.loadScratchpad()

        NotificationCenter.default.addObserver(
            forName: .flowHistoryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reloadAll()
        }
        reloadAll()
    }

    private func save() {
        let cfg = Config.shared
        cfg.hotkeyKeycode = hotkey
        cfg.model = model
        cfg.language = language == "auto" ? nil : language
        cfg.sounds = sounds
        cfg.showOverlay = showOverlay
        cfg.saveHistory = saveHistory
        cfg.userName = userName
        cfg.save()
    }

    func reloadAll() {
        reloadHistory()
        totals = store.totals()
        days = store.last14Days()
        apps = store.topApps()
        dict = store.dictRows()
        snippets = store.snippetRows()
    }

    func reloadHistory() {
        history = store.history(search: search)
    }

    func copyText(_ t: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t, forType: .string)
    }

    func saveScratchpadNow() {
        store.saveScratchpad(scratchpad)
    }
}

// ============================================================= окно

final class DashboardController: NSWindowController, NSWindowDelegate {
    private let model: DashboardModel

    init(model: DashboardModel) {
        self.model = model
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Flow Local"
        win.center()
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: DashboardView(model: model))
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        model.reloadAll()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.saveScratchpadNow()
    }
}

// ============================================================= views

enum DashSection: String, CaseIterable, Identifiable {
    case home = "Главная"
    case stats = "Статистика"
    case dict = "Словарь"
    case snippets = "Сниппеты"
    case scratch = "Черновик"
    case settings = "Настройки"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "clock.arrow.circlepath"
        case .stats: return "chart.bar"
        case .dict: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .scratch: return "square.and.pencil"
        case .settings: return "gearshape"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var section: DashSection = .home

    var body: some View {
        NavigationSplitView {
            List(DashSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch section {
            case .home: HistoryView(model: model)
            case .stats: StatsView(model: model)
            case .dict: DictView(model: model)
            case .snippets: SnippetsView(model: model)
            case .scratch: ScratchView(model: model)
            case .settings: SettingsView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
    }
}

// ---------------------------------------------------------- история

struct HistoryView: View {
    @ObservedObject var model: DashboardModel
    @State private var editingRow: HistoryRow?

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Поиск по тексту…", text: $model.search)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color.gray.opacity(0.12))

            if model.history.isEmpty {
                Spacer()
                Text(model.search.isEmpty ? "Пока нет диктовок — зажми клавишу и говори."
                                          : "Ничего не найдено.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(model.history) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Self.fmt.string(from: Date(timeIntervalSince1970: row.ts)))
                                .font(.caption).foregroundColor(.secondary)
                            if !row.app.isEmpty {
                                Text("→ \(row.app)").font(.caption).foregroundColor(.secondary)
                            }
                            if row.wpm > 0 {
                                Text("\(Int(row.wpm)) слов/мин").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button { editingRow = row } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Исправить (замены предложатся в словарь)")
                            Button { model.copyText(row.text) } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Скопировать")
                            Button(role: .destructive) { model.store.deleteHistory(id: row.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить")
                        }
                        Text(row.text).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editingRow) { row in
            HistoryEditSheet(model: model, row: row) { editingRow = nil }
        }
        .navigationTitle(greeting())
    }

    private func greeting() -> String {
        let name = Config.shared.userName
        return name.isEmpty ? "История" : "История — \(name)"
    }
}

/// Редактор текста диктовки: правки диффуются, замены предлагаются в словарь.
struct HistoryEditSheet: View {
    @ObservedObject var model: DashboardModel
    let row: HistoryRow
    let dismiss: () -> Void

    @State private var text: String
    @State private var accepted: Set<String> = []

    init(model: DashboardModel, row: HistoryRow, dismiss: @escaping () -> Void) {
        self.model = model
        self.row = row
        self.dismiss = dismiss
        _text = State(initialValue: row.text)
    }

    private var found: [CorrectionCandidate] {
        WordDiff.candidates(old: row.text, new: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Исправь текст — замены можно сразу добавить в словарь.")
                .font(.caption).foregroundColor(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))

            if !found.isEmpty {
                Text("В словарь:").font(.headline)
                ForEach(found) { c in
                    Toggle(isOn: Binding(
                        get: { accepted.contains(c.id) },
                        set: { on in if on { accepted.insert(c.id) } else { accepted.remove(c.id) } }
                    )) {
                        HStack(spacing: 6) {
                            Text("«\(c.misheard)»").strikethrough().foregroundColor(.secondary)
                            Image(systemName: "arrow.right").font(.caption2)
                            Text("«\(c.word)»").bold()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    if text != row.text {
                        model.store.updateHistoryText(id: row.id, text: text)
                    }
                    for c in found where accepted.contains(c.id) {
                        model.store.addDict(word: c.word, misheard: c.misheard)
                    }
                    model.reloadAll()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onChange(of: text) { _ in
            // по умолчанию отмечаем все свежие кандидаты
            accepted = Set(found.map(\.id))
        }
    }
}

// ---------------------------------------------------------- статистика

struct StatsView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    statCard("Всего слов", "\(model.totals.words)")
                    statCard("Диктовок", "\(model.totals.dictations)")
                    statCard("Средний темп", model.totals.avgWpm > 0 ? "\(Int(model.totals.avgWpm)) слов/мин" : "—")
                    statCard("Серия", model.totals.streakDays > 0 ? "\(model.totals.streakDays) дн." : "—")
                }

                Text("Слова за 14 дней").font(.headline)
                Chart(model.days) { d in
                    BarMark(x: .value("День", d.day), y: .value("Слова", d.words))
                        .cornerRadius(3)
                }
                .frame(height: 180)

                Text("Топ приложений").font(.headline)
                let maxWords = max(model.apps.map(\.words).max() ?? 1, 1)
                VStack(spacing: 6) {
                    ForEach(model.apps) { a in
                        HStack {
                            Text(a.app).frame(width: 180, alignment: .leading).lineLimit(1)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(4, geo.size.width * CGFloat(a.words) / CGFloat(maxWords)))
                            }
                            .frame(height: 14)
                            Text("\(a.words)")
                                .font(.caption).foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Статистика")
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title2).bold()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
    }
}

// ---------------------------------------------------------- словарь

struct DictView: View {
    @ObservedObject var model: DashboardModel
    @State private var word = ""
    @State private var misheard = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Свои слова, имена и термины. «Ослышки» (через запятую) автоматически заменяются на правильное написание.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                TextField("Слово (напр. Wispr Flow)", text: $word)
                TextField("Ослышки (напр. виспер флоу, виспр флов)", text: $misheard)
                Button("Добавить") {
                    let w = word.trimmingCharacters(in: .whitespaces)
                    guard !w.isEmpty else { return }
                    model.store.addDict(word: w, misheard: misheard.trimmingCharacters(in: .whitespaces))
                    word = ""; misheard = ""
                    model.reloadAll()
                }
                .keyboardShortcut(.defaultAction)
            }
            List(model.dict) { d in
                HStack {
                    Text(d.word).bold()
                    if !d.misheard.isEmpty {
                        Text("← \(d.misheard)").foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.store.deleteDict(id: d.id)
                        model.reloadAll()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .navigationTitle("Словарь")
    }
}

// ---------------------------------------------------------- сниппеты

struct SnippetsView: View {
    @ObservedObject var model: DashboardModel
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Скажи фразу-триггер — вставится готовый текст. Например: «моя подпись» → полная подпись.")
                .font(.caption).foregroundColor(.secondary)
            HStack(alignment: .top) {
                TextField("Фраза-триггер", text: $trigger)
                    .frame(width: 220)
                TextField("Текст для вставки", text: $expansion, axis: .vertical)
                    .lineLimit(1...4)
                Button("Добавить") {
                    let t = trigger.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !expansion.isEmpty else { return }
                    model.store.addSnippet(trigger: t, expansion: expansion)
                    trigger = ""; expansion = ""
                    model.reloadAll()
                }
                .keyboardShortcut(.defaultAction)
            }
            List(model.snippets) { s in
                HStack(alignment: .top) {
                    Text(s.trigger).bold().frame(width: 200, alignment: .leading)
                    Text(s.expansion).foregroundColor(.secondary).lineLimit(3)
                    Spacer()
                    Button(role: .destructive) {
                        model.store.deleteSnippet(id: s.id)
                        model.reloadAll()
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .navigationTitle("Сниппеты")
    }
}

// ---------------------------------------------------------- черновик

struct ScratchView: View {
    @ObservedObject var model: DashboardModel
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $model.scratchpad)
            .font(.body)
            .padding(8)
            .onChange(of: model.scratchpad) { _ in
                saveTask?.cancel()
                saveTask = Task { [weak model] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if !Task.isCancelled { model?.saveScratchpadNow() }
                }
            }
            .navigationTitle("Черновик")
    }
}

// ---------------------------------------------------------- настройки

struct SettingsView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        Form {
            if model.needsRestart {
                HStack {
                    Label("Клавиша или модель изменены — нужен перезапуск.",
                          systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Перезапустить") { model.restartAction() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15)))
            }

            Picker("Клавиша диктовки", selection: $model.hotkey) {
                Text("Fn (🌐)").tag(Int64(63))
                Text("Правый Option").tag(Int64(61))
                Text("Левый Option").tag(Int64(58))
                Text("Правый Cmd").tag(Int64(54))
            }
            Picker("Модель", selection: $model.model) {
                Text("large-v3-turbo Q5 (~574 МБ, рекомендуется)").tag("large-v3-turbo-q5")
                Text("large-v3-turbo (~1.6 ГБ)").tag("large-v3-turbo")
                Text("medium Q5 (~540 МБ, быстрее)").tag("medium-q5")
                Text("small (~490 МБ)").tag("small")
            }
            Text("Файл модели должен лежать в ~/.flow-local/models — скачай через download_model.sh")
                .font(.caption).foregroundColor(.secondary)
            Picker("Язык", selection: $model.language) {
                Text("Авто (RU/EN)").tag("auto")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            Toggle("Звуки", isOn: $model.sounds)
            Toggle("Индикатор записи (пилл)", isOn: $model.showOverlay)
            Toggle("Сохранять историю", isOn: $model.saveHistory)
            TextField("Имя (для приветствия)", text: $model.userName)
        }
        .formStyle(.grouped)
        .navigationTitle("Настройки")
    }
}
