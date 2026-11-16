#!/usr/bin/env bash
# Create the pinned host environment for tools/uart_echo_test.py in
# build/venv-uart (inside the Git-ignored build/ directory). Does not touch the
# system Python. Network access is needed once to fetch pyserial.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m venv build/venv-uart
build/venv-uart/bin/python -m pip install --require-virtualenv -r tools/requirements-uart-host.in
build/venv-uart/bin/python -c 'import serial; print("pyserial", serial.__version__)'
