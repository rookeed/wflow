import AppKit

/// Меню-бар + машина состояний записи.
///
/// Потоки:
///  - tap-поток: только флаги + постановка команд в ctl-очередь
///  - ctl-очередь (serial): start/stop/cancel записи
///  - work-очередь (serial): транскрибация
///  - main: UI (меню-бар, оверлей, вставка)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenuItem = NSMenuItem(title: "Загрузка модели…", action: nil, keyEquivalent: "")
    private let helpMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let modelMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private let cfg = Config.shared
    private let store = Store()
    private var recorder: AudioRecorder!
    private var transcriber: Transcriber!
    private var hotkeyTap: HotkeyTap!
    private var overlay: Overlay?
    private var watchdog: Timer?
    private var dashboard: DashboardController?
    private var suggestions: SuggestionCenter!
    private var axWatcher: AXCorrectionWatcher!
    // для детекта передиктовки
    private var lastDictation: (text: String, ts: TimeInterval)?

    private let ctl = DispatchQueue(label: "flow.ctl")
    private let work = DispatchQueue(label: "flow.transcribe")

    // Состояние — только под stateLock (пишут tap-поток и ctl-очередь).
    private let stateLock = NSLock()
    private var ready = false
    private var recording = false
    private var locked = false
    private var stopConsumed = false
    private var pressTime: TimeInterval = 0
    private var recordStartedAt: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Отладка: FL_LEVEL=1..4 включает подсистемы поэтапно (по умолчанию всё).
        let debugLevel = Int(ProcessInfo.processInfo.environment["FL_LEVEL"] ?? "99") ?? 99

        makeStatusItem()
        // Иногда macOS кладёт новый статус-айтем под системные часы —
        // проверяем и пересоздаём, пока не встанет в нормальный слот.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.ensureStatusItemVisible()
        }
        // Смена мониторов/разрешения (в т.ч. Screen Sharing) двигает меню-бар —
        // перепроверяем позицию.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.ensureStatusItemVisible()
            }
        }

        guard debugLevel >= 2 else { return }
        suggestions = SuggestionCenter(store: store)
        axWatcher = AXCorrectionWatcher { [weak self] found in
            self?.suggestions.show(found)
        }

        overlay = Overlay()   // создаём один раз на main — без гонок при lazy-инициализации
        if cfg.showOverlay { overlay?.showIdle() }   // постоянный мини-бар
        // Правый клик по мини-бару — то же меню, что в меню-баре
        // (страховка, если иконку в баре потерял системный глюк).
        overlay?.view.menuProvider = { [weak self] in
            let menu = NSMenu()
            let open = NSMenuItem(title: "Открыть Flow Local…",
                                  action: #selector(AppDelegate.openDashboard), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Выйти из Flow Local",
                                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
            return menu
        }
        recorder = AudioRecorder(sampleRate: cfg.sampleRate)
        recorder.levelSink = { [weak self] v in
            self?.overlay?.view.pushLevel(v)   // запись в буфер потокобезопасна
        }
        transcriber = Transcriber(language: cfg.language)

        guard debugLevel >= 3 else { return }
        AudioRecorder.requestMicAccess { [weak self] ok in
            if !ok { self?.setStatus("exclamationmark.triangle", "Нет доступа к микрофону (Настройки → Конфиденциальность).") }
        }

        // Модель — в фоне.
        work.async { [weak self] in
            guard let self else { return }
            do {
                try self.transcriber.load()
                self.stateLock.lock(); self.ready = true; self.stateLock.unlock()
                log("model loaded, ready")
                self.setStatus("mic", "Готов. \(self.cfg.hotkeyName): держать или тап.")
            } catch {
                log("model load ERROR: \(error)")
                self.setStatus("exclamationmark.triangle", "Ошибка: \(error)")
            }
        }

        guard debugLevel >= 4 else { return }
        // Хоткей.
        hotkeyTap = HotkeyTap(keycode: cfg.hotkeyKeycode)
        hotkeyTap.onHotkey = { [weak self] down in self?.onHotkey(down) }
        hotkeyTap.onInterrupt = { [weak self] in self?.onInterrupt() }
        hotkeyTap.onFailed = { [weak self] in
            self?.setStatus("exclamationmark.triangle", "Нет доступа: включи Универсальный доступ и Мониторинг ввода.")
        }
        hotkeyTap.start()

        watchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.hotkeyTap.reviveIfNeeded()
        }
        RunLoop.main.add(watchdog!, forMode: .common)   // работает и при открытом меню

        // Проверка Accessibility (нужно для вставки Cmd+V).
        // С prompt: приложение регистрируется в списке Настроек и macOS
        // показывает диалог с кнопкой «Открыть Настройки».
        if !AXIsProcessTrusted() {
            log("AX not trusted — запрашиваю Универсальный доступ")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    // MARK: - статус-айтем

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(ready ? "mic" : "hourglass")

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Открыть Flow Local…",
                                  action: #selector(openDashboard), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        statusMenuItem.isEnabled = false
        helpMenuItem.title = "\(cfg.hotkeyName): держать = говорить, тап = замок 🔒, ещё тап = стоп"
        helpMenuItem.isEnabled = false
        modelMenuItem.title = "Модель: \(cfg.model) (whisper.cpp / Metal)"
        modelMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(helpMenuItem)
        menu.addItem(modelMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// Если айтем оказался в зоне системных индикаторов (правые ~180 pt) —
    /// пересоздаём: свежий айтем получает нормальный слот.
    private func ensureStatusItemVisible(attempt: Int = 1) {
        guard attempt <= 5 else {
            log("status item: gave up after \(attempt - 1) attempts")
            return
        }
        // После 2 неудач — переходим на emoji-тайтл (как v1): рисуется всегда.
        if attempt == 3 && !useEmojiStatus {
            log("status item: switching to emoji title fallback")
            useEmojiStatus = true
            setStatusIcon(lastStatusSymbol)
        }
        // Не пересоздаём айтем (removeStatusItem может бросить исключение AppKit),
        // а прячем/показываем — система пересчитывает слот заново.
        let retry: (String) -> Void = { [weak self] reason in
            guard let self else { return }
            let img = self.statusItem.button?.image != nil
            let title = self.statusItem.button?.title ?? ""
            log("status item: \(reason) img=\(img) title='\(title)', re-slotting (attempt \(attempt))")
            self.statusItem.isVisible = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.statusItem.isVisible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.ensureStatusItemVisible(attempt: attempt + 1)
                }
            }
        }
        guard let win = statusItem.button?.window else {
            retry("no window yet")
            return
        }
        let screen = (win.screen ?? NSScreen.main)?.frame ?? .zero
        let f = win.frame
        if f.maxX > screen.maxX - 180 || f.origin.x <= 1 || !win.isVisible {
            retry("bad slot (x=\(Int(f.origin.x)), visible=\(win.isVisible))")
        } else {
            log("status item ok at x=\(Int(f.origin.x))")
        }
    }

    // MARK: - дашборд

    @objc private func openDashboard() {
        // async: даём меню закончить трекинг, иначе первый клик после
        // запуска съедается и окно не показывается
        DispatchQueue.main.async { [weak self] in self?.doOpenDashboard() }
    }

    private func doOpenDashboard() {
        if dashboard == nil {
            let model = DashboardModel(
                store: store,
                applyLive: { [weak self] in
                    self?.transcriber.language = Config.shared.language
                    self?.overlay?.setVisible(Config.shared.showOverlay)
                },
                restart: { [weak self] in self?.restartApp() })
            dashboard = DashboardController(model: model)
        }
        dashboard?.show()
    }

    private func restartApp() {
        log("restart requested from dashboard")
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - статус
    // Иконки — шаблонные SF Symbols (ч/б, сами адаптируются к тёмной/светлой теме).

    /// true → рисуем emoji-тайтлом вместо SF Symbol (fallback, как в v1).
    private var useEmojiStatus = false
    private static let emojiFor: [String: String] = [
        "hourglass": "⏳", "mic": "🎙", "mic.fill": "🔴", "waveform": "✍️",
        "lock.fill": "🔒", "exclamationmark.triangle": "⚠️",
    ]
    private var lastStatusSymbol = "hourglass"

    private func setStatusIcon(_ symbolName: String) {
        lastStatusSymbol = symbolName
        if useEmojiStatus {
            statusItem.button?.image = nil
            statusItem.button?.title = AppDelegate.emojiFor[symbolName] ?? "🎙"
            return
        }
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Flow Local")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.title = ""
    }

    private func setStatus(_ symbolName: String, _ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.setStatusIcon(symbolName)
            self?.statusMenuItem.title = text
        }
    }

    private func setReadyStatus() {
        setStatus("mic", "Готов. \(cfg.hotkeyName): держать или тап.")
    }

    // MARK: - оверлей (только main)

    private func overlayShow(_ mode: OverlayMode) {
        guard cfg.showOverlay else { return }
        DispatchQueue.main.async { [weak self] in self?.overlay?.expand(mode) }
    }

    private func overlayMode(_ mode: OverlayMode) {
        guard cfg.showOverlay else { return }
        DispatchQueue.main.async { [weak self] in self?.overlay?.setMode(mode) }
    }

    private func overlayHide() {
        DispatchQueue.main.async { [weak self] in self?.overlay?.collapse() }
    }

    // MARK: - хоткей (tap-поток; только флаги и очередь)

    private func onHotkey(_ pressed: Bool) {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        if pressed {
            pressTime = now
            if recording && locked {
                stopConsumed = true
                locked = false
                stateLock.unlock()
                ctl.async { [weak self] in self?.stopRecording() }
                return
            } else if !recording && ready {
                stopConsumed = false
                recording = true
                recordStartedAt = now
                stateLock.unlock()
                ctl.async { [weak self] in self?.startRecording() }
                return
            }
            stateLock.unlock()
        } else {
            if stopConsumed || !recording {
                stateLock.unlock()
                return
            }
            if now - pressTime < cfg.tapLockSec {
                locked = true
                stateLock.unlock()
                playSound("Morse")
                overlayMode(.locked)
                setStatus("lock.fill", "Hands-free: говори. \(cfg.hotkeyName) — стоп.")
            } else {
                stateLock.unlock()
                ctl.async { [weak self] in self?.stopRecording() }
            }
        }
    }

    /// Другая клавиша/клик во время удержания — модификатор был шорткатом.
    private func onInterrupt() {
        stateLock.lock()
        let shouldCancel = recording && !locked
        if shouldCancel { stopConsumed = true }
        stateLock.unlock()
        if shouldCancel {
            ctl.async { [weak self] in self?.cancelRecording() }
        }
    }

    // MARK: - запись (ctl-очередь)

    private func startRecording() {
        stateLock.lock()
        let stillRecording = recording
        stateLock.unlock()
        guard stillRecording else { return }   // уже отменили, пока команда ждала

        do {
            try recorder.start()
        } catch {
            stateLock.lock(); recording = false; locked = false; stateLock.unlock()
            log("mic error: \(error)")
            setStatus("exclamationmark.triangle", "Микрофон: \(error)")
            return
        }
        log("recording started")
        playSound("Pop")
        overlayShow(.record)
        setStatus("mic.fill", "Запись…")
    }

    private func stopRecording() {
        stateLock.lock()
        recording = false
        locked = false
        let startedAt = recordStartedAt
        stateLock.unlock()

        let audio = recorder.stop()
        let duration = Date().timeIntervalSince1970 - startedAt
        log("recording stopped, \(String(format: "%.2f", duration))s, \(audio.count) samples")

        if duration < cfg.minDurationSec || audio.isEmpty {
            overlayHide()
            setReadyStatus()
            return
        }
        playSound("Bottle")
        overlayMode(.busy)
        setStatus("waveform", "Распознаю…")

        let audioDur = Double(audio.count) / cfg.sampleRate
        // Имя фронтмост-приложения снимаем на main (без sync — без риска дедлока).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let targetApp = frontmostAppName()
            self.work.async { self.processJob(audio, audioDur: audioDur, targetApp: targetApp) }
        }
    }

    private func cancelRecording() {
        stateLock.lock()
        recording = false
        locked = false
        stateLock.unlock()
        _ = recorder.stop()
        log("recording cancelled (shortcut detected)")
        overlayHide()
        setReadyStatus()
    }

    // MARK: - транскрибация (work-очередь)

    private func processJob(_ audio: [Float], audioDur: Double, targetApp: String) {
        let t0 = Date()
        let prompt = dictionaryPrompt(store)
        var text = transcriber.transcribe(audio, initialPrompt: prompt)
        text = postprocess(text, store: store)
        let dt = Date().timeIntervalSince(t0)

        if text.isEmpty {
            overlayHide()
            setStatus("mic", "Пусто — ничего не расслышал.")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if FocusCheck.focusIsEditable() {
                self.overlay?.collapse()
                Paster.paste(text)
                // Через секунду (текст уже в поле) — начать следить за правками.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.axWatcher.watch(pastedText: text)
                }
            } else {
                // Вставлять некуда — пилл раскрывается в карточку с текстом.
                log("focus not editable — morphing pill into result card")
                self.overlay?.showResult(text)
            }
        }
        // Детект передиктовки: похожая фраза в течение 3 минут → предложить разницу.
        let now = Date().timeIntervalSince1970
        if let last = lastDictation, now - last.ts < 180,
           WordDiff.similarity(last.text, text) >= 0.7 {
            let found = WordDiff.candidates(old: last.text, new: text)
            if !found.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.suggestions.show(found) }
            }
        }
        lastDictation = (text, now)
        if cfg.saveHistory {
            store.addHistory(text: text, duration: audioDur, model: cfg.model, app: targetApp)
        }
        let short = text.count > 40 ? String(text.prefix(40)) + "…" : text
        setStatus("mic", "Вставлено за \(String(format: "%.1f", dt))с: \(short)")
    }
}
