#!/usr/bin/env bash
# Install the ontherun plugin for the current user from this checkout, loaded in place.
#
#   ./install.sh [--dry-run]     register this checkout as the `claude-workflows` marketplace,
#                                install `ontherun@claude-workflows`, and remove the symlinks an
#                                earlier version of this script left in ~/.claude
#   ./install.sh --uninstall     uninstall the plugin and remove the marketplace
#
# A marketplace added from a local directory loads its plugins in place: nothing is copied
# into ~/.claude/plugins/cache, and a `git pull` here is an upgrade, picked up at the next
# session or `/reload-plugins`. Installing from GitHub instead (README.md) copies a pinned
# version and gets updates through `claude plugin update`.
#
# Idempotent: a marketplace already registered under this name and a plugin already
# installed are left as they are. Needs the `claude` CLI and `jq` on PATH (the checks read
# `claude ... --json`). Exits 0 on success, 1 when either is missing or a step fails, 64 on
# usage.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST="${HOME}/.claude"
MARKET=claude-workflows
PLUGIN=ontherun
mode=install
dry_run=false

for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=true ;;
    --uninstall) mode=uninstall ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'usage: %s [--dry-run] [--uninstall]\n' "$0" >&2; exit 64 ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() { if $dry_run; then say "  would: $*"; else "$@"; fi; }

command -v claude >/dev/null 2>&1 || { say "claude is not on PATH; install Claude Code first" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { say "jq is not on PATH; the installer reads claude's --json output with it" >&2; exit 1; }

points_here() { # <link> -> 0 when it is a symlink into this checkout
  [[ -L "$1" ]] || return 1
  local target; target="$(readlink "$1")"
  [[ "$target" == "$SRC" || "$target" == "$SRC"/* ]]
}

# The symlinks the previous installer made: ~/.claude/wf, ~/.claude/skills/wf-*,
# ~/.claude/agents/wf-*.md. Left in place they would load every skill and agent twice.
prune_old_links() {
  local l
  for l in "$DEST/wf" "$DEST"/skills/wf-* "$DEST"/agents/wf-*.md; do
    if points_here "$l"; then say "unlink   $l (pre-plugin install)"; run rm "$l"; fi
  done
}

marketplace_registered() { # -> 0 when a marketplace named $MARKET is registered
  claude plugin marketplace list --json 2>/dev/null \
    | jq -e --arg m "$MARKET" '
        (if type == "array" then .[] else to_entries[] | (.value + {name: (.value.name // .key)}) end)
        | select(.name == $m)' >/dev/null 2>&1
}

plugin_installed() { # -> 0 when $PLUGIN@$MARKET is installed in any scope
  claude plugin list --json 2>/dev/null \
    | jq -e --arg id "$PLUGIN@$MARKET" '.[] | select(.id == $id)' >/dev/null 2>&1
}

if [[ $mode == uninstall ]]; then
  prune_old_links
  if plugin_installed; then say "uninstall $PLUGIN@$MARKET"; run claude plugin uninstall "$PLUGIN@$MARKET"; fi
  if marketplace_registered; then say "remove   marketplace $MARKET"; run claude plugin marketplace remove "$MARKET"; fi
  $dry_run && say "(dry run - nothing changed)"
  exit 0
fi

prune_old_links
if marketplace_registered; then
  say "ok       marketplace $MARKET is registered"
else
  say "add      marketplace $MARKET from $SRC"
  run claude plugin marketplace add "$SRC"
fi
if plugin_installed; then
  say "ok       $PLUGIN@$MARKET is installed"
else
  say "install  $PLUGIN@$MARKET"
  run claude plugin install "$PLUGIN@$MARKET"
fi

say
say "Loaded in place from $SRC. Start a new session, or run /reload-plugins in an open one."
$dry_run && say "(dry run - nothing changed)"
exit 0
