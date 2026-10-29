#!/usr/bin/env bash
# Run every *.test.sh beside this file, each in its own process, and report the ones
# that failed.
#
#   run-tests.sh [-v]
#
# Prints one line per suite -- its name and its own pass/fail tally -- or, with -v, each
# suite's full output. Exits 0 when every suite passes, 1 when any fails, 64 on usage.
# Needs what the suites need: bash, git, awk, perl, ruby and jq. The merge-monitor suite
# waits on real (shortened) polls; the whole run takes about a minute.

set -u

verbose=false
case ${1:-} in
  '') ;;
  -v) verbose=true ;;
  *) printf 'usage: %s [-v]\n' "${0##*/}" >&2; exit 64 ;;
esac

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
failed=()
for t in "$here"/*.test.sh; do
  name=${t##*/}
  if out=$("$t" 2>&1); then status=ok; else status=FAIL; failed+=("$name"); fi
  if $verbose; then printf '%s\n' "$out"; fi
  printf '%-4s  %-28s  %s\n' "$status" "$name" "$(printf '%s\n' "$out" | tail -1)"
  if [ "$status" = FAIL ] && ! $verbose; then
    printf '%s\n' "$out" | grep -A3 '^  FAIL' | sed 's/^/      /'
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  printf '\n%d suite(s) failed: %s\n' "${#failed[@]}" "${failed[*]}"
  exit 1
fi
printf '\nall suites passed\n'
