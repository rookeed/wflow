#!/bin/bash
# Сборка оболочки Flow Local.app с замороженным загрузчиком.
# Выполняется ОДИН раз; дальше код обновляется в ~/FlowLocal без пересборки.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/FlowLocal"
cd "$DST"
cp "$SRC/bootstrap.py" .
rm -f shellbuild.done

{
  ./.venv/bin/pyinstaller --noconfirm --windowed \
    --name "Flow Local" \
    --osx-bundle-identifier com.flowlocal.app \
    --collect-all mlx --collect-all mlx_whisper \
    --collect-all numba --collect-all llvmlite \
    --collect-all tiktoken \
    bootstrap.py

  PLIST="dist/Flow Local.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$PLIST" || true
  /usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string "Flow Local записывает голос для локальной транскрибации. Звук не покидает этот Mac."' "$PLIST" || true
  codesign --force --deep -s - "dist/Flow Local.app"
  echo BUILD_OK
} > shellbuild.log 2>&1

# установка
pkill -f 'Flow Local' 2>/dev/null || true
pkill -f flow_local.py 2>/dev/null || true
sleep 1
rm -rf '/Applications/Flow Local.app'
cp -R "dist/Flow Local.app" /Applications/
xattr -cr '/Applications/Flow Local.app' 2>/dev/null || true

# права: сброс один последний раз
tccutil reset Accessibility com.flowlocal.app 2>/dev/null || true
tccutil reset ListenEvent com.flowlocal.app 2>/dev/null || true
tccutil reset Microphone com.flowlocal.app 2>/dev/null || true

open '/Applications/Flow Local.app'
sleep 6
tail -4 "$HOME/.flow-local/log.txt"
touch shellbuild.done
echo SHELL_APP_DONE
