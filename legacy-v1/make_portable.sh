#!/bin/bash
# Сборка переносимого пакета Flow Local на Рабочий стол
set -e
PKG="$HOME/Desktop/FlowLocal-Portable"
rm -rf "$PKG"
mkdir -p "$PKG/model"

# 1. Приложение
cp -R "$HOME/FlowLocal/dist/Flow Local.app" "$PKG/"

# 2. Модель (huggingface-кэш)
cp -R "$HOME/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo" "$PKG/model/"

# 3. Установщик для нового Mac
cat > "$PKG/УСТАНОВИТЬ.command" <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
echo "== Установка Flow Local =="
mkdir -p "$HOME/.cache/huggingface/hub"
cp -R model/models--mlx-community--whisper-large-v3-turbo "$HOME/.cache/huggingface/hub/" 2>/dev/null || true
xattr -cr "Flow Local.app" 2>/dev/null || true
cp -R "Flow Local.app" /Applications/
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
echo ""
echo "Готово! Запускаю Flow Local…"
open "/Applications/Flow Local.app"
echo ""
echo "ВАЖНО: при первом запуске дай разрешения приложению Flow Local:"
echo "  Настройки → Конфиденциальность → Микрофон, Универсальный доступ, Мониторинг ввода"
echo "После включения тумблеров перезапусти приложение."
EOF
chmod +x "$PKG/УСТАНОВИТЬ.command"

# 4. Инструкция
cat > "$PKG/README.txt" <<'EOF'
Flow Local — приватная локальная диктовка (замена Wispr Flow).

ТРЕБОВАНИЯ: Mac на Apple Silicon (M1/M2/M3/M4), macOS 14+.

УСТАНОВКА НА НОВЫЙ MAC:
1. Скопируй эту папку на новый Mac (AirDrop / флешка / диск).
2. Двойной клик по УСТАНОВИТЬ.command
   (если macOS ругается: правый клик → Открыть)
3. Выдай разрешения приложению Flow Local, когда система спросит:
   Микрофон, Универсальный доступ, Мониторинг ввода
   (Настройки → Конфиденциальность и безопасность)
4. Перезапусти Flow Local.

ИСПОЛЬЗОВАНИЕ: держи Fn — говори — отпусти. Текст вставится в курсор.
Иконка в меню-баре: 🎙 готов / 🔴 запись / ✍️ распознаю.

НАСТРОЙКИ: ~/.flow-local/config.json (клавиша, модель, язык).
Интернет не нужен. Звук и текст не покидают компьютер.

АВТОЗАПУСК: Настройки → Основные → Объекты входа → добавь Flow Local.
EOF

du -sh "$PKG"
echo PORTABLE_OK
