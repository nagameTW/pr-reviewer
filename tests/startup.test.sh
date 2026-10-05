#!/usr/bin/env bash
# Startup smoke for pr-autoreview.sh: run its head — everything above the
# single-instance lock, which is where every knob is parsed — under the
# script's own `set -u`, and require a clean exit. A knob that reads a name a lib defines
# before the lib is sourced is an unbound variable at startup and a gate
# that dies on every round while every unit test stays green.
# bash -n and shellcheck cannot see it; running
# the head can. Run: bash tests/startup.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }

# The head ends right BEFORE the single-instance lock: the knob block sits
# above it, which is where a lib-defined name gets read too early, and
# everything from the lock on is real work — taking the gate's lock (or
# losing the race to a live round and exiting 0 without our marker) and
# sweeping the shared scratch directory. Neither belongs in a test.
LOCK_LN="$(grep -nE '^LOCKFILE=' pr-autoreview.sh | head -1 | cut -d: -f1)"
if [ -z "$LOCK_LN" ]; then bad 'found the lock line' 'no `LOCKFILE=` line in pr-autoreview.sh'; else ok "the head ends before the lock at line $LOCK_LN"; fi
HEAD_END=$(( ${LOCK_LN:-2} - 1 ))
# The copy lives beside the real script so $SCRIPT_DIR resolves to the repo
# root; the `.prreview-run-` prefix marks "a round's private copy, not a file of
# this repo".
SMOKE="./.prreview-run-startup-smoke.sh"
trap 'rm -f "$SMOKE"' EXIT
sed -n "1,${HEAD_END}p" pr-autoreview.sh > "$SMOKE"
printf '\necho STARTUP-OK\n' >> "$SMOKE"
# Minimal environment: the head only checks that its tools exist and parses
# knobs; nothing in it talks to GitHub or the model.
# PRREVIEW_GATE_REPOS and PRREVIEW_OWNER_LOGIN are set so the head never has to ask
# gh for them.
# The head only checks that claude and gh are executable, so /usr/bin/true
# stands in for both: this must also pass on a CI runner that has neither.
OUT="$(env -i HOME="$HOME" PATH="$PATH" PRREVIEW_GATE_REPOS=acme/widgets PRREVIEW_OWNER_LOGIN=acme CLAUDE_BIN=/usr/bin/true GH_BIN=/usr/bin/true bash "$SMOKE" 2>&1)"; RC=$?
case "$OUT" in
  *STARTUP-OK*) ok 'the head of pr-autoreview.sh runs up to the lock under set -u' ;;
  *) bad 'the head of pr-autoreview.sh runs up to the lock under set -u' "rc=$RC, output: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')" ;;
esac
case "$OUT" in *'unbound variable'*) bad 'no unbound variable at startup' "$(printf '%s' "$OUT" | grep 'unbound' | head -2 | tr '\n' ' ')" ;; *) ok 'no unbound variable at startup' ;; esac

if [ "$FAILED" -eq 0 ]; then echo "PASS: startup"; else echo "FAIL: startup"; exit 1; fi
