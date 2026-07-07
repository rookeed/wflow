#!/bin/bash
# Flow Local — деплой обновления + переход на тонкий лончер.
# Лончер запускает код прямо из ~/FlowLocal: обновления кода больше
# не меняют подпись приложения и не сбрасывают разрешения macOS.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/FlowLocal"
APP="/Applications/Flow Local.app"

echo "== 1. Копирую код в $DST =="
cp "$SRC/flow_local.py" "$SRC/store.py" "$SRC/webui.py" \
   "$SRC/dashboard_window.py" "$SRC/install.sh" "$SRC/README.md" "$DST/"

echo "== 2. Останавливаю старое приложение =="
pkill -f 'Flow Local' 2>/dev/null || true
pkill -f flow_local.py 2>/dev/null || true
sleep 1

echo "== 3. Собираю тонкий лончер =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/MacOS/FlowLocal" <<LAUNCH
#!/bin/bash
exec "$DST/.venv/bin/python3" "$DST/flow_local.py"
LAUNCH
chmod +x "$APP/Contents/MacOS/FlowLocal"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIdentifier</key><string>com.flowlocal.app</string>
  <key>CFBundleName</key><string>Flow Local</string>
  <key>CFBundleDisplayName</key><string>Flow Local</string>
  <key>CFBundleExecutable</key><string>FlowLocal</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Flow Local записывает голос для локальной транскрибации. Звук не покидает этот Mac.</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
xattr -cr "$APP" 2>/dev/null || true

echo "== 4. Сбрасываю разрешения (нужно выдать один раз, дальше не слетят) =="
tccutil reset Accessibility com.flowlocal.app 2>/dev/null || true
tccutil reset ListenEvent com.flowlocal.app 2>/dev/null || true
tccutil reset Microphone com.flowlocal.app 2>/dev/null || true

echo "== 5. Запускаю =="
open "$APP"
sleep 6
echo "== Лог: =="
tail -4 "$HOME/.flow-local/log.txt"
echo "== Процесс: =="
pgrep -fl 'flow_local.py' | head -2 || echo "НЕ ЗАПУСТИЛСЯ"
echo DEPLOY_DONE
