#!/usr/bin/env bash
# Tests for lib/rotate.sh. No gh, no network.
# Run: bash tests/rotate.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. lib/rotate.sh || { echo "FAIL: cannot source lib/rotate.sh"; exit 1; }

FAILED=0
is() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$3" "$2"; FAILED=1; fi
}

is 'cursor 0 keeps the original order' \
   "$(rotate_list 'a b c' 0)" "$(printf 'a\nb\nc')"
is 'cursor 1 starts at the second item' \
   "$(rotate_list 'a b c' 1)" "$(printf 'b\nc\na')"
is 'cursor 2 starts at the third item' \
   "$(rotate_list 'a b c' 2)" "$(printf 'c\na\nb')"
is 'cursor wraps modulo the list length' \
   "$(rotate_list 'a b c' 4)" "$(printf 'b\nc\na')"
is 'a corrupt cursor degrades to the original order, never aborts' \
   "$(rotate_list 'a b c' 'garbage')" "$(printf 'a\nb\nc')"
is 'an empty cursor reads as 0' \
   "$(rotate_list 'a b c' '')" "$(printf 'a\nb\nc')"
is 'an empty list yields nothing' \
   "$(rotate_list '' 2)" ''
is 'a single-item list is unchanged at any cursor' \
   "$(rotate_list 'only' 7)" 'only'

if [ "$FAILED" -eq 0 ]; then echo "PASS: lib/rotate.sh"; else echo "FAIL: lib/rotate.sh"; exit 1; fi
