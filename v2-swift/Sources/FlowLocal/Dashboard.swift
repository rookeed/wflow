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
        // NSHostingController (а не NSHostingView) — иначе SwiftUI не получает
        // нативный unified-тулбар, материал сайдбара и системное выделение.
        let host = NSHostingController(rootView: DashboardView(model: model))
        let win = NSWindow(contentViewController: host)
        win.title = "Flow Local"
        win.styleMask.insert([.closable, .miniaturizable, .resizable])
        win.toolbarStyle = .unified
        win.titlebarSeparatorStyle = .automatic
        win.setContentSize(NSSize(width: 940, height: 620))
        win.center()
        win.isReleasedWhenClosed = false
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
                Label(s.rawValue, systemImage: s.icon)
                    .tag(s)
                    .listItemTint(.monochrome)   // серое выделение, как в Finder
            }
            .listStyle(.sidebar)
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
        Group {
            if model.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.search.isEmpty ? "mic" : "magnifyingglass")
                        .font(.system(size: 36)).foregroundColor(.secondary)
                    Text(model.search.isEmpty ? "Пока нет диктовок — зажми клавишу и говори."
                                              : "Ничего не найдено.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.history) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(Self.fmt.string(from: Date(timeIntervalSince1970: row.ts)))
                                .font(.caption).foregroundColor(.secondary)
                                .monospacedDigit()
                            if !row.app.isEmpty {
                                Text(row.app)
                                    .font(.caption2)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                                    .foregroundColor(.secondary)
                            }
                            if row.wpm > 0 {
                                Text("\(Int(row.wpm)) слов/мин")
                                    .font(.caption2).foregroundColor(Color(nsColor: .tertiaryLabelColor))
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
                            .lineSpacing(2)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Поиск по тексту")
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
                    statCard("Всего слов", "\(model.totals.words)", icon: "text.word.spacing")
                    statCard("Диктовок", "\(model.totals.dictations)", icon: "mic")
                    statCard("Средний темп", model.totals.avgWpm > 0 ? "\(Int(model.totals.avgWpm)) сл/мин" : "—", icon: "speedometer")
                    statCard("Серия", model.totals.streakDays > 0 ? "\(model.totals.streakDays) дн." : "—", icon: "flame")
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

    private func statCard(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption).foregroundColor(.accentColor)
                Text(title).font(.caption).foregroundColor(.secondary)
            }
            Text(value).font(.title2).bold().monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor)))
    }
}

// ---------------------------------------------------------- словарь

struct DictView: View {
    @ObservedObject var model: DashboardModel
    @State private var selection: Int64?
    @State private var editing: DictRow?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            if model.dict.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 36)).foregroundColor(.secondary)
                    Text("Добавь свои слова, имена и термины —\nмодель будет распознавать их правильно.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.dict, selection: $selection) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.word)
                        if !d.misheard.isEmpty {
                            Text(d.misheard)
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(d.id)
                    .contextMenu {
                        Button("Изменить…") { editing = d }
                        Button("Удалить", role: .destructive) { delete(d.id) }
                    }
                    .onTapGesture(count: 2) { editing = d }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            listFooter
        }
        .sheet(isPresented: $adding) {
            DictEditSheet(title: "Новое слово", word: "", misheard: "") { w, m in
                model.store.addDict(word: w, misheard: m)
                model.reloadAll()
            }
        }
        .sheet(item: $editing) { d in
            DictEditSheet(title: "Изменить слово", word: d.word, misheard: d.misheard) { w, m in
                model.store.updateDict(id: d.id, word: w, misheard: m)
                model.reloadAll()
            }
        }
        .navigationTitle("Словарь")
    }

    private var listFooter: some View {
        HStack(spacing: 2) {
            Button { adding = true } label: { Image(systemName: "plus") }
                .help("Добавить слово")
            Button {
                if let sel = selection { delete(sel) }
            } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Удалить выбранное")
            Divider().frame(height: 14).padding(.horizontal, 4)
            Button {
                if let sel = selection, let d = model.dict.first(where: { $0.id == sel }) {
                    editing = d
                }
            } label: { Image(systemName: "pencil") }
                .disabled(selection == nil)
                .help("Изменить (или двойной клик по строке)")
            Spacer()
            Text("Ослышки заменяются на правильное написание автоматически")
                .font(.caption).foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func delete(_ id: Int64) {
        model.store.deleteDict(id: id)
        if selection == id { selection = nil }
        model.reloadAll()
    }
}

struct DictEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var word: String
    @State var misheard: String
    let onSave: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form {
                TextField("Слово:", text: $word, prompt: Text("Wispr Flow"))
                TextField("Ослышки:", text: $misheard, prompt: Text("виспер флоу, виспр флов"))
                Text("Несколько вариантов — через запятую")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    let w = word.trimmingCharacters(in: .whitespaces)
                    guard !w.isEmpty else { return }
                    onSave(w, misheard.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// ---------------------------------------------------------- сниппеты

struct SnippetsView: View {
    @ObservedObject var model: DashboardModel
    @State private var selection: Int64?
    @State private var editing: SnippetRow?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            if model.snippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 36)).foregroundColor(.secondary)
                    Text("Скажи фразу-триггер — вставится готовый текст.\nНапример: «моя подпись» → полная подпись.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.snippets, selection: $selection) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.trigger)
                        Text(s.expansion)
                            .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(s.id)
                    .contextMenu {
                        Button("Изменить…") { editing = s }
                        Button("Удалить", role: .destructive) { delete(s.id) }
                    }
                    .onTapGesture(count: 2) { editing = s }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            listFooter
        }
        .sheet(isPresented: $adding) {
            SnippetEditSheet(title: "Новый сниппет", trigger: "", expansion: "") { t, e in
                model.store.addSnippet(trigger: t, expansion: e)
                model.reloadAll()
            }
        }
        .sheet(item: $editing) { s in
            SnippetEditSheet(title: "Изменить сниппет", trigger: s.trigger, expansion: s.expansion) { t, e in
                model.store.updateSnippet(id: s.id, trigger: t, expansion: e)
                model.reloadAll()
            }
        }
        .navigationTitle("Сниппеты")
    }

    private var listFooter: some View {
        HStack(spacing: 2) {
            Button { adding = true } label: { Image(systemName: "plus") }
                .help("Добавить сниппет")
            Button {
                if let sel = selection { delete(sel) }
            } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Удалить выбранное")
            Divider().frame(height: 14).padding(.horizontal, 4)
            Button {
                if let sel = selection, let s = model.snippets.first(where: { $0.id == sel }) {
                    editing = s
                }
            } label: { Image(systemName: "pencil") }
                .disabled(selection == nil)
                .help("Изменить (или двойной клик по строке)")
            Spacer()
            Text("Триггер должен совпадать со сказанной фразой целиком")
                .font(.caption).foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func delete(_ id: Int64) {
        model.store.deleteSnippet(id: id)
        if selection == id { selection = nil }
        model.reloadAll()
    }
}

struct SnippetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var trigger: String
    @State var expansion: String
    let onSave: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Фраза-триггер:", text: $trigger, prompt: Text("моя подпись"))
            Text("Текст для вставки:").font(.caption).foregroundColor(.secondary)
            TextEditor(text: $expansion)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    let t = trigger.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !expansion.isEmpty else { return }
                    onSave(t, expansion)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
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
