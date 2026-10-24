#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep a single worker: it owns live WebSockets and serializes match updates.
exec "${LAKBAYIN_PYTHON:-server/.venv/bin/python}" -m uvicorn server.app:create_app --factory --host 127.0.0.1 --port "${LAKBAYIN_PORT:-8000}" --workers 1 --ws-max-size 32768 --no-access-log
