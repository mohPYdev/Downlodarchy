#!/bin/bash

# lifecycle.sh <downloads-dir> <category> <action> <threshold-days> [archive-dir]
#
# Actions:
#   scan     - List files older than threshold with metadata (JSON output)
#   archive  - Move old files to archive directory
#   delete   - Remove old files permanently
#
# Security: validates all paths, rejects symlinks and traversal.
# Output: JSON with results for each action.

set -euo pipefail

downloads="$1"
category="$2"
action="$3"
threshold="$4"
archive_dir="${5:-$downloads/.archive}"

# --- Input validation ---

[[ "$category" != */* ]] || { echo '{"error":"category contains path separator"}'; exit 1; }
[[ "$category" != "." && "$category" != ".." ]] || { echo '{"error":"category is dot/dotdot"}'; exit 1; }
[[ "$threshold" =~ ^[0-9]+$ ]] || { echo '{"error":"threshold must be a positive integer"}'; exit 1; }
[[ "$action" == "scan" || "$action" == "archive" || "$action" == "delete" ]] || { echo '{"error":"invalid action"}'; exit 1; }

category_dir="$downloads/$category"

# Category directory must exist.
[[ -d "$category_dir" ]] || { echo '{"files":[],"count":0}'; exit 0; }

# --- Security: verify category_dir is real (not symlink) ---

real_dir=$(stat -L -c '%d:%i' "$category_dir" 2>/dev/null) || { echo '{"error":"cannot stat category dir"}'; exit 1; }
link_dir=$(stat -c '%d:%i' "$category_dir" 2>/dev/null) || { echo '{"error":"cannot stat category dir"}'; exit 1; }
[[ "$real_dir" == "$link_dir" ]] || { echo '{"error":"category dir is a symlink"}'; exit 1; }

# --- Find old files ---

# Use find with -mtime to get files older than threshold days.
# -maxdepth 1: only direct children (no recursion into subdirs).
# -type f: regular files only.
# -not -name ".*": skip dotfiles.
old_files=()
while IFS= read -r -d '' filepath; do
  # Additional security: verify it's a real file, not a symlink.
  [[ -f "$filepath" && ! -L "$filepath" ]] || continue
  # Verify it's still a direct child of category_dir.
  rel="${filepath#"$category_dir/"}"
  [[ "$rel" != */* ]] || continue
  old_files+=("$filepath")
done < <(find "$category_dir" -maxdepth 1 -type f -not -name ".*" -mtime +"$threshold" -print0 2>/dev/null)

count=${#old_files[@]}

# --- Scan action: output metadata ---

if [[ "$action" == "scan" ]]; then
  echo -n '{"files":['
  first=true
  for filepath in "${old_files[@]}"; do
    name=$(basename "$filepath")
    size=$(stat -c '%s' "$filepath" 2>/dev/null || echo "0")
    mtime=$(stat -c '%Y' "$filepath" 2>/dev/null || echo "0")
    atime=$(stat -c '%X' "$filepath" 2>/dev/null || echo "0")
    
    # Convert to ISO dates.
    mtime_iso=$(date -u -d "@$mtime" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    atime_iso=$(date -u -d "@$atime" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    
    [[ "$first" == "true" ]] || echo -n ','
    first=false
    printf '{"path":"%s","name":"%s","size":%s,"lastModified":"%s","lastAccessed":"%s","category":"%s"}' \
      "$filepath" "$name" "$size" "$mtime_iso" "$atime_iso" "$category"
  done
  echo "],\"count\":$count}"
  exit 0
fi

# --- Archive action: move files to archive dir ---

if [[ "$action" == "archive" ]]; then
  # Create archive directory structure.
  date_stamp=$(date '+%Y-%m')
  archive_target="$archive_dir/$category/$date_stamp"
  mkdir -p -- "$archive_target"
  
  # Verify archive_target is real (not symlink).
  real_archive=$(stat -L -c '%d:%i' "$archive_target" 2>/dev/null) || { echo '{"error":"cannot stat archive dir"}'; exit 1; }
  link_archive=$(stat -c '%d:%i' "$archive_target" 2>/dev/null) || { echo '{"error":"cannot stat archive dir"}'; exit 1; }
  [[ "$real_archive" == "$link_archive" ]] || { echo '{"error":"archive dir is a symlink"}'; exit 1; }
  
  moved=0
  errors=0
  for filepath in "${old_files[@]}"; do
    name=$(basename "$filepath")
    target="$archive_target/$name"
    
    # Collision-safe naming.
    if [[ -e "$target" || -L "$target" ]]; then
      if [[ $name == *.* && ${name%.*} != "" ]]; then
        stem="${name%.*}"
        ext=".${name##*.}"
      else
        stem="$name"
        ext=""
      fi
      n=1
      while [[ -e "$archive_target/$stem ($n)$ext" || -L "$archive_target/$stem ($n)$ext" ]]; do
        ((n++))
      done
      target="$archive_target/$stem ($n)$ext"
    fi
    
    # Atomic move.
    if mv -- "$filepath" "$target" 2>/dev/null; then
      ((moved++))
    else
      ((errors++))
    fi
  done
  
  echo "{\"archived\":$moved,\"errors\":$errors,\"archivePath\":\"$archive_target\"}"
  exit 0
fi

# --- Delete action: remove files permanently ---

if [[ "$action" == "delete" ]]; then
  deleted=0
  errors=0
  for filepath in "${old_files[@]}"; do
    if rm -f -- "$filepath" 2>/dev/null; then
      ((deleted++))
    else
      ((errors++))
    fi
  done
  
  echo "{\"deleted\":$deleted,\"errors\":$errors}"
  exit 0
fi
