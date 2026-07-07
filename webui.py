"""Flow Local — локальный веб-дашборд (история, словарь, сниппеты, настройки).

HTTP-сервер только на 127.0.0.1, доступ по токену (генерируется на запуск).
Никаких внешних ресурсов: один HTML со встроенными CSS/JS.
"""

import json
import secrets
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = secrets.token_hex(16)
PORT_PREF = 47811

VERSION = "2.0"

# ------------------------------------------------------------------ HTML

HTML = r"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<title>Flow Local</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root {
  --bg:#f5f3ee; --side:#efece5; --card:#fbfaf7; --line:#e5e1d8;
  --text:#211f1c; --muted:#8a857a; --accent:#191713; --danger:#c0392b;
}
* { box-sizing:border-box; margin:0; padding:0; }
body { font:14px/1.5 -apple-system,'Helvetica Neue',sans-serif;
  background:var(--bg); color:var(--text); height:100vh; display:flex;
  overflow:hidden; -webkit-user-select:none; user-select:none; }
h1 { font:400 34px/1.2 Georgia,'Times New Roman',serif; margin-bottom:24px; }
h2 { font:400 20px/1.3 Georgia,serif; margin:20px 0 12px; }

/* ---------- sidebar ---------- */
#side { width:230px; min-width:230px; background:var(--side);
  border-right:1px solid var(--line); display:flex; flex-direction:column;
  padding:18px 12px; }
#logo { font:600 19px/1 -apple-system,sans-serif; padding:6px 10px 20px;
  display:flex; align-items:center; gap:8px; }
#logo .badge { font:500 10px/1 -apple-system; color:var(--muted);
  border:1px solid var(--line); border-radius:6px; padding:3px 6px; }
.nav { display:flex; flex-direction:column; gap:2px; }
.nav button { all:unset; cursor:pointer; padding:9px 10px; border-radius:9px;
  display:flex; gap:10px; align-items:center; font-size:14px; color:var(--text); }
.nav button:hover { background:rgba(0,0,0,.045); }
.nav button.active { background:rgba(0,0,0,.075); font-weight:600; }
.nav .ic { width:18px; text-align:center; opacity:.75; }
#side .grow { flex:1; }
#ver { color:var(--muted); font-size:11px; padding:10px; }

/* ---------- main ---------- */
#main { flex:1; overflow-y:auto; padding:44px 56px; }
.page { display:none; max-width:980px; }
.page.visible { display:block; }
.card { background:var(--card); border:1px solid var(--line);
  border-radius:14px; padding:18px 20px; }
.row { display:flex; gap:16px; align-items:center; }
.muted { color:var(--muted); }
button.btn { all:unset; cursor:pointer; background:var(--accent); color:#fff;
  padding:9px 16px; border-radius:10px; font-size:13px; font-weight:500; }
button.btn.ghost { background:transparent; color:var(--text);
  border:1px solid var(--line); }
button.btn:active { opacity:.75; }
input[type=text], input[type=search], textarea, select {
  font:14px -apple-system,sans-serif; color:var(--text);
  background:#fff; border:1px solid var(--line); border-radius:10px;
  padding:9px 12px; outline:none; -webkit-user-select:text; user-select:text; }
input:focus, textarea:focus { border-color:#b9b2a2; }

/* toggle */
.toggle { position:relative; width:44px; height:26px; flex:none; }
.toggle input { opacity:0; width:0; height:0; }
.toggle span { position:absolute; inset:0; background:#d8d3c8;
  border-radius:13px; transition:.15s; cursor:pointer; }
.toggle span:before { content:""; position:absolute; width:20px; height:20px;
  left:3px; top:3px; background:#fff; border-radius:50%; transition:.15s; }
.toggle input:checked + span { background:var(--accent); }
.toggle input:checked + span:before { transform:translateX(18px); }

/* ---------- home ---------- */
#home-top { display:flex; gap:24px; align-items:flex-start; }
#home-left { flex:1; min-width:0; }
#statcard { width:250px; flex:none; }
#statcard .big { font:400 26px/1.1 Georgia,serif; }
#statcard .item { padding:10px 0; border-bottom:1px solid var(--line);
  display:flex; align-items:baseline; gap:8px; }
#statcard .item:last-child { border-bottom:0; }
#histsearch { width:100%; margin:18px 0 6px; }
.datehdr { font:600 11px/1 -apple-system; letter-spacing:.08em;
  color:var(--muted); text-transform:uppercase; margin:22px 0 4px; }
.hrow { display:flex; gap:14px; padding:13px 10px;
  border-bottom:1px solid var(--line); align-items:flex-start; }
.hrow:hover { background:rgba(0,0,0,.02); }
.hrow .time { width:70px; flex:none; color:var(--muted); font-size:12px;
  padding-top:2px; }
.hrow .txt { flex:1; min-width:0; white-space:pre-wrap; word-break:break-word;
  -webkit-user-select:text; user-select:text; }
.hrow .meta { font-size:11px; color:var(--muted); margin-top:3px; }
.hrow .acts { flex:none; display:flex; gap:4px; opacity:0; transition:.12s; }
.hrow:hover .acts { opacity:1; }
.iconbtn { all:unset; cursor:pointer; padding:4px 7px; border-radius:7px;
  font-size:13px; }
.iconbtn:hover { background:rgba(0,0,0,.07); }

/* ---------- insights ---------- */
#insight-cards { display:grid; grid-template-columns:repeat(4,1fr); gap:14px;
  margin-bottom:24px; }
#insight-cards .card .n { font:400 30px/1.1 Georgia,serif; }
#insight-cards .card .l { color:var(--muted); font-size:12px; margin-top:4px; }
#chart { display:flex; gap:6px; align-items:flex-end; height:140px;
  padding:12px 4px 0; }
#chart .bar { flex:1; background:var(--accent); border-radius:4px 4px 0 0;
  min-height:2px; opacity:.85; }
#chart-labels { display:flex; gap:6px; }
#chart-labels div { flex:1; text-align:center; font-size:9px;
  color:var(--muted); }
.applist .hrow { padding:10px 6px; }

/* ---------- dictionary / snippets ---------- */
.addform { display:flex; gap:10px; margin-bottom:18px; flex-wrap:wrap; }
.addform input[type=text] { flex:1; min-width:160px; }
.addform textarea { flex-basis:100%; min-height:60px; resize:vertical; }
.itemrow { display:flex; gap:10px; padding:12px 8px; align-items:center;
  border-bottom:1px solid var(--line); }
.itemrow input, .itemrow textarea { flex:1; background:transparent;
  border-color:transparent; }
.itemrow input:hover, .itemrow textarea:hover { border-color:var(--line); }
.itemrow input:focus, .itemrow textarea:focus { border-color:#b9b2a2;
  background:#fff; }
.itemrow textarea { resize:vertical; min-height:38px; }

/* ---------- scratchpad ---------- */
#scratch { width:100%; height:60vh; resize:none; font-size:15px;
  line-height:1.6; }

/* ---------- settings ---------- */
.setrow { display:flex; align-items:center; justify-content:space-between;
  gap:20px; padding:16px 0; border-bottom:1px solid var(--line); }
.setrow:last-child { border-bottom:0; }
.setrow .lbl b { display:block; font-weight:600; }
.setrow .lbl span { color:var(--muted); font-size:12px; }
#restartbar { display:none; margin-top:16px; padding:12px 16px;
  background:#fff6e0; border:1px solid #ecd9a0; border-radius:12px;
  align-items:center; justify-content:space-between; }
#restartbar.visible { display:flex; }

.toast { position:fixed; bottom:24px; left:50%; transform:translateX(-50%);
  background:var(--accent); color:#fff; padding:10px 18px; border-radius:10px;
  font-size:13px; opacity:0; transition:.2s; pointer-events:none; z-index:9; }
.toast.visible { opacity:1; }
.empty { color:var(--muted); text-align:center; padding:40px 0; }
</style>
</head>
<body>
<div id="side">
  <div id="logo">〰 Flow Local <span class="badge">Приватный</span></div>
  <div class="nav">
    <button data-page="home" class="active"><span class="ic">⌂</span>Главная</button>
    <button data-page="insights"><span class="ic">◔</span>Статистика</button>
    <button data-page="dict"><span class="ic">✎</span>Словарь</button>
    <button data-page="snip"><span class="ic">✂</span>Сниппеты</button>
    <button data-page="scratch-page"><span class="ic">▤</span>Черновик</button>
  </div>
  <div class="grow"></div>
  <div class="nav">
    <button data-page="settings"><span class="ic">⚙</span>Настройки</button>
  </div>
  <div id="ver">Flow Local v__VERSION__ · всё локально</div>
</div>

<div id="main">

  <!-- ================= HOME ================= -->
  <div class="page visible" id="page-home">
    <h1 id="greet">С возвращением</h1>
    <div id="home-top">
      <div id="home-left">
        <input type="search" id="histsearch" placeholder="Поиск по истории…">
        <div id="histlist"></div>
      </div>
      <div class="card" id="statcard">
        <div class="item"><span class="big" id="st-words">0</span>
          <span class="muted">слов всего</span></div>
        <div class="item"><span class="big" id="st-wpm">0</span>
          <span class="muted">слов/мин</span></div>
        <div class="item"><span class="big" id="st-streak">0</span>
          <span class="muted">недель подряд</span></div>
      </div>
    </div>
  </div>

  <!-- ================= INSIGHTS ================= -->
  <div class="page" id="page-insights">
    <h1>Статистика</h1>
    <div id="insight-cards">
      <div class="card"><div class="n" id="in-words">0</div>
        <div class="l">слов всего</div></div>
      <div class="card"><div class="n" id="in-sessions">0</div>
        <div class="l">диктовок</div></div>
      <div class="card"><div class="n" id="in-wpm">0</div>
        <div class="l">слов/мин в среднем</div></div>
      <div class="card"><div class="n" id="in-daystreak">0</div>
        <div class="l">дней подряд</div></div>
    </div>
    <div class="card">
      <h2 style="margin-top:0">Слова за 14 дней</h2>
      <div id="chart"></div>
      <div id="chart-labels"></div>
    </div>
    <div class="card applist" style="margin-top:16px">
      <h2 style="margin-top:0">Куда диктуешь чаще всего</h2>
      <div id="topapps"></div>
    </div>
  </div>

  <!-- ================= DICTIONARY ================= -->
  <div class="page" id="page-dict">
    <h1>Словарь</h1>
    <p class="muted" style="margin:-12px 0 18px">Свои слова, имена и термины.
      Подаются модели как подсказка; «ослышки» исправляются автоматически.</p>
    <div class="addform card">
      <input type="text" id="dw" placeholder="Слово как надо (напр. Wispr Flow)">
      <input type="text" id="dm" placeholder="Ослышки через запятую (виспер флоу, виспр флов)">
      <button class="btn" onclick="addWord()">Добавить</button>
    </div>
    <div id="dictlist"></div>
  </div>

  <!-- ================= SNIPPETS ================= -->
  <div class="page" id="page-snip">
    <h1>Сниппеты</h1>
    <p class="muted" style="margin:-12px 0 18px">Скажи фразу-триггер —
      вставится готовый текст (подпись, e-mail, реквизиты…).</p>
    <div class="addform card">
      <input type="text" id="sw" placeholder="Триггер (напр. «моя подпись»)">
      <textarea id="se" placeholder="Текст, который вставится"></textarea>
      <button class="btn" onclick="addSnippet()">Добавить</button>
    </div>
    <div id="sniplist"></div>
  </div>

  <!-- ================= SCRATCHPAD ================= -->
  <div class="page" id="page-scratch-page">
    <h1>Черновик</h1>
    <p class="muted" style="margin:-12px 0 14px">Заметки под рукой.
      Сохраняется автоматически. <span id="scratch-status"></span></p>
    <textarea id="scratch" placeholder="Пиши или диктуй сюда…"></textarea>
    <div class="row" style="margin-top:12px">
      <button class="btn ghost" onclick="copyScratch()">Скопировать всё</button>
      <button class="btn ghost" onclick="confirmClick(this, clearScratch)">Очистить</button>
    </div>
  </div>

  <!-- ================= SETTINGS ================= -->
  <div class="page" id="page-settings">
    <h1>Настройки</h1>
    <div class="card">
      <div class="setrow">
        <div class="lbl"><b>Горячая клавиша</b>
          <span>Держать — говорить; короткий тап — hands-free замок</span></div>
        <select id="cfg-hotkey">
          <option value="63">Fn</option>
          <option value="58">Левый Option ⌥</option>
          <option value="61">Правый Option ⌥</option>
          <option value="54">Правый Cmd ⌘</option>
          <option value="59">Левый Ctrl ⌃</option>
          <option value="60">Правый Shift ⇧</option>
        </select>
      </div>
      <div class="setrow">
        <div class="lbl"><b>Модель распознавания</b>
          <span>Точнее = медленнее. turbo — оптимум</span></div>
        <select id="cfg-model">
          <option value="large-v3-turbo">large-v3-turbo</option>
          <option value="large-v3">large-v3 (максимум качества)</option>
          <option value="medium">medium (быстрее)</option>
          <option value="small">small (самая быстрая)</option>
        </select>
      </div>
      <div class="setrow">
        <div class="lbl"><b>Язык</b>
          <span>Авто понимает RU/EN вперемешку</span></div>
        <select id="cfg-language">
          <option value="">Авто (RU + EN)</option>
          <option value="ru">Только русский</option>
          <option value="en">Только английский</option>
        </select>
      </div>
      <div class="setrow">
        <div class="lbl"><b>Звуки</b>
          <span>Сигналы начала/конца записи</span></div>
        <label class="toggle"><input type="checkbox" id="cfg-sounds"><span></span></label>
      </div>
      <div class="setrow">
        <div class="lbl"><b>Индикатор записи (Flow Bar)</b>
          <span>Плавающая полоска с waveform внизу экрана</span></div>
        <label class="toggle"><input type="checkbox" id="cfg-show_overlay"><span></span></label>
      </div>
      <div class="setrow">
        <div class="lbl"><b>Сохранять историю</b>
          <span>Выключи — и диктовки не будут записываться в базу</span></div>
        <label class="toggle"><input type="checkbox" id="cfg-save_history"><span></span></label>
      </div>
    </div>
    <div id="restartbar">
      <span>Изменения клавиши/модели вступят в силу после перезапуска.</span>
      <button class="btn" onclick="doRestart()">Перезапустить</button>
    </div>
    <div class="row" style="margin-top:20px">
      <button class="btn ghost" style="color:var(--danger)"
        onclick="confirmClick(this, clearHistory)">Очистить всю историю</button>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
const TOKEN = "__TOKEN__";
const $ = s => document.querySelector(s);

async function api(path, body) {
  const opts = { headers: { "X-Flow-Token": TOKEN } };
  if (body !== undefined) {
    opts.method = "POST";
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.add("visible");
  clearTimeout(t._h);
  t._h = setTimeout(() => t.classList.remove("visible"), 1600);
}

/* confirm() в WKWebView не работает — двухшаговое подтверждение кнопкой */
function confirmClick(btn, fn) {
  if (btn.dataset.armed) {
    delete btn.dataset.armed;
    btn.textContent = btn.dataset.orig;
    fn();
    return;
  }
  btn.dataset.orig = btn.textContent;
  btn.dataset.armed = "1";
  btn.textContent = "Точно? Нажми ещё раз";
  setTimeout(() => {
    if (btn.dataset.armed) {
      delete btn.dataset.armed;
      btn.textContent = btn.dataset.orig;
    }
  }, 3000);
}

function esc(s) {
  return (s || "").replace(/[&<>"]/g,
    c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;" }[c]));
}

/* ---------------- nav ---------------- */
document.querySelectorAll(".nav button").forEach(b => {
  b.onclick = () => {
    document.querySelectorAll(".nav button").forEach(x =>
      x.classList.toggle("active", x === b));
    document.querySelectorAll(".page").forEach(p =>
      p.classList.remove("visible"));
    $("#page-" + b.dataset.page).classList.add("visible");
    refresh(b.dataset.page);
  };
});

/* ---------------- home / history ---------------- */
function dayLabel(ts) {
  const d = new Date(ts * 1000), now = new Date();
  const sameDay = (a, b) => a.toDateString() === b.toDateString();
  if (sameDay(d, now)) return "Сегодня";
  const y = new Date(now); y.setDate(y.getDate() - 1);
  if (sameDay(d, y)) return "Вчера";
  return d.toLocaleDateString("ru-RU",
    { day: "numeric", month: "long", year: "numeric" });
}

async function loadHistory() {
  const q = $("#histsearch").value.trim();
  const items = await api("/api/history?q=" + encodeURIComponent(q));
  const box = $("#histlist");
  if (!items.length) {
    box.innerHTML = '<div class="empty">Пока пусто. Зажми горячую клавишу и скажи что-нибудь.</div>';
    return;
  }
  let html = "", lastDay = "";
  for (const it of items) {
    const dl = dayLabel(it.ts);
    if (dl !== lastDay) { html += `<div class="datehdr">${dl}</div>`; lastDay = dl; }
    const time = new Date(it.ts * 1000).toLocaleTimeString("ru-RU",
      { hour: "2-digit", minute: "2-digit" });
    const meta = [it.app, it.wpm ? it.wpm + " слов/мин" : ""]
      .filter(Boolean).join(" · ");
    html += `<div class="hrow">
      <div class="time">${time}</div>
      <div class="txt">${esc(it.text)}${meta ? `<div class="meta">${esc(meta)}</div>` : ""}</div>
      <div class="acts">
        <button class="iconbtn" title="Скопировать" onclick="copyText(${it.id})">⧉</button>
        <button class="iconbtn" title="Удалить" onclick="delHist(${it.id})">🗑</button>
      </div></div>`;
  }
  box.innerHTML = html;
  window._hist = Object.fromEntries(items.map(i => [i.id, i.text]));
}

async function copyText(id) {
  await api("/api/copy", { text: window._hist[id] });
  toast("Скопировано");
}
async function delHist(id) {
  await api("/api/history/delete", { id });
  loadHistory(); loadState();
}
async function clearHistory() {
  if (!confirm("Удалить всю историю диктовок?")) return;
  await api("/api/history/clear", {});
  toast("История очищена"); loadHistory(); loadState();
}
let _st;
$("#histsearch").addEventListener("input", () => {
  clearTimeout(_st); _st = setTimeout(loadHistory, 250);
});

/* ---------------- state / stats / settings ---------------- */
async function loadState() {
  const s = await api("/api/state");
  const st = s.stats;
  $("#greet").textContent = "С возвращением" +
    (s.config.user_name ? ", " + s.config.user_name : "");
  $("#st-words").textContent = st.total_words.toLocaleString("ru-RU");
  $("#st-wpm").textContent = st.avg_wpm;
  $("#st-streak").textContent = st.week_streak;
  $("#in-words").textContent = st.total_words.toLocaleString("ru-RU");
  $("#in-sessions").textContent = st.total_sessions.toLocaleString("ru-RU");
  $("#in-wpm").textContent = st.avg_wpm;
  $("#in-daystreak").textContent = st.day_streak;

  const mx = Math.max(1, ...st.last14.map(d => d.words));
  $("#chart").innerHTML = st.last14.map(d =>
    `<div class="bar" style="height:${Math.round(d.words / mx * 100)}%"
      title="${d.date}: ${d.words} слов"></div>`).join("");
  $("#chart-labels").innerHTML =
    st.last14.map(d => `<div>${d.date.slice(0, 2)}</div>`).join("");
  $("#topapps").innerHTML = st.top_apps.map(a =>
    `<div class="hrow"><div class="txt">${esc(a.app)}</div>
     <div class="muted">${a.count}</div></div>`).join("") ||
    '<div class="empty">Нет данных</div>';

  const c = s.config;
  $("#cfg-hotkey").value = String(c.hotkey_keycode);
  $("#cfg-model").value = c.model;
  $("#cfg-language").value = c.language || "";
  $("#cfg-sounds").checked = !!c.sounds;
  $("#cfg-show_overlay").checked = !!c.show_overlay;
  $("#cfg-save_history").checked = c.save_history !== false;
  $("#restartbar").classList.toggle("visible", s.needs_restart);
}

async function saveSetting(key, value) {
  const r = await api("/api/settings", { [key]: value });
  $("#restartbar").classList.toggle("visible", r.needs_restart);
  toast("Сохранено");
}
$("#cfg-hotkey").onchange = e => saveSetting("hotkey_keycode", +e.target.value);
$("#cfg-model").onchange = e => saveSetting("model", e.target.value);
$("#cfg-language").onchange = e =>
  saveSetting("language", e.target.value || null);
$("#cfg-sounds").onchange = e => saveSetting("sounds", e.target.checked);
$("#cfg-show_overlay").onchange = e =>
  saveSetting("show_overlay", e.target.checked);
$("#cfg-save_history").onchange = e =>
  saveSetting("save_history", e.target.checked);

async function doRestart() {
  await api("/api/restart", {});
  document.body.innerHTML =
    '<div style="margin:auto;font:20px Georgia">Перезапускаюсь… окно можно закрыть.</div>';
}

/* ---------------- dictionary ---------------- */
async function loadDict() {
  const items = await api("/api/dictionary");
  $("#dictlist").innerHTML = items.map(it => `
    <div class="itemrow">
      <input type="text" value="${esc(it.word)}" style="max-width:220px"
        onchange="updWord(${it.id}, this.value, null)">
      <input type="text" value="${esc(it.misheard)}"
        placeholder="ослышки через запятую"
        onchange="updWord(${it.id}, null, this.value)">
      <button class="iconbtn" onclick="delWord(${it.id})">🗑</button>
    </div>`).join("") ||
    '<div class="empty">Словарь пуст</div>';
}
async function addWord() {
  const w = $("#dw").value.trim();
  if (!w) return;
  await api("/api/dictionary/add", { word: w, misheard: $("#dm").value });
  $("#dw").value = ""; $("#dm").value = "";
  toast("Добавлено"); loadDict();
}
async function updWord(id, word, misheard) {
  await api("/api/dictionary/update", { id, word, misheard });
  toast("Сохранено");
}
async function delWord(id) {
  await api("/api/dictionary/delete", { id }); loadDict();
}

/* ---------------- snippets ---------------- */
async function loadSnip() {
  const items = await api("/api/snippets");
  $("#sniplist").innerHTML = items.map(it => `
    <div class="itemrow">
      <input type="text" value="${esc(it.trigger)}" style="max-width:220px"
        onchange="updSnip(${it.id}, this.value, null)">
      <textarea onchange="updSnip(${it.id}, null, this.value)">${esc(it.expansion)}</textarea>
      <button class="iconbtn" onclick="delSnip(${it.id})">🗑</button>
    </div>`).join("") ||
    '<div class="empty">Сниппетов нет</div>';
}
async function addSnippet() {
  const t = $("#sw").value.trim(), e = $("#se").value.trim();
  if (!t || !e) return;
  await api("/api/snippets/add", { trigger: t, expansion: e });
  $("#sw").value = ""; $("#se").value = "";
  toast("Добавлено"); loadSnip();
}
async function updSnip(id, trigger, expansion) {
  await api("/api/snippets/update", { id, trigger, expansion });
  toast("Сохранено");
}
async function delSnip(id) {
  await api("/api/snippets/delete", { id }); loadSnip();
}

/* ---------------- scratchpad ---------------- */
let _sp;
$("#scratch").addEventListener("input", () => {
  $("#scratch-status").textContent = "…";
  clearTimeout(_sp);
  _sp = setTimeout(async () => {
    await api("/api/scratchpad", { text: $("#scratch").value });
    $("#scratch-status").textContent = "Сохранено ✓";
  }, 500);
});
async function loadScratch() {
  const r = await api("/api/scratchpad");
  $("#scratch").value = r.text;
}
async function copyScratch() {
  await api("/api/copy", { text: $("#scratch").value });
  toast("Скопировано");
}
async function clearScratch() {
  if (!confirm("Очистить черновик?")) return;
  $("#scratch").value = "";
  await api("/api/scratchpad", { text: "" });
}

/* ---------------- refresh ---------------- */
function refresh(page) {
  if (page === "home") { loadState(); loadHistory(); }
  else if (page === "insights") loadState();
  else if (page === "dict") loadDict();
  else if (page === "snip") loadSnip();
  else if (page === "scratch-page") loadScratch();
  else if (page === "settings") loadState();
}
loadState(); loadHistory();
setInterval(() => {
  const active = document.querySelector(".nav button.active");
  if (active && active.dataset.page === "home") loadHistory();
}, 5000);
</script>
</body>
</html>
"""


# ------------------------------------------------------------------ server

class _Handler(BaseHTTPRequestHandler):
    store = None      # заполняется в start_server
    hooks = None

    def log_message(self, *a):
        pass

    # ---- helpers
    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False))

    def _authed(self):
        if self.headers.get("X-Flow-Token") == TOKEN:
            return True
        qs = parse_qs(urlparse(self.path).query)
        return qs.get("token", [""])[0] == TOKEN

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n))
        except json.JSONDecodeError:
            return {}

    # ---- GET
    def do_GET(self):
        if not self._authed():
            return self._send(403, "forbidden", "text/plain")
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        s = self.store
        if u.path == "/":
            html = (HTML.replace("__TOKEN__", TOKEN)
                        .replace("__VERSION__", VERSION))
            return self._send(200, html, "text/html")
        if u.path == "/api/state":
            return self._json({
                "config": self.hooks["get_config"](),
                "stats": s.stats(),
                "needs_restart": self.hooks["needs_restart"](),
            })
        if u.path == "/api/history":
            q = qs.get("q", [""])[0]
            return self._json(s.get_history(q=q))
        if u.path == "/api/dictionary":
            return self._json(s.get_dictionary())
        if u.path == "/api/snippets":
            return self._json(s.get_snippets())
        if u.path == "/api/scratchpad":
            return self._json({"text": s.get_scratchpad()})
        self._send(404, "not found", "text/plain")

    # ---- POST
    def do_POST(self):
        if not self._authed():
            return self._send(403, "forbidden", "text/plain")
        p = urlparse(self.path).path
        b = self._body()
        s = self.store
        try:
            if p == "/api/history/delete":
                s.delete_history(int(b["id"]))
            elif p == "/api/history/clear":
                s.clear_history()
            elif p == "/api/dictionary/add":
                s.add_word(b.get("word"), b.get("misheard", ""))
            elif p == "/api/dictionary/update":
                cur = {r["id"]: r for r in s.get_dictionary()}[int(b["id"])]
                s.update_word(int(b["id"]),
                              b["word"] if b.get("word") is not None else cur["word"],
                              b["misheard"] if b.get("misheard") is not None else cur["misheard"])
            elif p == "/api/dictionary/delete":
                s.delete_word(int(b["id"]))
            elif p == "/api/snippets/add":
                s.add_snippet(b.get("trigger"), b.get("expansion"))
            elif p == "/api/snippets/update":
                cur = {r["id"]: r for r in s.get_snippets()}[int(b["id"])]
                s.update_snippet(int(b["id"]),
                                 b["trigger"] if b.get("trigger") is not None else cur["trigger"],
                                 b["expansion"] if b.get("expansion") is not None else cur["expansion"])
            elif p == "/api/snippets/delete":
                s.delete_snippet(int(b["id"]))
            elif p == "/api/scratchpad":
                s.set_scratchpad(b.get("text", ""))
            elif p == "/api/copy":
                self.hooks["copy"](b.get("text", ""))
            elif p == "/api/settings":
                return self._json(
                    {"ok": True,
                     "needs_restart": self.hooks["apply_settings"](b)})
            elif p == "/api/restart":
                self.hooks["restart"]()
            else:
                return self._send(404, "not found", "text/plain")
            self._json({"ok": True})
        except Exception as e:
            self._json({"ok": False, "error": str(e)}, 500)


def _free_port(pref):
    for port in (pref, 0):
        try:
            with socket.socket() as s:
                s.bind(("127.0.0.1", port))
                return s.getsockname()[1] if port == 0 else port
        except OSError:
            continue
    raise OSError("нет свободного порта")


def start_server(store, hooks):
    """Стартует сервер в daemon-потоке. Возвращает URL дашборда с токеном."""
    _Handler.store = store
    _Handler.hooks = hooks
    port = _free_port(PORT_PREF)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), _Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{port}/?token={TOKEN}"
