#!/usr/bin/env python3
"""
Flow Local — приватная локальная альтернатива Wispr Flow.

Пайплайн (как у Wispr Flow, но без облака):
  Fn (удержание = push-to-talk, короткий тап = hands-free с замком)
  → запись микрофона → локальный Whisper → вставка текста в курсор.

Визуальный индикатор: плавающий пилл внизу экрана с живым waveform,
как Flow Bar у Wispr Flow.

Весь звук и текст остаются на этой машине.
"""

import collections
import json
import os
import platform
import queue
import re
import subprocess
import sys
import threading
import time

import numpy as np
import sounddevice as sd
import Quartz
import rumps
import objc
from AppKit import (NSPasteboard, NSPasteboardTypeString, NSPanel, NSView,
                    NSColor, NSBezierPath, NSScreen, NSBackingStoreBuffered,
                    NSWindowStyleMaskBorderless, NSWindowStyleMaskNonactivatingPanel,
                    NSStatusWindowLevel, NSFont, NSFontAttributeName,
                    NSForegroundColorAttributeName, NSWorkspace)
from Foundation import NSOperationQueue, NSTimer, NSString, NSMakeRect

import webui
from store import Store
from dashboard_window import DashboardWindow

# ---------------------------------------------------------------- config

CONFIG_DIR = os.path.expanduser("~/.flow-local")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

DEFAULTS = {
    # 58 = левый Option (⌥). Альтернативы: 61 = правый Option, 63 = Fn,
    # 59/62 = Control, 54 = правый Cmd, 60 = правый Shift.
    "hotkey_keycode": 58,
    # large-v3-turbo / large-v3 / medium / small
    "model": "large-v3-turbo",
    # null = автоопределение языка (ru/en). Можно зафиксировать: "ru".
    "language": None,
    "sample_rate": 16000,
    "min_duration_sec": 0.4,
    # тап короче этого времени = замок (hands-free), длиннее = push-to-talk
    "tap_lock_sec": 0.35,
    "sounds": True,
    "show_overlay": True,
    # писать ли диктовки в историю (дашборд → Настройки)
    "save_history": True,
    # имя для приветствия в дашборде (необязательно)
    "user_name": "",
}

MODIFIER_MASKS = {
    63: Quartz.kCGEventFlagMaskSecondaryFn,
    58: Quartz.kCGEventFlagMaskAlternate,
    61: Quartz.kCGEventFlagMaskAlternate,
    55: Quartz.kCGEventFlagMaskCommand,
    54: Quartz.kCGEventFlagMaskCommand,
    56: Quartz.kCGEventFlagMaskShift,
    60: Quartz.kCGEventFlagMaskShift,
    59: Quartz.kCGEventFlagMaskControl,
    62: Quartz.kCGEventFlagMaskControl,
}

MLX_MODELS = {
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "small": "mlx-community/whisper-small-mlx",
}


LOG_PATH = os.path.join(CONFIG_DIR, "log.txt")


def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
    except Exception:
        pass


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH) as f:
            cfg.update(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            json.dump(DEFAULTS, f, indent=2, ensure_ascii=False)
    return cfg


CFG = load_config()
IS_ARM = platform.machine() == "arm64"

KEY_NAMES = {63: "Fn", 59: "Ctrl", 62: "Ctrl", 58: "Option", 61: "Option",
             55: "Cmd", 54: "Cmd", 56: "Shift", 60: "Shift"}
HOTKEY_NAME = KEY_NAMES.get(CFG["hotkey_keycode"], "клавиша")


# ---------------------------------------------------------------- STT

class Transcriber:
    def __init__(self, model_name, language):
        self.language = language
        self.backend = None
        self.model_name = model_name
        self._model = None

    def load(self):
        if IS_ARM:
            import mlx_whisper as mw
            self.backend = "mlx"
            self.repo = MLX_MODELS.get(self.model_name, self.model_name)
            mw.transcribe(np.zeros(16000, dtype=np.float32),
                          path_or_hf_repo=self.repo, language=self.language)
        else:
            from faster_whisper import WhisperModel
            self.backend = "faster"
            self._model = WhisperModel(self.model_name, device="cpu",
                                       compute_type="int8")

    def transcribe(self, audio, initial_prompt=None):
        if self.backend == "mlx":
            import mlx_whisper as mw
            result = mw.transcribe(audio, path_or_hf_repo=self.repo,
                                   language=self.language,
                                   initial_prompt=initial_prompt or None)
            return result["text"].strip()
        segments, _ = self._model.transcribe(audio, language=self.language,
                                             initial_prompt=initial_prompt or None,
                                             vad_filter=True)
        return " ".join(s.text.strip() for s in segments).strip()


# ---------------------------------------------------------------- audio

class Recorder:
    def __init__(self, sample_rate, level_sink):
        self.sample_rate = sample_rate
        self.level_sink = level_sink   # callable(float 0..1)
        self._frames = []
        self._stream = None
        self._lock = threading.Lock()

    def _callback(self, indata, frames, time_info, status):
        with self._lock:
            self._frames.append(indata.copy())
        try:
            rms = float(np.sqrt(np.mean(indata ** 2)))
            self.level_sink(min(1.0, rms * 14.0))
        except Exception:
            pass

    def start(self):
        with self._lock:
            self._frames = []
        self._stream = sd.InputStream(samplerate=self.sample_rate, channels=1,
                                      dtype="float32", callback=self._callback,
                                      blocksize=1024)
        self._stream.start()

    def stop(self):
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        with self._lock:
            if not self._frames:
                return np.zeros(0, dtype=np.float32)
            audio = np.concatenate(self._frames)[:, 0]
            self._frames = []
        return audio


# ---------------------------------------------------------------- overlay
# Плавающий пилл внизу экрана (аналог Flow Bar у Wispr Flow).

N_BARS = 27


class WaveView(NSView):
    """Пилл: [● / 🔒]  ▂▄▆▄▂ waveform  + подсказка."""

    def initWithFrame_(self, frame):
        self = objc.super(WaveView, self).initWithFrame_(frame)
        if self is None:
            return None
        self.levels = collections.deque([0.0] * N_BARS, maxlen=N_BARS)
        self.mode = "record"          # record | locked | busy
        self.phase = 0.0              # для пульсации точки
        return self

    def push_level(self, v):
        self.levels.append(v)

    def drawRect_(self, rect):
        w = self.bounds().size.width
        h = self.bounds().size.height
        # фон-пилл
        pill = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(0, 0, w, h), h / 2, h / 2)
        NSColor.colorWithCalibratedWhite_alpha_(0.07, 0.93).setFill()
        pill.fill()

        self.phase += 0.25

        # левый значок
        icon_cx, icon_cy = 30.0, h / 2
        if self.mode == "locked":
            self._draw_text("🔒", icon_cx - 10, icon_cy - 9, 15)
        elif self.mode == "busy":
            self._draw_text("✍️", icon_cx - 10, icon_cy - 9, 15)
        else:
            pulse = 0.55 + 0.45 * abs(np.sin(self.phase * 0.5))
            NSColor.colorWithCalibratedRed_green_blue_alpha_(
                1.0, 0.23, 0.19, pulse).setFill()
            dot = NSBezierPath.bezierPathWithOvalInRect_(
                NSMakeRect(icon_cx - 6, icon_cy - 6, 12, 12))
            dot.fill()

        # waveform
        bars_x0, bars_x1 = 52.0, w - 96.0
        if self.mode == "busy":
            bars_x1 = w - 16.0
        n = N_BARS
        step = (bars_x1 - bars_x0) / n
        bw = max(2.0, step * 0.55)
        NSColor.colorWithCalibratedWhite_alpha_(0.95, 0.95).setFill()
        levels = list(self.levels)
        for i in range(n):
            if self.mode == "busy":
                lv = 0.25 + 0.2 * abs(np.sin(self.phase * 0.6 + i * 0.5))
            else:
                lv = levels[i]
            bh = 3.0 + lv * (h - 18.0)
            x = bars_x0 + i * step
            y = (h - bh) / 2
            bar = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                NSMakeRect(x, y, bw, bh), bw / 2, bw / 2)
            bar.fill()

        # подсказка справа
        if self.mode == "locked":
            self._draw_text(f"{HOTKEY_NAME} — стоп", w - 86, h / 2 - 7, 11,
                            grey=True)
        elif self.mode == "record":
            self._draw_text("тап = 🔒", w - 86, h / 2 - 7, 11, grey=True)

    def _draw_text(self, s, x, y, size, grey=False):
        color = (NSColor.colorWithCalibratedWhite_alpha_(0.7, 0.9) if grey
                 else NSColor.whiteColor())
        attrs = {NSFontAttributeName: NSFont.systemFontOfSize_(size),
                 NSForegroundColorAttributeName: color}
        NSString.stringWithString_(s).drawAtPoint_withAttributes_((x, y), attrs)

    def tick_(self, timer):
        self.setNeedsDisplay_(True)

    def isFlipped(self):
        return False


class Overlay:
    """Управление панелью. Все вызовы — только с main thread."""

    W, H = 320, 46

    def __init__(self):
        screen = NSScreen.mainScreen().frame()
        x = (screen.size.width - self.W) / 2.0
        y = 88.0
        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(x, y, self.W, self.H),
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered, False)
        self.panel.setLevel_(NSStatusWindowLevel)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setIgnoresMouseEvents_(True)
        self.panel.setHidesOnDeactivate_(False)
        self.panel.setCollectionBehavior_(1)  # canJoinAllSpaces
        self.view = WaveView.alloc().initWithFrame_(NSMakeRect(0, 0, self.W, self.H))
        self.panel.setContentView_(self.view)
        self._timer = None

    def show(self, mode):
        self.view.mode = mode
        self.view.levels.extend([0.0] * N_BARS)
        if self._timer is None:
            self._timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                1.0 / 30.0, self.view, "tick:", None, True)
        self.panel.orderFrontRegardless()

    def set_mode(self, mode):
        self.view.mode = mode

    def hide(self):
        if self._timer is not None:
            self._timer.invalidate()
            self._timer = None
        self.panel.orderOut_(None)


# ---------------------------------------------------------------- helpers

def paste_text(text):
    pb = NSPasteboard.generalPasteboard()
    old = pb.stringForType_(NSPasteboardTypeString)
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)
    time.sleep(0.08)
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for key_down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(src, 9, key_down)  # 9 = 'v'
        Quartz.CGEventSetFlags(ev, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)
        time.sleep(0.02)
    if old is not None:
        def restore():
            pb2 = NSPasteboard.generalPasteboard()
            pb2.clearContents()
            pb2.setString_forType_(old, NSPasteboardTypeString)
        threading.Timer(0.7, restore).start()


def frontmost_app_name():
    try:
        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        return str(app.localizedName()) if app else ""
    except Exception:
        return ""


def set_clipboard(text):
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)


def _norm_phrase(s):
    """Нормализация для сравнения с триггером сниппета."""
    return re.sub(r"[^\w\s]", "", s or "", flags=re.UNICODE).lower().strip()


def postprocess_text(text, store):
    """Автозамены из словаря + подстановка сниппетов."""
    # 1) словарь: «ослышка → правильное слово»
    for entry in store.get_dictionary():
        variants = [v.strip() for v in (entry["misheard"] or "").split(",")
                    if v.strip()]
        for var in variants:
            text = re.sub(re.escape(var), entry["word"], text,
                          flags=re.IGNORECASE)
    # 2) сниппеты: сказанная фраза-триггер → готовый текст
    tnorm = _norm_phrase(text)
    for sn in store.get_snippets():
        trig = _norm_phrase(sn["trigger"])
        if trig and trig == tnorm:
            return sn["expansion"]
    return text


def dictionary_prompt(store):
    """Слова из словаря — как подсказка (initial_prompt) для Whisper."""
    words = [e["word"] for e in store.get_dictionary()]
    if not words:
        return None
    return "Словарь: " + ", ".join(words[:60]) + "."


def play(sound_name):
    if CFG["sounds"]:
        subprocess.Popen(
            ["afplay", f"/System/Library/Sounds/{sound_name}.aiff"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def on_main(fn):
    NSOperationQueue.mainQueue().addOperationWithBlock_(fn)


# ---------------------------------------------------------------- app

class FlowLocalApp(rumps.App):
    def __init__(self):
        super().__init__("⏳", quit_button=rumps.MenuItem("Выйти"))
        self.status_item = rumps.MenuItem("Загрузка модели…")
        self.help_item = rumps.MenuItem(
            f"{HOTKEY_NAME}: держать = говорить, тап = замок 🔒, ещё тап = стоп")
        self.model_item = rumps.MenuItem(f"Модель: {CFG['model']}"
                                         + (" (MLX)" if IS_ARM else " (CPU)"))
        self.open_item = rumps.MenuItem("Открыть Flow Local…",
                                        callback=self._open_dashboard)
        self.menu = [self.open_item, None, self.status_item, self.help_item,
                     self.model_item]

        # ---- хранилище + веб-дашборд (история, словарь, сниппеты, настройки)
        self.store = Store()
        # значения на момент старта процесса: перезапуск нужен, только если
        # текущий конфиг реально от них отличается
        self._boot_cfg = {"hotkey_keycode": CFG["hotkey_keycode"],
                          "model": CFG["model"]}
        self.dashboard = DashboardWindow()
        self.dashboard_url = webui.start_server(self.store, {
            "get_config": lambda: dict(CFG),
            "needs_restart": self._needs_restart_now,
            "apply_settings": self._apply_settings,
            "restart": self._restart,
            "copy": lambda t: on_main(lambda: set_clipboard(t)),
        })
        log(f"dashboard at {self.dashboard_url}")

        self.recorder = Recorder(CFG["sample_rate"], self._push_level)
        self.transcriber = Transcriber(CFG["model"], CFG["language"])
        self.overlay = None  # создаётся на main thread при первом запуске
        self.ready = False
        self.recording = False
        self.locked = False
        self._press_time = 0.0
        self._stop_consumed = False
        self.record_started_at = 0.0
        self.jobs = queue.Queue()
        # Команды start/stop/cancel выполняются в отдельном потоке,
        # чтобы event tap callback оставался мгновенным (иначе macOS
        # отключает tap за медлительность).
        self.ctl = queue.Queue()

        self._tap = None
        threading.Thread(target=self._load_model, daemon=True).start()
        threading.Thread(target=self._worker, daemon=True).start()
        threading.Thread(target=self._ctl_worker, daemon=True).start()
        # Слушатель клавиш — на ВЫДЕЛЕННОМ потоке с собственным run loop,
        # чтобы его не «морил» главный поток во время работы модели.
        threading.Thread(target=self._tap_thread, daemon=True).start()
        # Watchdog-подстраховка на главном потоке.
        self._watchdog = rumps.Timer(self._check_tap, 2)
        self._watchdog.start()

    # ---- дашборд
    def _open_dashboard(self, _sender=None):
        # rumps-колбэки уже на main thread, но подстрахуемся
        on_main(lambda: self.dashboard.show(self.dashboard_url))

    def _needs_restart_now(self):
        return any(CFG.get(k) != v for k, v in self._boot_cfg.items())

    def _apply_settings(self, changes):
        """Применить настройки из дашборда. Возвращает needs_restart."""
        allowed = {"hotkey_keycode", "model", "language", "sounds",
                   "show_overlay", "save_history", "user_name",
                   "min_duration_sec", "tap_lock_sec"}
        for k, v in changes.items():
            if k not in allowed or CFG.get(k) == v:
                continue
            CFG[k] = v
            if k == "language":
                self.transcriber.language = v or None
        with open(CONFIG_PATH, "w") as f:
            json.dump(CFG, f, indent=2, ensure_ascii=False)
        needs = self._needs_restart_now()
        log(f"settings applied: {changes}, needs_restart={needs}")
        return needs

    def _restart(self):
        log("restart requested from dashboard")

        def do_restart():
            time.sleep(0.4)
            os.execv(sys.executable, [sys.executable] + sys.argv)
        threading.Thread(target=do_restart, daemon=True).start()

    # ---- overlay (только main thread)
    def _overlay_do(self, action, mode=None):
        if not CFG["show_overlay"]:
            return
        def run():
            if self.overlay is None:
                self.overlay = Overlay()
            if action == "show":
                self.overlay.show(mode)
            elif action == "mode":
                self.overlay.set_mode(mode)
            elif action == "hide":
                self.overlay.hide()
        on_main(run)

    def _push_level(self, v):
        if self.overlay is not None:
            self.overlay.view.push_level(v)  # deque — потокобезопасно

    # ---- модель
    def _load_model(self):
        try:
            self.transcriber.load()
            self.ready = True
            log("model loaded, ready")
            self._set_status("🎙", f"Готов. {HOTKEY_NAME}: держать или тап.")
        except Exception as e:
            log(f"model load ERROR: {e}")
            self._set_status("⚠️", f"Ошибка загрузки модели: {e}")

    def _set_status(self, icon, text):
        def apply():
            self.title = icon
            self.status_item.title = text
        on_main(apply)

    # ---- hotkey (собственный поток + run loop)
    def _tap_thread(self):
        keycode = CFG["hotkey_keycode"]
        mask_bit = MODIFIER_MASKS.get(keycode) or Quartz.kCGEventFlagMaskAlternate
        self._flag_down = False   # текущее состояние клавиши-модификатора

        def callback(proxy, etype, event, refcon):
            # ВАЖНО: никаких тяжёлых операций здесь — только флаги и очередь.
            try:
                if etype in (Quartz.kCGEventTapDisabledByTimeout,
                             Quartz.kCGEventTapDisabledByUserInput):
                    log(f"tap disabled (etype={etype}), re-enabling")
                    if self._tap is not None:
                        Quartz.CGEventTapEnable(self._tap, True)
                    return event
                if etype in (Quartz.kCGEventLeftMouseDown,
                             Quartz.kCGEventRightMouseDown):
                    if self.recording and not self.locked:
                        self._stop_consumed = True
                        self.ctl.put("cancel")
                    return event
                if etype == Quartz.kCGEventKeyDown:
                    # Модификатор+клавиша = шорткат: тихо отменяем.
                    if self.recording and not self.locked:
                        self._stop_consumed = True
                        self.ctl.put("cancel")
                    return event
                if etype != Quartz.kCGEventFlagsChanged:
                    return event
                # Реагируем только на нужную физическую клавишу (напр. правый
                # Option = 61), а состояние берём из перехода флага модификатора.
                kc = Quartz.CGEventGetIntegerValueField(
                    event, Quartz.kCGKeyboardEventKeycode)
                if kc != keycode:
                    return event
                flags = Quartz.CGEventGetFlags(event)
                down = bool(flags & mask_bit)
                if down != self._flag_down:
                    self._flag_down = down
                    log(f"hotkey {'DOWN' if down else 'UP'} (kc={kc})")
                    self._on_hotkey(down)
            except Exception as e:
                log(f"tap callback error: {e}")
            return event

        tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionListenOnly,
            Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
            | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventRightMouseDown),
            callback, None)
        if tap is None:
            log("tap create FAILED (нет Input Monitoring)")
            self._set_status("⚠️", "Нет доступа: включи Универсальный доступ "
                                   "и Мониторинг ввода в Настройках.")
            return
        source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
        loop = Quartz.CFRunLoopGetCurrent()   # run loop ЭТОГО потока
        Quartz.CFRunLoopAddSource(loop, source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(tap, True)
        self._tap = tap
        log(f"tap installed on dedicated thread (key={keycode})")
        # Бесконечно крутим свой run loop — поток занят только клавишами.
        Quartz.CFRunLoopRun()

    def _check_tap(self, _timer=None):
        """Watchdog-подстраховка: реанимирует tap, если macOS его отключил."""
        try:
            if self._tap is not None and not Quartz.CGEventTapIsEnabled(self._tap):
                Quartz.CGEventTapEnable(self._tap, True)
        except Exception:
            pass

    def _on_hotkey(self, pressed):
        """Держать = PTT. Короткий тап = замок. Тап при замке = стоп.
        Вызывается из event tap — только флаги и очередь, ничего тяжёлого."""
        now = time.time()
        if pressed:
            self._press_time = now
            if self.recording and self.locked:
                self._stop_consumed = True
                self.locked = False
                self.ctl.put("stop")
            elif not self.recording and self.ready:
                # Флаг ставим сразу (оптимистично), тяжёлый старт — в потоке.
                self._stop_consumed = False
                self.recording = True
                self.record_started_at = now
                self.ctl.put("start")
        else:
            if self._stop_consumed or not self.recording:
                return
            if now - self._press_time < CFG["tap_lock_sec"]:
                self.locked = True
                play("Morse")
                self._overlay_do("mode", "locked")
                self._set_status("🔒", f"Hands-free: говори. {HOTKEY_NAME} — стоп.")
            else:
                self.ctl.put("stop")

    def _ctl_worker(self):
        """Тяжёлые операции с аудио — вне event tap потока."""
        while True:
            cmd = self.ctl.get()
            try:
                if cmd == "start":
                    self._start_recording()
                elif cmd == "stop":
                    self._stop_recording()
                elif cmd == "cancel":
                    self._cancel_recording()
            except Exception as e:
                log(f"ctl {cmd} error: {e}")

    def _cancel_recording(self):
        """Отмена без вставки (модификатор использован как шорткат)."""
        if not self.recording:
            return
        self.recording = False
        self.locked = False
        try:
            self.recorder.stop()
        except Exception:
            pass
        log("recording cancelled (shortcut detected)")
        self._overlay_do("hide")
        self._set_status("🎙", f"Готов. {HOTKEY_NAME}: держать или тап.")

    # ---- запись (выполняется в ctl-потоке)
    def _start_recording(self):
        if not self.recording:
            return  # уже отменили, пока команда ждала
        try:
            self.recorder.start()
        except Exception as e:
            self.recording = False
            log(f"mic error: {e}")
            self._set_status("⚠️", f"Микрофон: {e}")
            return
        log("recording started")
        play("Pop")
        self._overlay_do("show", "record")
        self._set_status("🔴", "Запись…")

    def _stop_recording(self):
        self.recording = False
        self.locked = False
        audio = self.recorder.stop()
        duration = time.time() - self.record_started_at
        log(f"recording stopped, {duration:.2f}s, {audio.size} samples")
        if duration < CFG["min_duration_sec"] or audio.size == 0:
            self._overlay_do("hide")
            self._set_status("🎙", f"Готов. {HOTKEY_NAME}: держать или тап.")
            return
        play("Bottle")
        self._overlay_do("mode", "busy")
        self._set_status("✍️", "Распознаю…")
        # приложение, куда будет вставлен текст — снимаем в момент стопа
        target_app = frontmost_app_name()
        audio_dur = audio.size / float(CFG["sample_rate"])
        self.jobs.put((audio, audio_dur, target_app))

    # ---- транскрибация
    def _worker(self):
        while True:
            audio, audio_dur, target_app = self.jobs.get()
            try:
                t0 = time.time()
                prompt = dictionary_prompt(self.store)
                text = self.transcriber.transcribe(audio, initial_prompt=prompt)
                text = postprocess_text(text, self.store)
                dt = time.time() - t0
                self._overlay_do("hide")
                if text:
                    on_main(lambda t=text: paste_text(t))
                    if CFG.get("save_history", True):
                        try:
                            self.store.add_history(text, audio_dur,
                                                   model=CFG["model"],
                                                   app=target_app)
                        except Exception as e:
                            log(f"history save error: {e}")
                    short = text[:40] + "…" if len(text) > 40 else text
                    self._set_status("🎙", f"Вставлено за {dt:.1f}с: {short}")
                else:
                    self._set_status("🎙", "Пусто — ничего не расслышал.")
            except Exception as e:
                self._overlay_do("hide")
                self._set_status("⚠️", f"Ошибка распознавания: {e}")


def acquire_single_instance_lock():
    import fcntl
    lock_path = os.path.join(CONFIG_DIR, "app.lock")
    os.makedirs(CONFIG_DIR, exist_ok=True)
    fd = open(lock_path, "w")
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit("Flow Local уже запущен.")
    fd.write(str(os.getpid()))
    fd.flush()
    return fd


if __name__ == "__main__":
    import multiprocessing
    multiprocessing.freeze_support()

    if sys.platform != "darwin":
        sys.exit("Flow Local работает только на macOS.")
    _lock = acquire_single_instance_lock()
    FlowLocalApp().run()
