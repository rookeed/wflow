"""Flow Local — замороженный загрузчик.

Этот файл — единственное, что вшито в .app. Он выполняет актуальный код
из ~/FlowLocal, поэтому обновления кода не требуют пересборки приложения
и не меняют его подпись (разрешения macOS сохраняются).

Импорты ниже нужны PyInstaller: он включает в сборку только то, что видит
статически. Сам код грузится из ~/FlowLocal при каждом запуске.
"""

# -- зависимости для заморозки (не удалять) --
import collections            # noqa: F401
import datetime               # noqa: F401
import fcntl                  # noqa: F401
import http.server            # noqa: F401
import json                   # noqa: F401
import multiprocessing        # noqa: F401
import os
import platform               # noqa: F401
import queue                  # noqa: F401
import re                     # noqa: F401
import runpy
import secrets                # noqa: F401
import socket                 # noqa: F401
import sqlite3                # noqa: F401
import subprocess             # noqa: F401
import sys
import threading              # noqa: F401
import time                   # noqa: F401
import urllib.parse           # noqa: F401
import webbrowser             # noqa: F401

import numpy                  # noqa: F401
import sounddevice            # noqa: F401
import objc                   # noqa: F401
import rumps                  # noqa: F401
import Quartz                 # noqa: F401
import AppKit                 # noqa: F401
import Foundation             # noqa: F401
import WebKit                 # noqa: F401
import mlx_whisper            # noqa: F401

if __name__ == "__main__":
    multiprocessing.freeze_support()
    APP_DIR = os.path.expanduser("~/FlowLocal")
    main_py = os.path.join(APP_DIR, "flow_local.py")
    if not os.path.exists(main_py):
        sys.exit(f"Не найден {main_py} — код приложения должен лежать в ~/FlowLocal")
    sys.path.insert(0, APP_DIR)
    os.chdir(APP_DIR)
    runpy.run_path(main_py, run_name="__main__")
