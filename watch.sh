#!/bin/bash

# Streams completed new files in a directory to stdout, one path per line.
# Filters browser partial downloads, dotfiles, and directories. Only
# close_write (last write handle closed) and moved_to (rename into place,
# how browsers finalize .part files) are reported, so files are complete
# when seen.
#
# Security: runs under setsid so all pipeline members share one process
# group that can be killed atomically. PID file is created securely via
# mktemp + atomic rename (no symlink-following truncating redirect).

set -euo pipefail

dir="${1:-$HOME/Downloads}"
pidfile="${XDG_RUNTIME_DIR:-$HOME/.cache}/downlodarchy-watcher.pid"

cleanup() {
  rm -f "$pidfile"
}
trap cleanup EXIT

# --- Secure PID file creation (no symlink-following truncation) ---
tmpfile=$(mktemp "${pidfile}.XXXXXX" 2>/dev/null) || tmpfile=""
if [ -n "$tmpfile" ]; then
  printf '%s\n' "$$" > "$tmpfile"
  mv -f "$tmpfile" "$pidfile"
fi

inotifywait -m -q -e close_write,moved_to --format '%w%f' "$dir" |
while IFS= read -r path; do
  base="${path##*/}"
  case "$base" in
    .*|*.part|*.crdownload|*.partial|*.tmp|*.swp|*.kate-swap|*.!ut) continue ;;
  esac
  [ -f "$path" ] || continue
  printf '%s\n' "$path"
done
