#!/usr/bin/env bash
# Tool fallbacks: timeout or gtimeout, sha256sum or gsha256sum or shasum.
#
# Homebrew's coreutils installs gtimeout and gsha256sum. macOS has shasum
# and no timeout. The scripts resolve TIMEOUT_BIN and SHA256_BIN once at
# startup (lib/tools.sh) and use them at every call site. A user then needs
# no gnubin PATH step.
#
# Each case runs with a PATH that holds only the tools named in the case.
# The shims call the real tool by its full path, so the case does not depend
# on which names this machine has.
#
# Run: bash tests/tool-fallbacks.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "must not contain '$2', got: $3";; *) ok "$1";; esac; }
for h in ok bad is has lacks; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

. lib/tools.sh  || { echo "  FAIL lib/tools.sh missing or broken"; echo "FAIL: tool fallbacks"; exit 1; }
. lib/merge.sh  || { echo "  FAIL lib/merge.sh missing or broken"; echo "FAIL: tool fallbacks"; exit 1; }
. lib/prompt.sh || { echo "  FAIL lib/prompt.sh missing or broken"; echo "FAIL: tool fallbacks"; exit 1; }
. lib/clone.sh  || { echo "  FAIL lib/clone.sh missing or broken"; echo "FAIL: tool fallbacks"; exit 1; }
. lib/claude-call.sh || { echo "  FAIL lib/claude-call.sh missing or broken"; echo "FAIL: tool fallbacks"; exit 1; }

TMP="$(mktemp -d)"
SMOKE="./.prreview-run-tools-smoke.sh"
trap 'rm -f "$SMOKE"; rm -rf "$TMP"' EXIT

# The real tools, found on the real PATH. This machine may have only the g
# names, so the resolver itself finds them.
tools_resolve || { echo "  FAIL this machine has no timeout and sha256 tool at all"; echo "FAIL: tool fallbacks"; exit 1; }
REAL_TIMEOUT="$(command -v "${TIMEOUT_BIN%% *}")"
REAL_SHA_CMD="$(command -v "${SHA256_BIN%% *}")${SHA256_BIN#"${SHA256_BIN%% *}"}"

# shim DIR NAME...: one small script per NAME in DIR.
shim() {
  local d="$1" n body; shift
  mkdir -p "$d"
  for n in "$@"; do
    case "$n" in
      timeout|gtimeout)     body="exec $REAL_TIMEOUT \"\$@\"" ;;
      sha256sum|gsha256sum) body="exec $REAL_SHA_CMD \"\$@\"" ;;
      # shasum takes -a 256 first. Any other form is an error, as a hash
      # tool that ignored it would hide a call site that dropped the flag.
      shasum)               body="[ \"\$1 \$2\" = '-a 256' ] || exit 2; shift 2; exec $REAL_SHA_CMD \"\$@\"" ;;
      git|curl|openssl|flock) body="exit 0" ;;
      *)                    body="exec $(command -v "$n") \"\$@\"" ;;
    esac
    printf '#!/bin/bash\n%s\n' "$body" > "$d/$n"
    chmod +x "$d/$n"
  done
}
for n in timeout gtimeout sha256sum gsha256sum shasum; do shim "$TMP/$n" "$n"; done
# What the cases need besides the tool under test.
shim "$TMP/base" dirname mkdir jq cut cat sleep tr grep sed awk head git curl openssl flock
mkdir -p "$TMP/none"

under() { local p="$1"; shift; ( PATH="$p"; "$@" ); }

# ── which tool is picked ────────────────────────────────────────────────────
pick() { tools_resolve >/dev/null 2>&1; printf '%s|%s' "$TIMEOUT_BIN" "$SHA256_BIN"; }
is 'timeout alone is used'                  "$(under "$TMP/timeout" pick)" 'timeout|'
is 'gtimeout alone is used'                 "$(under "$TMP/gtimeout" pick)" 'gtimeout|'
is 'timeout wins when both exist'           "$(under "$TMP/gtimeout:$TMP/timeout" pick)" 'timeout|'
is 'sha256sum alone is used'                "$(under "$TMP/sha256sum" pick)" '|sha256sum'
is 'gsha256sum alone is used'               "$(under "$TMP/gsha256sum" pick)" '|gsha256sum'
is 'shasum alone is used with -a 256'       "$(under "$TMP/shasum" pick)" '|shasum -a 256'
is 'gsha256sum wins over shasum'            "$(under "$TMP/shasum:$TMP/gsha256sum" pick)" '|gsha256sum'
is 'sha256sum wins over both'               "$(under "$TMP/shasum:$TMP/gsha256sum:$TMP/sha256sum" pick)" '|sha256sum'
is 'nothing on PATH gives two empty values' "$(under "$TMP/none" pick)" '|'
under "$TMP/gtimeout" tools_resolve >/dev/null 2>&1 \
  && bad 'a missing hash tool is a failure' 'status 1' 'status 0' || ok 'a missing hash tool is a failure'
under "$TMP/sha256sum" tools_resolve >/dev/null 2>&1 \
  && bad 'a missing timeout tool is a failure' 'status 1' 'status 0' || ok 'a missing timeout tool is a failure'
under "$TMP/gtimeout:$TMP/shasum" tools_resolve >/dev/null 2>&1 \
  && ok 'gtimeout and shasum are enough' || bad 'gtimeout and shasum are enough' 'status 0' 'status 1'

# ── the digest, and the review key, are the same through every hash tool ────
INPUT=$'title\nbody with ünïcode\nmain'
WANT_DIGEST="$(printf '%s' "$INPUT" | $REAL_SHA_CMD | cut -c1-12)"
digest() { tools_resolve >/dev/null 2>&1; printf '%s' "$INPUT" | $SHA256_BIN | cut -c1-12; }
H40=0123456789abcdef0123456789abcdef01234567
B40=89abcdef0123456789abcdef0123456789abcdef
PRJ="{\"headRefOid\":\"$H40\",\"title\":\"fix: keep the key\",\"body\":\"Line one.\\nLine two, ünïcode.\",\"baseRefName\":\"main\",\"baseRefOid\":\"$B40\"}"
# The v0.2.0 key of PRJ (tests/review-key-digest.test.sh has the same value).
V020_KEY="$H40-7df6371f5f84"
key() { tools_resolve >/dev/null 2>&1; prompt_review_key "$PRJ" main; }
for t in sha256sum gsha256sum shasum; do
  is "$t alone: the digest of the same input" "$(under "$TMP/$t:$TMP/base" digest)" "$WANT_DIGEST"
  is "$t alone: prompt_review_key gives the v0.2.0 key" "$(under "$TMP/$t:$TMP/base" key)" "$V020_KEY"
done

# ── gtimeout alone runs every timeout wrapper ──────────────────────────────
GT="$TMP/gtimeout:$TMP/base"
printf '#!/bin/bash\n[ "${1-}" = --version ] && { echo "2.1.305 (Claude Code)"; exit 0; }\ncat >/dev/null\necho STUB-ANSWER\n' > "$TMP/claude"
printf '#!/bin/bash\n[ "${1-}" = --version ] && { echo "gh version 2.63.0 (2024-11-27)"; exit 0; }\nexit 1\n' > "$TMP/gh"
chmod +x "$TMP/claude" "$TMP/gh"
quick() { tools_resolve >/dev/null 2>&1; clone_net_run sleep 0; }
slow()  { tools_resolve >/dev/null 2>&1; PRREVIEW_CLONE_NET_TIMEOUT=1 clone_net_run sleep 30; }
call()  { tools_resolve >/dev/null 2>&1; CLAUDE_BIN="$TMP/claude" claude_call 5 test-model "" -- "Read(//x/**)" </dev/null; }
cver()  { tools_resolve >/dev/null 2>&1; CLAUDE_BIN="$TMP/claude" claude_version_check; }
gver()  { tools_resolve >/dev/null 2>&1; gh_version_check "$TMP/gh"; }
under "$GT" quick >/dev/null 2>&1 \
  && ok 'gtimeout alone: clone_net_run runs a command' || bad 'gtimeout alone: clone_net_run runs a command' 'status 0' 'failed'
T0="$(date +%s)"
under "$GT" slow >/dev/null 2>&1; RC=$?
is 'gtimeout alone: clone_net_run still ends a slow command (status 124)' "$RC" 124
[ $(( $(date +%s) - T0 )) -lt 20 ] && ok '...at its deadline' || bad '...at its deadline' 'under 20s' 'longer'
is 'gtimeout alone: claude_call reaches the model command' "$(under "$GT" call 2>&1)" 'STUB-ANSWER'
under "$GT" cver >/dev/null 2>&1 \
  && ok 'gtimeout alone: claude_version_check passes' || bad 'gtimeout alone: claude_version_check passes' 'status 0' 'failed'
under "$GT" gver >/dev/null 2>&1 \
  && ok 'gtimeout alone: gh_version_check passes' || bad 'gtimeout alone: gh_version_check passes' 'status 0' 'failed'

# ── pr-autoreview.sh startup ───────────────────────────────────────────────
# The head, as tests/startup.test.sh runs it: everything above the lock.
LOCK_LN="$(grep -nE '^LOCKFILE=' pr-autoreview.sh | head -1 | cut -d: -f1)"
if [ -z "$LOCK_LN" ]; then bad 'found the lock line' 'no `LOCKFILE=` line in pr-autoreview.sh'; fi
sed -n "1,$(( ${LOCK_LN:-2} - 1 ))p" pr-autoreview.sh > "$SMOKE"
printf '\necho STARTUP-OK\n' >> "$SMOKE"
run_head() { # $1 = PATH
  env -i HOME="$TMP/home" PATH="$1" PRREVIEW_GATE_REPOS=acme/widgets PRREVIEW_OWNER_LOGIN=acme \
    CLAUDE_BIN="$TMP/claude" GH_BIN="$TMP/gh" "$BASH" "$SMOKE" 2>&1
}
OUT="$(run_head "$TMP/gtimeout:$TMP/shasum:$TMP/base")"; RC=$?
has 'gtimeout and shasum only: the head of pr-autoreview.sh starts' 'STARTUP-OK' "$OUT"
is  '...with status 0' "$RC" 0
OUT="$(run_head "$TMP/base")"; RC=$?
is  'no hash tool and no timeout tool: the head stops with status 1' "$RC" 1
has '...and names the hash tool' 'sha256sum missing' "$OUT"
lacks '...and does not start' 'STARTUP-OK' "$OUT"
OUT="$(run_head "$TMP/gsha256sum:$TMP/base")"; RC=$?
is  'no timeout tool: the head stops with status 1' "$RC" 1
has '...and names the timeout tool' 'timeout(1) missing' "$OUT"
has '...and names the other name it tried' 'gtimeout' "$OUT"
lacks '...and does not start' 'STARTUP-OK' "$OUT"
OUT="$(run_head "$TMP/gtimeout:$TMP/base")"; RC=$?
is  'no hash tool: the head stops with status 1' "$RC" 1
has '...and names the hash tool' 'sha256sum missing' "$OUT"
has '...and the names it tried' 'gsha256sum' "$OUT"
lacks '...and does not start' 'STARTUP-OK' "$OUT"

# ── review-loop.sh startup ─────────────────────────────────────────────────
# No repositories are set, so a loop that gets past the tool check exits 2.
OUT="$(env -i HOME="$TMP/home" PATH="$TMP/base" "$BASH" review-loop.sh 2>&1)"; RC=$?
is  'review-loop.sh with no timeout tool stops with status 1' "$RC" 1
has '...and names the tool' 'timeout(1) missing' "$OUT"
OUT="$(env -i HOME="$TMP/home" PATH="$TMP/gtimeout:$TMP/base" "$BASH" review-loop.sh 2>&1)"; RC=$?
is  'review-loop.sh with gtimeout goes past the tool check' "$RC" 2
lacks '...and does not name the tool' 'timeout(1) missing' "$OUT"

# ── prreview setup ─────────────────────────────────────────────────────────
# The real setup_tools and install_hint, read out of the script.
eval "$(grep -E '^(TOOLS=|say\(\))' prreview)"
eval "$(awk '/^(install_hint|setup_tools)\(\) \{/ { f = 1 } f { print } f && /^\}/ { f = 0 }' prreview)"
declare -F setup_tools >/dev/null && declare -F install_hint >/dev/null \
  && ok 'prreview defines setup_tools and install_hint' || bad 'prreview defines setup_tools and install_hint' 'two functions' 'absent'
shim "$TMP/setup-base" git jq curl openssl flock
printf '#!/bin/bash\nexit 0\n' > "$TMP/setup-base/gh"; cp "$TMP/setup-base/gh" "$TMP/setup-base/claude"; chmod +x "$TMP/setup-base/gh" "$TMP/setup-base/claude"
setup() { PLATFORM="$1" setup_tools; }
OUT="$(under "$TMP/setup-base" setup linux)"; RC=$?
is  'setup finds neither timeout nor sha256sum: status 1' "$RC" 1
has '...and says which are missing' 'Missing: timeout sha256sum' "$OUT"
OUT="$(under "$TMP/gtimeout:$TMP/shasum:$TMP/setup-base" setup linux)"; RC=$?
is  'setup with gtimeout and shasum: status 0' "$RC" 0
has '...and finds all tools' 'All tools found.' "$OUT"
OUT="$(under "$TMP/gtimeout:$TMP/setup-base" setup macos)"; RC=$?
has 'setup with gtimeout and no hash tool: only the hash tool is missing' 'Missing: sha256sum' "$OUT"
lacks '...and macOS gets no gnubin PATH step' 'gnubin' "$OUT"
lacks '...and no gtimeout advice' 'gtimeout' "$OUT"
lacks '...and no PATH export' 'export PATH' "$OUT"

# setup_claude asks `claude auth status` through TIMEOUT_BIN too. With
# gtimeout alone, a plain `timeout` there would leave the answer empty, and
# setup would print "Could not ask" in place of "not logged in".
eval "$(awk '/^setup_claude\(\) \{/ { f = 1 } f { print } f && /^\}/ { f = 0 }' prreview)"
declare -F setup_claude >/dev/null \
  && ok 'prreview defines setup_claude' || bad 'prreview defines setup_claude' 'one function' 'absent'
cat > "$TMP/auth-claude" <<'STUB'
#!/bin/bash
case "${1-}" in
  --version) echo "2.1.305 (Claude Code)" ;;
  auth) echo '{"loggedIn":false}' ;;
esac
STUB
chmod +x "$TMP/auth-claude"
claude_setup() { tools_resolve >/dev/null 2>&1; CLAUDE_BIN="$TMP/auth-claude" setup_claude; }
OUT="$(under "$TMP/gtimeout:$TMP/setup-base" claude_setup 2>&1)"; RC=$?
is  'gtimeout alone: setup_claude reads the login state, not logged in: status 1' "$RC" 1
has '...and says Claude Code is not logged in' 'Claude Code is not logged in' "$OUT"
lacks '...and does not say it could not ask' 'Could not ask' "$OUT"

# ── the docs ───────────────────────────────────────────────────────────────
lacks 'README.md has no gnubin PATH step' 'gnubin' "$(cat README.md)"
has   'README.md names the timeout alternative' 'gtimeout' "$(cat README.md)"
has   'README.md names the hash alternatives' 'gsha256sum' "$(cat README.md)"
has   '...including shasum' 'shasum' "$(cat README.md)"

if [ "$FAILED" -eq 0 ]; then echo "PASS: tool fallbacks"; else echo "FAIL: tool fallbacks"; exit 1; fi
