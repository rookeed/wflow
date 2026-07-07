#!/bin/bash
# Сборка переносимого Flow Local.app
set -e
cd "$HOME/FlowLocal"
rm -f build.done
{
  ./.venv/bin/pyinstaller --noconfirm --windowed \
    --name "Flow Local" \
    --osx-bundle-identifier com.flowlocal.app \
    --collect-all mlx --collect-all mlx_whisper \
    --collect-all numba --collect-all llvmlite \
    flow_local.py

  PLIST="dist/Flow Local.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$PLIST" || true
  /usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string "Flow Local записывает голос для локальной транскрибации. Звук не покидает этот Mac."' "$PLIST" || true
  codesign --force --deep -s - "dist/Flow Local.app"
  echo BUILD_OK
} > build.log 2>&1
touch build.done
