#!/bin/bash
# Загрузка ggml-модели whisper.cpp в ~/.flow-local/models/
# Использование: bash download_model.sh [large-v3-turbo-q5|large-v3-turbo|large-v3|medium|medium-q5|small]
set -euo pipefail

MODEL="${1:-large-v3-turbo-q5}"
DIR="$HOME/.flow-local/models"
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

case "$MODEL" in
  large-v3-turbo-q5) FILE="ggml-large-v3-turbo-q5_0.bin" ;;  # ~574 МБ
  large-v3-turbo)    FILE="ggml-large-v3-turbo.bin" ;;       # ~1.6 ГБ
  large-v3)          FILE="ggml-large-v3.bin" ;;             # ~3.1 ГБ
  medium)            FILE="ggml-medium.bin" ;;               # ~1.5 ГБ
  medium-q5)         FILE="ggml-medium-q5_0.bin" ;;          # ~540 МБ
  small)             FILE="ggml-small.bin" ;;                # ~490 МБ
  *) echo "Неизвестная модель: $MODEL"; exit 1 ;;
esac

mkdir -p "$DIR"
if [ -f "$DIR/$FILE" ]; then
  echo "Уже скачана: $DIR/$FILE"
  exit 0
fi

echo "Скачиваю $FILE ..."
curl -L --fail --progress-bar -o "$DIR/$FILE.part" "$BASE/$FILE"
mv "$DIR/$FILE.part" "$DIR/$FILE"
echo "Готово: $DIR/$FILE"
