#!/usr/bin/env bash
# Tests for lib/scan.sh. No network, no gh, no patterns file from the box.
# Run: bash tests/scan.test.sh
#
# ⚠️ Run these through bash, not by pasting the commands into an interactive
# shell: a profile can turn `grep` into a shell FUNCTION around another tool,
# and ugrep, for one, answers differently on a malformed pattern file. A
# script run by bash reads no profile, so it gets the grep these tests
# exercise.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. lib/scan.sh || { echo "FAIL: cannot source lib/scan.sh"; exit 1; }

FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/patterns"; DEST="$WORK/active"

# ── scan_patterns_load ────────────────────────────────────────────────────
printf '# a comment\n\nsecret[0-9]+\nZEBRA-[A-Z]+\n' > "$SRC"
scan_patterns_load "$SRC" "$DEST" >/dev/null \
  && ok 'a normal patterns file loads' || bad 'a normal patterns file loads' 0 non-zero
is 'comments and blank lines are stripped' "$(wc -l < "$DEST" | tr -d ' ')" '2'

# A blank line becomes an empty alternative that matches EVERYTHING — i.e.
# every body reported as a hit, every PR blocked. This is why the strip exists.
printf 'secret\n\n\n' > "$SRC"
scan_patterns_load "$SRC" "$DEST" >/dev/null
is 'blank lines cannot survive into the active list' "$(wc -l < "$DEST" | tr -d ' ')" '1'

refuses() {
  local why
  if why="$(scan_patterns_load "$1" "$DEST")"; then
    bad "$2" 'non-zero + a reason' 'accepted it'
  elif [ -z "$why" ]; then
    bad "$2" 'a reason on stdout' 'refused silently'
  else
    ok "$2"
  fi
}
refuses "$WORK/nope" 'a missing patterns file is refused, with a reason'
: > "$SRC";                    refuses "$SRC" 'an empty patterns file is refused'
printf '# only a comment\n' > "$SRC"; refuses "$SRC" 'a comments-only file is refused'
printf 'abc[\n' > "$SRC";      refuses "$SRC" 'an unclosed bracket is refused'

# The divergence this exists to remove. Joined into one alternation, a trailing
# backslash makes `abc\|ghi` — a LITERAL pipe in ERE — so BOTH patterns stop
# matching and the old startup probe still said the file was fine. Read as a
# FILE, grep rejects it outright and this refuses to run.
printf 'abc\\\nghi\n' > "$SRC"
refuses "$SRC" 'a trailing backslash is refused, not silently disabled'

# ── scan_text / scan_file ─────────────────────────────────────────────────
printf 'secret[0-9]+\nZEBRA-[A-Z]+\n' > "$SRC"
scan_patterns_load "$SRC" "$DEST" >/dev/null
code() { scan_text "$DEST" "$1"; echo "$?"; }
is 'a match returns 0'                  "$(code 'the value is secret42 here')" '0'
is 'clean text returns 1'               "$(code 'nothing to see')" '1'
is 'matching is case-insensitive'       "$(code 'SECRET42')" '0'
is 'the second pattern matches too'     "$(code 'ZEBRA-ABC')" '0'
is 'multi-line text is scanned whole'   "$(code "$(printf 'clean line\nsecret7\n')")" '0'
is 'an unreadable patterns file is 2, never 1' "$(scan_text "$WORK/gone" x; echo $?)" '2'

# The third answer is the point: seven of the eight call sites this replaced
# folded grep's error status into "clean", which on an outbound scan means a
# body nobody could check goes out as if it had been checked.
hit_or_unknown() { scan_hit_or_unknown "$1" "$2"; echo "$?"; }
is 'hit_or_unknown says yes on a match'        "$(hit_or_unknown "$DEST" 'secret9')" '0'
is 'hit_or_unknown says no on clean text'      "$(hit_or_unknown "$DEST" 'fine')" '1'
is 'hit_or_unknown says YES when it cannot decide' \
   "$(hit_or_unknown "$WORK/gone" 'fine')" '0'


# A pattern file large enough to outrun a pipe buffer: the class of bug
# tests/scan-discipline.test.sh exists for, from the other direction.
{ printf 'secret[0-9]+\n'; for i in $(seq 1 5000); do printf 'filler%s\n' "$i"; done; } > "$SRC"
scan_patterns_load "$SRC" "$DEST" >/dev/null
is 'a 5000-line patterns file still matches' "$(code 'secret1')" '0'

# An EMPTY pattern file makes `grep -f` match nothing and exit 1 — i.e. it
# reads as "clean". The load-time check cannot cover a file emptied AFTER the
# load, so both matchers check it too. This is the one direction that must
# never happen by accident.
: > "$WORK/empty"
is 'an empty patterns file is 2 (cannot decide), never 1 (clean)' \
   "$(scan_text "$WORK/empty" 'anything'; echo $?)" '2'
is 'hit_or_unknown treats an empty patterns file as a hit' \
   "$(scan_hit_or_unknown "$WORK/empty" 'anything'; echo $?)" '0'

# grep names the offending line; swallowing it means the operator has a
# refusal with no way to find which pattern is wrong.
printf 'abc[\n' > "$SRC"
WHY="$(scan_patterns_load "$SRC" "$DEST" 2>/dev/null)"
case "$WHY" in
  *grep*) ok 'the refusal quotes grep own diagnostic' ;;
  *) bad 'the refusal quotes grep own diagnostic' "a reason mentioning grep" "$WHY" ;;
esac

if [ "$FAILED" -eq 0 ]; then echo "PASS: lib/scan.sh"; else echo "FAIL: lib/scan.sh"; exit 1; fi
