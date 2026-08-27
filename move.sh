#!/bin/bash

# move.sh <downloads-dir> <file> <category>
# Moves <file> into ~/Downloads/<category> with a collision-safe name and
# sends a desktop notification. Prints the final path on stdout.
# Security: rejects symlinks, traversal outside ~/Downloads, and malformed
# paths.

set -euo pipefail

downloads="$1"
file="$2"
category="$3"

# --- security checks ---

# Source must exist and be a regular file (not a symlink or directory).
[[ -f "$file" && ! -L "$file" ]] || { echo "error: source is not a regular file" >&2; exit 1; }

# Source must be a direct child of $downloads (no traversal via subdirs or ..).
[[ "$file" == "$downloads/"* ]] || { echo "error: source outside Downloads" >&2; exit 1; }
relative="${file#"$downloads/"}"
[[ "$relative" != */* ]] || { echo "error: source is nested in a subdirectory" >&2; exit 1; }

# Category must be a simple name — no slashes, dots, or traversal.
[[ "$category" != */* ]] || { echo "error: category contains path separator" >&2; exit 1; }
[[ "$category" != "." && "$category" != ".." ]] || { echo "error: category is dot/dotdot" >&2; exit 1; }

name="$(basename "$file")"

# Collision-safe destination: "report.pdf" -> "report (1).pdf", ...
dest="$downloads/$category"
mkdir -p -- "$dest"

# Destination must not be a symlink.
[[ ! -L "$dest" ]] || { echo "error: category dir is a symlink" >&2; exit 1; }

target="$dest/$name"
if [[ -e $target || -L $target ]]; then
  if [[ $name == *.* && ${name%.*} != "" ]]; then
    stem="${name%.*}"
    ext=".${name##*.}"
  else
    stem="$name"
    ext=""
  fi
  n=1
  while [[ -e "$dest/$stem ($n)$ext" || -L "$dest/$stem ($n)$ext" ]]; do
    ((n++))
  done
  target="$dest/$stem ($n)$ext"
fi

mv -- "$file" "$target"
printf '%s\n' "$target"

omarchy-notification-send -g "" \
  "Download sorted" \
  "$(basename "$target") → $category" >/dev/null 2>&1 || true
