#!/bin/bash

# Streams completed new files in a directory to stdout, one path per line.
# Filters browser partial downloads, dotfiles, and directories. Only
# close_write (last write handle closed) and moved_to (rename into place,
# how browsers finalize .part files) are reported, so files are complete
# when seen.

set -euo pipefail

dir="${1:-$HOME/Downloads}"
pidfile="${XDG_RUNTIME_DIR:-$HOME/.cache}/downlodarchy-watcher.pid"

cleanup() {
  rm -f "$pidfile"
}
trap cleanup EXIT

# Write our PID (and the inotifywait child's) so a new service instance
# can kill us cleanly instead of using broad pattern matching.
inotifywait -m -q -e close_write,moved_to --format '%w%f' "$dir" |
while IFS= read -r path; do
  base="$(basename "$path")"
  case "$base" in
    .*|*.part|*.crdownload|*.partial|*.tmp|*.swp|*.kate-swap|*.!ut) continue ;;
  esac
  [ -f "$path" ] || continue
  printf '%s\n' "$path"
done &
child=$!

# Write our own PID and the inotifywait PID.
printf '%s\n%s\n' "$$" "$child" > "$pidfile"

# Wait for the pipeline; trap EXIT cleans the pidfile.
wait "$child" 2>/dev/null || true
