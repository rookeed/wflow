#!/bin/bash
# Сборка FlowLocal.app из Swift-исходников.
# Требуется Xcode (или CLT со Swift toolchain). Результат: build/FlowLocal.app
#
# Переменные:
#   CODESIGN_ID — identity для подписи (по умолчанию "-" = ad-hoc).
#                 Пример: CODESIGN_ID="Apple Development: ..." bash build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

# Подпись: если в связке есть сертификат Apple Development — используем его
# (права TCC не слетают при пересборках). Иначе ad-hoc "-".
# Свой сертификат: CODESIGN_ID="Apple Development: ..." bash build_app.sh
if [ -z "${CODESIGN_ID:-}" ]; then
  FOUND_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
  CODESIGN_ID="${FOUND_ID:--}"
fi
echo "→ подпись: $CODESIGN_ID"

if ! command -v swift >/dev/null; then
  echo "Swift не найден. Установи Xcode или: xcode-select --install"
  exit 1
fi

echo "→ swift build -c release (первый раз скачает whisper.cpp xcframework, ~45 МБ)"
swift build -c release

BIN=".build/release/FlowLocal"
APP="build/FlowLocal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FlowLocal"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Иконка приложения
if [ -d Support/AppIcon.iconset ]; then
  iconutil -c icns Support/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" \
    || echo "⚠️ iconutil не отработал — иконка не будет добавлена"
fi

# Если whisper слинкован динамически (@rpath) — кладём фреймворк в бандл.
if otool -L "$BIN" | grep -q "@rpath.*whisper"; then
  FW=$(find .build/artifacts -type d -name "whisper.framework" | grep -i macos | head -1 || true)
  if [ -n "$FW" ]; then
    echo "→ встраиваю whisper.framework"
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$FW" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
      "$APP/Contents/MacOS/FlowLocal" 2>/dev/null || true
  else
    echo "⚠️ whisper.framework не найден в .build/artifacts — проверь линковку"
  fi
fi

echo "→ codesign"
if [ -d "$APP/Contents/Frameworks" ]; then
  codesign --force --sign "${CODESIGN_ID:--}" "$APP/Contents/Frameworks/"* || true
fi
codesign --force --sign "${CODESIGN_ID:--}" "$APP"

echo ""
echo "✅ Готово: $PWD/$APP"
echo ""
echo "Дальше:"
echo "  1. bash download_model.sh            # если модель ещё не скачана"
echo "  2. cp -R $APP /Applications/         # или запускай из build/"
echo "  3. Первый запуск: выдай разрешения (Микрофон, Универсальный доступ,"
echo "     Мониторинг ввода) уже для Flow Local, а не для Terminal."
echo ""
echo "⚠️ При ad-hoc подписи каждая пересборка = новая подпись, macOS снова"
echo "   спросит разрешения. Для стабильности: CODESIGN_ID=\"Apple Development: ...\""
