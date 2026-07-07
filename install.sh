#!/bin/bash
# Flow Local — офлайн-установка (пакеты лежат в ./wheels)
set -e
cd "$(dirname "$0")"
rm -f install.done
exec > >(tee install.log) 2>&1
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH

echo "== Flow Local: установка (офлайн из wheels/) =="

PY=$(command -v python3.12)
[ -z "$PY" ] && { echo "Нет python3.12 — запусти: brew install python@3.12"; exit 1; }
echo "Python: $($PY --version)"

rm -rf .venv
$PY -m venv .venv
source .venv/bin/activate
pip install --quiet --no-index --find-links wheels pip setuptools wheel 2>/dev/null || true

echo "Ставлю зависимости из wheels/ (без сети)…"
pip install --quiet --no-index --find-links wheels \
  numpy sounddevice rumps pyobjc-framework-Quartz pyobjc-framework-Cocoa \
  pyobjc-framework-WebKit mlx-whisper
echo "Зависимости установлены."

echo ""
echo "Скачиваю модель whisper-large-v3-turbo (~1.5 GB, один раз)…"
python - <<'EOF'
import os, time, sys

def try_download():
    from huggingface_hub import snapshot_download
    return snapshot_download("mlx-community/whisper-large-v3-turbo")

last_err = None
# 1) напрямую, мимо прокси; 2) через системный прокси
for attempt, env in [(1, "*"), (2, "*"), (3, None), (4, None)]:
    if env:
        os.environ["no_proxy"] = os.environ["NO_PROXY"] = env
    else:
        os.environ.pop("no_proxy", None); os.environ.pop("NO_PROXY", None)
    try:
        path = try_download()
        print("Модель скачана:", path)
        break
    except Exception as e:
        last_err = e
        print(f"Попытка {attempt} не удалась: {e}. Повтор через 5 сек (докачка с места обрыва)…")
        time.sleep(5)
else:
    sys.exit(f"Не удалось скачать модель: {last_err}")

# Прогрев: убеждаемся, что модель реально работает
import numpy as np
import mlx_whisper
r = mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32),
                           path_or_hf_repo="mlx-community/whisper-large-v3-turbo")
print("Модель загружается и работает. Дальше всё офлайн.")
EOF

touch install.done
echo ""
echo "== УСТАНОВКА ЗАВЕРШЕНА. Запуск: bash run.sh =="
