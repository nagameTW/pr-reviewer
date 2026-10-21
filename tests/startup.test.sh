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
STUB="$(mktemp -d)"
trap 'rm -f "$SMOKE"; rm -rf "$STUB"' EXIT
sed -n "1,${HEAD_END}p" pr-autoreview.sh > "$SMOKE"
printf '\necho STARTUP-OK\n' >> "$SMOKE"
# Minimal environment: the head only checks that its tools exist, asks
# claude for its version and parses knobs; nothing in it talks to GitHub or
# the model.
# PRREVIEW_GATE_REPOS and PRREVIEW_OWNER_LOGIN are set so the head never has to ask
# gh for them.
# claude and gh are stubs that print FAKE_CLAUDE_VERSION and FAKE_GH_VERSION
# the way `claude --version` and `gh --version` do. This must also pass on a
# CI runner that has neither.
cat > "$STUB/claude" <<'STUB_EOF'
#!/usr/bin/env bash
[ "${1-}" = --version ] || exit 1
printf '%s\n' "$FAKE_CLAUDE_VERSION"
STUB_EOF
chmod +x "$STUB/claude"
cat > "$STUB/gh" <<'STUB_EOF'
#!/usr/bin/env bash
[ "${1-}" = --version ] || exit 1
printf '%s\n%s\n' "$FAKE_GH_VERSION" 'https://github.com/cli/cli/releases/latest'
STUB_EOF
chmod +x "$STUB/gh"
# $1 = what the claude stub prints for --version, $2 = what the gh stub prints
# (default: a gh that is new enough)
run_head() {
  env -i HOME="$HOME" PATH="$PATH" PRREVIEW_GATE_REPOS=acme/widgets PRREVIEW_OWNER_LOGIN=acme \
    CLAUDE_BIN="$STUB/claude" GH_BIN="$STUB/gh" FAKE_CLAUDE_VERSION="$1" \
    FAKE_GH_VERSION="${2-gh version 2.63.0 (2024-11-27)}" bash "$SMOKE" 2>&1
}
OUT="$(run_head '2.1.305 (Claude Code)')"; RC=$?
case "$OUT" in
  *STARTUP-OK*) ok 'the head of pr-autoreview.sh runs up to the lock under set -u' ;;
  *) bad 'the head of pr-autoreview.sh runs up to the lock under set -u' "rc=$RC, output: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')" ;;
esac
case "$OUT" in *'unbound variable'*) bad 'no unbound variable at startup' "$(printf '%s' "$OUT" | grep 'unbound' | head -2 | tr '\n' ' ')" ;; *) ok 'no unbound variable at startup' ;; esac

# Claude Code 2.1.305 or later. Each field is compared as an integer, so
# 2.1.1000 and 10.0.0 pass, where a string compare would refuse them.
# Build metadata (+...) does not change the order. A pre-release (-...) of a
# later version passes.
for v in '2.2.0 (Claude Code)' '3.0.0 (Claude Code)' '2.1.1000 (Claude Code)' '10.0.0 (Claude Code)' \
         '2.1.306-beta.1 (Claude Code)' '2.1.305+build.7 (Claude Code)'; do
  OUT="$(run_head "$v")"
  case "$OUT" in
    *STARTUP-OK*) ok "Claude Code '$v' is accepted" ;;
    *) bad "Claude Code '$v' is accepted" "$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')" ;;
  esac
done
# 2.1.304 fails every request on Vertex, Bedrock and gateways when --tools
# leaves out ToolSearch. Older versions do not apply --tools to every tool.
# A pre-release of 2.1.305 comes before 2.1.305 (SemVer), so it is refused.
for v in '2.1.304 (Claude Code)' '2.0.999 (Claude Code)' '1.99.999 (Claude Code)' 'Claude Code' '2.1' '' \
         '2.1.305-rc.1 (Claude Code)' '2.1.306- (Claude Code)'; do
  OUT="$(run_head "$v")"; RC=$?
  case "$OUT" in
    *STARTUP-OK*) bad "Claude Code '$v' is refused" 'the head ran to the end' ;;
    *'2.1.305 or later'*) ok "Claude Code '$v' is refused, and the message names 2.1.305" ;;
    *) bad "Claude Code '$v' is refused, and the message names 2.1.305" "rc=$RC, output: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')" ;;
  esac
done
OUT="$(run_head '2.1.304 (Claude Code)')"; RC=$?
case "$OUT" in *'2.1.304'*) ok 'the refusal names the version it found' ;; *) bad 'the refusal names the version it found' "$OUT" ;; esac
if [ "$RC" -ne 0 ]; then ok '...and exits non-zero'; else bad '...and exits non-zero' "rc=$RC"; fi

# gh 2.63.0 or later: the first release that lists baseRefOid in
# `gh pr view --json`. Fields compare as integers, so 2.100.0 passes and
# 2.9.0 does not.
for v in 'gh version 2.63.0 (2024-11-27)' 'gh version 2.63.1 (2024-12-02)' 'gh version 2.100.0 (2026-01-01)' \
         'gh version 3.0.0 (2027-01-01)' 'gh version 2.64.0-rc.1 (2024-12-01)'; do
  OUT="$(run_head '2.1.305 (Claude Code)' "$v")"
  case "$OUT" in
    *STARTUP-OK*) ok "gh '$v' is accepted" ;;
    *) bad "gh '$v' is accepted" "$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')" ;;
  esac
done
for v in 'gh version 2.62.0 (2024-11-14)' 'gh version 2.9.0 (2022-02-01)' 'gh version 1.14.0 (2021-08-01)' \
         'gh version 2.63.0-rc.1 (2024-11-20)' 'gh version' 'not gh' ''; do
  OUT="$(run_head '2.1.305 (Claude Code)' "$v")"; RC=$?
  case "$OUT" in
    *STARTUP-OK*) bad "gh '$v' is refused" 'the head ran to the end' ;;
    *'gh 2.63.0 or later'*) ok "gh '$v' is refused, and the message names 2.63.0" ;;
    *) bad "gh '$v' is refused, and the message names 2.63.0" "rc=$RC, output: $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')" ;;
  esac
done
OUT="$(run_head '2.1.305 (Claude Code)' 'gh version 2.62.0 (2024-11-14)')"; RC=$?
case "$OUT" in *'gh version 2.62.0'*) ok 'the gh refusal names the version it found' ;; *) bad 'the gh refusal names the version it found' "$OUT" ;; esac
if [ "$RC" -ne 0 ]; then ok '...and exits non-zero'; else bad '...and exits non-zero' "rc=$RC"; fi
# A gh that is not there at all is refused the same way.
OUT="$(env -i HOME="$HOME" PATH="$PATH" PRREVIEW_GATE_REPOS=acme/widgets PRREVIEW_OWNER_LOGIN=acme \
  CLAUDE_BIN="$STUB/claude" GH_BIN="$STUB/no-such-gh" FAKE_CLAUDE_VERSION='2.1.305 (Claude Code)' bash "$SMOKE" 2>&1)"
case "$OUT" in *'gh 2.63.0 or later'*"printed 'nothing'"*) ok 'a missing gh is refused, and the message says it printed nothing' ;; *) bad 'a missing gh is refused, and the message says it printed nothing' "$OUT" ;; esac

if [ "$FAILED" -eq 0 ]; then echo "PASS: startup"; else echo "FAIL: startup"; exit 1; fi
