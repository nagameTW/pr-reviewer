#!/usr/bin/env bash
# Tests for lib/clone.sh. No network and no real gh: the fake below just
# records its arguments and creates whatever a clone would have created.
# Run: bash tests/clone.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. lib/clone.sh || { echo "FAIL: cannot source lib/clone.sh"; exit 1; }
. lib/tools.sh || { echo "FAIL: cannot source lib/tools.sh"; exit 1; }
# macOS without the coreutils gnubin directory has gtimeout and no timeout.
# Find the commands the way the scripts do.
tools_resolve || { echo "FAIL: no timeout command or no SHA-256 command on PATH"; exit 1; }

FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAILED=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh: `gh repo clone <repo> <dir> -- --quiet` makes a real (empty) repo
# so the caller's later `git -C` calls behave like they would on a real clone.
# CLONE_RC forces the failure path; CLONE_LOG counts invocations.
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CLONE_LOG"
[ "${CLONE_RC:-0}" -eq 0 ] || exit "$CLONE_RC"
# Args are: repo clone <owner/name> <dir> -- --quiet
git init -q "$4" >/dev/null 2>&1
EOF
chmod +x "$TMP/gh"
GH="$TMP/gh"
export CLONE_LOG="$TMP/gh.log"

reset() { rm -rf "$TMP/root"; : > "$CLONE_LOG"; export CLONE_RC=0; }

# --- a missing directory is cloned ---
reset
ensure_usable_clone "o/r" "$TMP/root/r" "$TMP/root" >/dev/null \
  && [ -d "$TMP/root/r/.git" ] \
  && ok "missing directory is cloned" || bad "missing directory is cloned"
[ "$(wc -l < "$CLONE_LOG")" -eq 1 ] \
  && ok "cloning calls gh exactly once" || bad "cloning calls gh exactly once"

# --- an existing good clone is left alone ---
: > "$CLONE_LOG"
ensure_usable_clone "o/r" "$TMP/root/r" "$TMP/root" >/dev/null \
  && ok "a usable clone returns success" || bad "a usable clone returns success"
[ ! -s "$CLONE_LOG" ] \
  && ok "a usable clone is not re-cloned" || bad "a usable clone is not re-cloned"

# --- THE regression this file exists for -------------------------------------
# A clone interrupted by a reboot, Ctrl-C, or a round timeout leaves
# a .git behind with nothing usable in it. `[ -d "$dir/.git" ]` alone accepts
# that shape forever: every later round passes the test, fails at fetch, skips
# the repo, and repeats until a human runs rm -rf.
reset
mkdir -p "$TMP/root/r/.git"
ensure_usable_clone "o/r" "$TMP/root/r" "$TMP/root" >/dev/null \
  && ok "an empty .git is detected and re-cloned" \
  || bad "an empty .git is detected and re-cloned"
[ "$(wc -l < "$CLONE_LOG")" -eq 1 ] \
  && ok "the repair path actually re-clones" || bad "the repair path actually re-clones"
git -C "$TMP/root/r" rev-parse --git-dir >/dev/null 2>&1 \
  && ok "the repaired clone is a real repository" \
  || bad "the repaired clone is a real repository"

# --- a directory that is not a repo at all is also repaired ---
reset
mkdir -p "$TMP/root/r"
echo junk > "$TMP/root/r/leftover"
ensure_usable_clone "o/r" "$TMP/root/r" "$TMP/root" >/dev/null \
  && [ ! -e "$TMP/root/r/leftover" ] \
  && ok "a non-repo directory is wiped and re-cloned" \
  || bad "a non-repo directory is wiped and re-cloned"

# --- a failed clone reports failure (caller skips the repo, never proceeds) ---
reset
export CLONE_RC=1
ensure_usable_clone "o/r" "$TMP/root/r" "$TMP/root" >/dev/null 2>&1 \
  && bad "a failed clone must return non-zero" \
  || ok "a failed clone must return non-zero"

# --- a hung network call is cut off, not waited on ---------------------------
# What this half of the file exists for. A `git fetch --prune` on a
# connection that has already gone away blocks with no deadline of its own,
# and every later round waits behind it. A clone can hang the same way. One
# second of budget against a fake that sleeps for a minute: what is pinned is
# that the call RETURNS.
reset
cat > "$TMP/gh-hang" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
chmod +x "$TMP/gh-hang"
HANG_START="$(date +%s)"
GH="$TMP/gh-hang" PRREVIEW_CLONE_NET_TIMEOUT=1   ensure_usable_clone "o/r" "$TMP/root/r" "$TMP/root" >/dev/null 2>&1
HANG_RC=$?
HANG_ELAPSED=$(( $(date +%s) - HANG_START ))
[ "$HANG_RC" -ne 0 ]   && ok "a hung clone returns non-zero instead of blocking"   || bad "a hung clone returns non-zero instead of blocking"
# 30s, not 2s: what is being caught is "waits for the full 60", and a loaded
# box must not turn this into a flake. timeout(1) returns 124 at 1s here.
[ "$HANG_ELAPSED" -lt 30 ]   && ok "a hung clone is cut off, not waited out ($HANG_ELAPSED s)"   || bad "a hung clone is cut off, not waited out ($HANG_ELAPSED s)"

# --- the gate's fetch authenticates through gh, not git's own helper --------
# A repo that needs auth over https: `gh repo clone` gets in with gh's login,
# and a plain `git fetch` afterwards asks whatever credential helper the
# machine has, which may be none. The fake git records its argv.
mkdir -p "$TMP/gitbin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\n' "$TMP/git.args" > "$TMP/gitbin/git"
chmod +x "$TMP/gitbin/git"
( PATH="$TMP/gitbin:$PATH"; GH="/opt/my gh/gh"; clone_net_git -C "$TMP/x" fetch -q origin )
WANT="$(printf '%s\n' -c credential.helper= -c 'credential.helper=!"/opt/my gh/gh" auth git-credential' -C "$TMP/x" fetch -q origin)"
[ "$(cat "$TMP/git.args" 2>/dev/null)" = "$WANT" ] \
  && ok "clone_net_git clears git's own helper and asks gh, quoting a path with a space" \
  || bad "clone_net_git clears git's own helper and asks gh (got: $(tr '\n' ' ' < "$TMP/git.args" 2>/dev/null))"
( PATH="$TMP/gitbin:$PATH"; GH=gh
  printf '#!/bin/sh\necho "$GIT_TERMINAL_PROMPT" > "%s"\n' "$TMP/git.prompt" > "$TMP/gitbin/git"
  clone_net_git fetch )
[ "$(cat "$TMP/git.prompt" 2>/dev/null)" = 0 ] \
  && ok "clone_net_git never waits on a terminal for a username" \
  || bad "clone_net_git never waits on a terminal for a username"
# Every git transport call in the gate goes through clone_net_git, not just the
# one fetch there is today: a plain `clone_net_run git ... ls-remote` added
# later would pass every other check and fail on a machine with no helper.
GATE_NET="$(grep -vE '^[[:space:]]*#' pr-autoreview.sh | grep -nE 'git( -C "[^"]*")? (clone|fetch|pull|push|ls-remote|remote update)')"
GATE_UNAUTH="$(grep -v 'clone_net_git ' <<<"$GATE_NET")"
[ -n "$GATE_NET" ] && [ -z "$GATE_UNAUTH" ] \
  && ok "pr-autoreview.sh authenticates every git transport call through clone_net_git" \
  || bad "pr-autoreview.sh authenticates every git transport call through clone_net_git (unauthenticated: ${GATE_UNAUTH:-none}; found: ${GATE_NET:-none})"

# --- every GIT transport call in both callers goes through the wrapper -------
# Scope, stated plainly:
#
#   IN scope — git's transport subcommands. git is the one that hangs: a
#   `fetch --prune` on a connection that is already gone waits forever,
#   because git applies no deadline of its own. Every spelling is matched,
#   not just the two in the tree today: a `git clone`, `git push` or
#   `git ls-remote` added later without the wrapper brings the hang back and
#   nothing else in the tree would notice.
#
#   OUT of scope — the `$GH` calls (23 in pr-autoreview.sh). They are a
#   different risk: gh has no timeout flag of its own, so they are NOT proven
#   safe, but none is known to hang, and wrapping every one in the gate's
#   hot path is a change that needs its own testing. Left for a change of its
#   own rather than half-done here, and this assertion does not cover them.
GIT_NET_RE='(^|[^a-zA-Z_-])git( -C "[^"]*")? (clone|fetch|pull|push|ls-remote|remote update)'
# The scripts that clone or fetch.
CLONE_USERS="pr-autoreview.sh"
for f in $CLONE_USERS; do
  [ -r "$f" ] || { bad "$f is missing"; continue; }
  # Materialised first, never `producer | grep -q` — see
  # tests/scan-discipline.test.sh for why that idiom reads a hit as a miss.
  NETSRC="$(grep -vE '^[[:space:]]*#' "$f" | grep -nE "$GIT_NET_RE")"
  BARE="$(grep -vE 'clone_net_run' <<<"$NETSRC")"
  [ -z "$BARE" ] \
    && ok "$f routes every git transport call through clone_net_run" \
    || bad "$f has a git transport call with no deadline: $BARE"
done
# The pattern has to be able to SEE a bare call, or the loop above is vacuous.
# lib/clone.sh's own `gh repo clone` is wrapped; this checks the regex against
# a line that is deliberately not.
BARE_PROBE="$(printf '%s\n' '  git -C "$d" push origin HEAD' | grep -cE "$GIT_NET_RE")"
[ "$BARE_PROBE" = 1 ] \
  && ok "the git-transport pattern can see a bare call" \
  || bad "the git-transport pattern can see a bare call (matched $BARE_PROBE) — the loop above proves nothing"

# --- a deadline timeout(1) cannot use is refused up front ---------------------
for GOOD in 1 600 08; do
  PRREVIEW_CLONE_NET_TIMEOUT="$GOOD" clone_net_timeout_ok 2>/dev/null \
    && ok "clone_net_timeout_ok accepts '$GOOD'" || bad "clone_net_timeout_ok accepts '$GOOD'"
done
(unset PRREVIEW_CLONE_NET_TIMEOUT; clone_net_timeout_ok 2>/dev/null) \
  && ok "clone_net_timeout_ok accepts the default" || bad "clone_net_timeout_ok accepts the default"
for BAD in 0 00 abc 3o -5; do
  TOUT="$(PRREVIEW_CLONE_NET_TIMEOUT="$BAD" clone_net_timeout_ok 2>&1)" \
    && bad "clone_net_timeout_ok refuses '$BAD'" \
    || { grep -qF "got: $BAD — refusing to run" <<<"$TOUT" \
           && ok "clone_net_timeout_ok refuses '$BAD'" \
           || bad "clone_net_timeout_ok refuses '$BAD' (said: $TOUT)"; }
done
for f in $CLONE_USERS; do
  grep -qE '^clone_net_timeout_ok \|\| exit [12]$' "$f" \
    && ok "$f refuses a bad PRREVIEW_CLONE_NET_TIMEOUT before its first clone or fetch" \
    || bad "$f refuses a bad PRREVIEW_CLONE_NET_TIMEOUT before its first clone or fetch"
done

if [ "$FAILED" -eq 0 ]; then echo "PASS: lib/clone.sh"; else echo "FAIL: lib/clone.sh"; exit 1; fi
