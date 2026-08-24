#!/bin/bash

# move.sh <downloads-dir> <file> <category>
# Creates ~/Downloads/<category>, moves <file> into it with a collision-safe
# name, and sends a desktop notification. Prints the final path on stdout.

set -euo pipefail

downloads="$1"
file="$2"
category="$3"

name="$(basename "$file")"

# Collision-safe destination: "report.pdf" -> "report (1).pdf", ...
dest="$downloads/$category"
mkdir -p -- "$dest"
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
