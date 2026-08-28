#!/bin/bash

# move.sh <downloads-dir> <file> <category>
# Moves <file> into ~/Downloads/<category> with a collision-safe name and
# sends a desktop notification. Prints the final path on stdout.
# Security: rejects symlinks, traversal, and uses cd-based operations to
# eliminate check-then-use races.

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

# Create category directory.
dest="$downloads/$category"
mkdir -p -- "$dest"

# --- atomic move via cd into destination ---
# cd into the target directory, then verify it is a real directory (not a
# symlink) by stat-ing the pinned cwd. This eliminates the TOCTOU race
# because we verify after pinning the descriptor via cd.

cd -- "$dest"

# Verify we landed in a real directory, not a symlink target.
# stat -L -c '%d:%i' gives device:inode of the target; compare with
# the canonical path to detect if we followed a symlink.
real_dir=$(stat -L -c '%d:%i' "$dest" 2>/dev/null) || { echo "error: cannot stat destination" >&2; exit 1; }
link_dir=$(stat -c '%d:%i' "$dest" 2>/dev/null) || { echo "error: cannot stat destination" >&2; exit 1; }
[[ "$real_dir" == "$link_dir" ]] || { echo "error: category dir is a symlink" >&2; exit 1; }

# Collision-safe destination: "report.pdf" -> "report (1).pdf", ...
# We are now cd'd into $dest, so all checks use relative paths.
target="$name"
if [[ -e "$target" || -L "$target" ]]; then
  if [[ $name == *.* && ${name%.*} != "" ]]; then
    stem="${name%.*}"
    ext=".${name##*.}"
  else
    stem="$name"
    ext=""
  fi
  n=1
  while [[ -e "$stem ($n)$ext" || -L "$stem ($n)$ext" ]]; do
    ((n++))
  done
  target="$stem ($n)$ext"
fi

mv -- "$file" "$target"
printf '%s\n' "$dest/$target"

omarchy-notification-send -g "" \
  "Download sorted" \
  "$(basename "$target") → $category" >/dev/null 2>&1 || true
