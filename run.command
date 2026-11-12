#!/bin/bash
# Double-click on macOS (or run ./run.command) to start Red vs Blue: AI Guardrail Arena.
# Settings are read from .env by the app itself; this script only prepares and starts it.
# Safe to run on any machine: it rebuilds .venv / node_modules if they were copied from elsewhere.

cd "$(dirname "$0")" || exit 1
PORT=8000
URL="http://127.0.0.1:$PORT"

pause_and_exit() { echo; read -r -p "Press Enter to close..."; exit 1; }

echo "Red vs Blue: AI Guardrail Arena"
echo

# --- Python 3.12+ -----------------------------------------------------------------
py_ok() { "$1" -c 'import sys; sys.exit(sys.version_info < (3, 12))' >/dev/null 2>&1; }

PYTHON=""
for candidate in python3.13 python3.12 python3 \
  /opt/homebrew/bin/python3 /usr/local/bin/python3 /opt/anaconda3/bin/python3 \
  /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
  /Library/Frameworks/Python.framework/Versions/3.12/bin/python3; do
  if command -v "$candidate" >/dev/null 2>&1 && py_ok "$candidate"; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "Python 3.12 or newer is required (found: $(python3 --version 2>&1 || echo none))."
  echo "Install it from https://www.python.org/downloads/ or with: brew install python@3.12"
  pause_and_exit
fi

if [ ! -f ".env" ]; then
  echo "Note: no .env file found. Azure checks will report 'not configured'. See .env.example."
fi

# --- Python environment -------------------------------------------------------------
# A .venv copied from another computer (zip, WhatsApp, AirDrop...) has hard-coded paths
# and quarantined native libraries that macOS refuses to load. Only reuse a .venv that
# this script built in this exact folder; otherwise rebuild it from scratch.
HERE="$(pwd -P)"
MARKER=.venv/.built-here
quarantined() { command -v xattr >/dev/null 2>&1 && xattr -p com.apple.quarantine "$1" >/dev/null 2>&1; }

venv_ok() {
  [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$HERE" ] && ! quarantined .venv/pyvenv.cfg \
    && .venv/bin/python -c 'import sys; sys.exit(sys.version_info < (3, 12))' >/dev/null 2>&1
}

if ! venv_ok; then
  echo "Setting up a fresh Python environment with $("$PYTHON" --version)..."
  rm -rf .venv
  "$PYTHON" -m venv .venv || { echo "Could not create the virtual environment."; pause_and_exit; }
fi

if [ ! -f "$MARKER" ] || [ requirements.txt -nt "$MARKER" ] \
  || ! .venv/bin/python -c "import fastapi, uvicorn, httpx, dotenv, pydantic_core" >/dev/null 2>&1; then
  echo "Installing Python dependencies..."
  .venv/bin/python -m pip install -q --upgrade pip >/dev/null 2>&1
  .venv/bin/python -m pip install -q -r requirements.txt || { echo "Python dependency install failed."; pause_and_exit; }
  echo "$HERE" > "$MARKER"
fi

# --- Interface (only needs Node when a build is required) ---------------------------
needs_build() {
  [ ! -f frontend/dist/index.html ] && return 0
  [ -n "$(find frontend/src frontend/index.html frontend/package.json -newer frontend/dist/index.html 2>/dev/null | head -1)" ]
}

build_ui() { (cd frontend && npm run build --silent); }

if needs_build; then
  command -v node >/dev/null 2>&1 || { echo "Node.js 20.19+ or 22.12+ is required to build the interface: https://nodejs.org/"; pause_and_exit; }
  if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit((a===20&&b>=19)||(a===22&&b>=12)||a>22 ? 0 : 1)'; then
    echo "Node.js $(node --version) is too old for Vite 8. Install Node 20.19+ or 22.12+: https://nodejs.org/"
    pause_and_exit
  fi
  echo "Building the interface..."
  # Copied node_modules hold quarantined native binaries too; reinstall those.
  if [ ! -d frontend/node_modules ] || quarantined frontend/node_modules/.package-lock.json; then
    rm -rf frontend/node_modules
    (cd frontend && npm ci --no-audit --no-fund) || { echo "npm install failed."; pause_and_exit; }
  fi
  if ! build_ui; then
    # node_modules copied from another machine can hold binaries for the wrong platform.
    echo "Build failed; reinstalling interface dependencies and retrying..."
    rm -rf frontend/node_modules
    (cd frontend && npm ci --no-audit --no-fund) || { echo "npm install failed."; pause_and_exit; }
    build_ui || { echo "Interface build failed."; pause_and_exit; }
  fi
fi

# --- Start ----------------------------------------------------------------------------
if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "Port $PORT is already in use (the arena may already be running)."
  echo "Open $URL, or stop the other process with: lsof -ti tcp:$PORT | xargs kill"
  pause_and_exit
fi

open_browser() {
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "$URL/api/status"; then
      if command -v open >/dev/null 2>&1; then open "$URL"; elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL"; fi
      return
    fi
    sleep 0.5
  done
}

echo
echo "Starting at $URL  (Ctrl+C to stop)"
open_browser &
OPENER=$!
trap 'kill "$OPENER" 2>/dev/null' EXIT
.venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port "$PORT"
echo
read -r -p "Server stopped. Press Enter to close..."
