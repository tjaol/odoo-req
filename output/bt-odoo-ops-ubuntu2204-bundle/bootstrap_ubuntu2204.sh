#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Please run: sudo apt install -y python3 python3-venv python3-pip"
  exit 1
fi

python3 -m venv .venv
source .venv/bin/activate
python -m pip install -U pip setuptools wheel

if [ -f requirements.txt ]; then
  pip install -r requirements.txt
fi

echo "[OK] venv ready: $(pwd)/.venv"
echo "Use: source .venv/bin/activate"
