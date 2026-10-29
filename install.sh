#!/usr/bin/env bash
# Install the wf- workflows for the current user by symlinking them into ~/.claude.
#
#   ./install.sh [--dry-run]       link everything, replacing stale links
#   ./install.sh --uninstall       remove every link that points into this checkout
#
# What it links:
#   ~/.claude/wf               -> this checkout (reference/ and bin/ are read from here)
#   ~/.claude/skills/wf-*      -> skills/wf-*
#   ~/.claude/agents/wf-*.md   -> agents/wf-*.md
#
# Symlinks rather than copies, so the live files and the checked-in ones can't drift: a
# `git pull` here is an upgrade. Idempotent. Anything real it would replace is moved to
# ~/.claude/.backups/<timestamp>/ -- outside skills/ and agents/, because a backup left
# beside the original is loaded as a second, near-identical skill. Links that point into
# this checkout at a file that no longer exists (a renamed or removed skill) are pruned.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST="${HOME}/.claude"
BACKUP_DIR="${DEST}/.backups/$(date +%Y%m%d-%H%M%S)"
mode=install
dry_run=false

for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=true ;;
    --uninstall) mode=uninstall ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'usage: %s [--dry-run] [--uninstall]\n' "$0" >&2; exit 64 ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() { if $dry_run; then say "  would: $*"; else "$@"; fi; }

points_here() { # <link> -> 0 when it is a symlink into this checkout
  [[ -L "$1" ]] || return 1
  local target; target="$(readlink "$1")"
  [[ "$target" == "$SRC" || "$target" == "$SRC"/* ]]
}

link() { # <src> <dst>
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    if [[ "$(readlink "$dst")" == "$src" ]]; then say "ok       $dst"; return; fi
    say "relink   $dst (was -> $(readlink "$dst"))"
    run rm "$dst"
  elif [[ -e "$dst" ]]; then
    say "backup   $dst -> ${BACKUP_DIR}/"
    run mkdir -p "$BACKUP_DIR"
    run mv "$dst" "${BACKUP_DIR}/"
  else
    say "link     $dst"
  fi
  run ln -s "$src" "$dst"
}

prune() { # <dir>: drop links into this checkout whose target is gone
  local l
  for l in "$1"/*; do
    if points_here "$l" && [[ ! -e "$l" ]]; then say "prune    $l"; run rm "$l"; fi
  done
}

if [[ $mode == uninstall ]]; then
  for l in "$DEST/wf" "$DEST"/skills/* "$DEST"/agents/*; do
    if points_here "$l"; then say "unlink   $l"; run rm "$l"; fi
  done
  $dry_run && say "(dry run - nothing changed)"
  exit 0
fi

run mkdir -p "$DEST/skills" "$DEST/agents"
link "$SRC" "$DEST/wf"
for d in "$SRC"/skills/wf-*/; do
  d="${d%/}"
  link "$d" "$DEST/skills/$(basename "$d")"
done
for f in "$SRC"/agents/wf-*.md; do
  link "$f" "$DEST/agents/$(basename "$f")"
done
prune "$DEST/skills"
prune "$DEST/agents"

say
say "Linked from $SRC"
$dry_run && say "(dry run - nothing changed)"
exit 0
