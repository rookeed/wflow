"""Flow Local — хранилище: история диктовок, словарь, сниппеты, статистика.

SQLite в ~/.flow-local/flow.db, потокобезопасно (один коннект + Lock).
Скретчпад — простой текстовый файл ~/.flow-local/scratchpad.txt.
"""

import datetime as dt
import os
import re
import sqlite3
import threading

CONFIG_DIR = os.path.expanduser("~/.flow-local")
DB_PATH = os.path.join(CONFIG_DIR, "flow.db")
SCRATCHPAD_PATH = os.path.join(CONFIG_DIR, "scratchpad.txt")

_WORD_RE = re.compile(r"\w+", re.UNICODE)


def count_words(text):
    return len(_WORD_RE.findall(text or ""))


class Store:
    def __init__(self, db_path=DB_PATH):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        self._lock = threading.Lock()
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._init_schema()

    def _init_schema(self):
        with self._lock:
            self._db.executescript("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                text TEXT NOT NULL,
                words INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                wpm REAL NOT NULL DEFAULT 0,
                model TEXT DEFAULT '',
                app TEXT DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts DESC);
            CREATE TABLE IF NOT EXISTS dictionary (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                word TEXT NOT NULL UNIQUE,
                misheard TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS snippets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trigger TEXT NOT NULL UNIQUE,
                expansion TEXT NOT NULL,
                created REAL NOT NULL
            );
            """)
            self._db.commit()

    def _exec(self, sql, params=()):
        with self._lock:
            cur = self._db.execute(sql, params)
            self._db.commit()
            return cur

    def _query(self, sql, params=()):
        with self._lock:
            return [dict(r) for r in self._db.execute(sql, params).fetchall()]

    # ---------------------------------------------------------- history

    def add_history(self, text, duration, model="", app=""):
        words = count_words(text)
        wpm = (words / (duration / 60.0)) if duration > 0.5 else 0.0
        ts = dt.datetime.now().timestamp()
        self._exec(
            "INSERT INTO history (ts, text, words, duration, wpm, model, app) "
            "VALUES (?,?,?,?,?,?,?)",
            (ts, text, words, duration, round(wpm, 1), model, app))

    def get_history(self, q="", limit=200):
        if q:
            return self._query(
                "SELECT * FROM history WHERE text LIKE ? "
                "ORDER BY ts DESC LIMIT ?", (f"%{q}%", limit))
        return self._query(
            "SELECT * FROM history ORDER BY ts DESC LIMIT ?", (limit,))

    def delete_history(self, item_id):
        self._exec("DELETE FROM history WHERE id=?", (item_id,))

    def clear_history(self):
        self._exec("DELETE FROM history")

    # ---------------------------------------------------------- dictionary

    def get_dictionary(self):
        return self._query("SELECT * FROM dictionary ORDER BY created DESC")

    def add_word(self, word, misheard=""):
        word = (word or "").strip()
        if not word:
            return
        self._exec(
            "INSERT INTO dictionary (word, misheard, created) VALUES (?,?,?) "
            "ON CONFLICT(word) DO UPDATE SET misheard=excluded.misheard",
            (word, (misheard or "").strip(), dt.datetime.now().timestamp()))

    def update_word(self, item_id, word, misheard):
        self._exec("UPDATE dictionary SET word=?, misheard=? WHERE id=?",
                   ((word or "").strip(), (misheard or "").strip(), item_id))

    def delete_word(self, item_id):
        self._exec("DELETE FROM dictionary WHERE id=?", (item_id,))

    # ---------------------------------------------------------- snippets

    def get_snippets(self):
        return self._query("SELECT * FROM snippets ORDER BY created DESC")

    def add_snippet(self, trigger, expansion):
        trigger = (trigger or "").strip()
        if not trigger or not (expansion or "").strip():
            return
        self._exec(
            "INSERT INTO snippets (trigger, expansion, created) VALUES (?,?,?) "
            "ON CONFLICT(trigger) DO UPDATE SET expansion=excluded.expansion",
            (trigger, expansion.strip(), dt.datetime.now().timestamp()))

    def update_snippet(self, item_id, trigger, expansion):
        self._exec("UPDATE snippets SET trigger=?, expansion=? WHERE id=?",
                   ((trigger or "").strip(), (expansion or "").strip(), item_id))

    def delete_snippet(self, item_id):
        self._exec("DELETE FROM snippets WHERE id=?", (item_id,))

    # ---------------------------------------------------------- scratchpad

    def get_scratchpad(self):
        try:
            with open(SCRATCHPAD_PATH) as f:
                return f.read()
        except FileNotFoundError:
            return ""

    def set_scratchpad(self, text):
        with open(SCRATCHPAD_PATH, "w") as f:
            f.write(text or "")

    # ---------------------------------------------------------- stats

    def stats(self):
        rows = self._query(
            "SELECT ts, words, wpm, app FROM history ORDER BY ts DESC")
        total_words = sum(r["words"] for r in rows)
        total_sessions = len(rows)
        wpms = [r["wpm"] for r in rows if r["wpm"] > 0]
        avg_wpm = round(sum(wpms) / len(wpms)) if wpms else 0

        dates = sorted({dt.date.fromtimestamp(r["ts"]) for r in rows},
                       reverse=True)
        weeks = sorted({d.isocalendar()[:2] for d in dates}, reverse=True)

        day_streak = self._streak(
            dates, dt.date.today(), lambda d, n: d - dt.timedelta(days=n))
        week_streak = self._week_streak(weeks)

        # слова по дням, последние 14 дней
        today = dt.date.today()
        by_day = {today - dt.timedelta(days=i): 0 for i in range(14)}
        for r in rows:
            d = dt.date.fromtimestamp(r["ts"])
            if d in by_day:
                by_day[d] += r["words"]
        last14 = [{"date": d.strftime("%d.%m"), "words": by_day[d]}
                  for d in sorted(by_day)]

        apps = {}
        for r in rows:
            app = r["app"] or "—"
            apps[app] = apps.get(app, 0) + 1
        top_apps = sorted(apps.items(), key=lambda kv: -kv[1])[:5]

        return {
            "total_words": total_words,
            "total_sessions": total_sessions,
            "avg_wpm": avg_wpm,
            "day_streak": day_streak,
            "week_streak": week_streak,
            "last14": last14,
            "top_apps": [{"app": a, "count": c} for a, c in top_apps],
        }

    @staticmethod
    def _streak(dates, today, step):
        if not dates:
            return 0
        dset = set(dates)
        start = today if today in dset else step(today, 1)
        if start not in dset:
            return 0
        n, cur = 0, start
        while cur in dset:
            n += 1
            cur = step(start, n)
        return n

    @staticmethod
    def _week_streak(weeks):
        if not weeks:
            return 0
        wset = set(weeks)

        def prev_week(yw, n):
            monday = dt.date.fromisocalendar(yw[0], yw[1], 1)
            back = monday - dt.timedelta(weeks=n)
            return back.isocalendar()[:2]

        cur = dt.date.today().isocalendar()[:2]
        start = cur if cur in wset else prev_week(cur, 1)
        if start not in wset:
            return 0
        n = 0
        while prev_week(start, n) in wset:
            n += 1
        return n
