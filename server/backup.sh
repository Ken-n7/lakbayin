#!/usr/bin/env bash
# One consistent copy of the database into ~/Backups/lakbayin (or $1), and
# copies older than 14 days gone. Run daily by lakbayin-backup.timer
# (server/README.md). The copies hold password hashes: the folder is private,
# and they are only as safe as this laptop until they are copied off it.
set -euo pipefail
cd "$(dirname "$0")/.."
dir="${1:-$HOME/Backups/lakbayin}"
mkdir -p "$dir"; chmod 700 "$dir"
server/.venv/bin/python -m server.manage backup "$dir/lakbayin-$(date +%F-%H%M%S).sqlite3"
find "$dir" -name 'lakbayin-*.sqlite3' -mtime +14 -delete
