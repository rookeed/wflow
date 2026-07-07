#!/bin/bash
# Flow Local — запуск
cd "$(dirname "$0")"
source .venv/bin/activate
exec python3 flow_local.py
