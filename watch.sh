#!/bin/bash

# Streams completed new files in a directory to stdout, one path per line.
# Filters browser partial downloads, dotfiles, and directories. Only
# close_write (last write handle closed) and moved_to (rename into place,
# how browsers finalize .part files) are reported, so files are complete
# when seen.

set -euo pipefail

dir="${1:-$HOME/Downloads}"

inotifywait -m -q -e close_write,moved_to --format '%w%f' "$dir" | while IFS= read -r path; do
  base="$(basename "$path")"
  case "$base" in
    .*|*.part|*.crdownload|*.partial|*.tmp|*.swp|*.kate-swap|*.!ut) continue ;;
  esac
  [ -f "$path" ] || continue
  printf '%s\n' "$path"
done
