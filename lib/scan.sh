#!/usr/bin/env bash
# The sensitive-data scan, in one place. Sourced by every
# script here that puts text on GitHub.
# Source-time side effects are forbidden here.
#
# Why one place, and why a file of patterns: two ways of matching that look
# equivalent are not. Joining the patterns into one alternation string
# (`paste -sd'|'`) and matching with `grep -qiE "$PATS"` breaks on a patterns
# line ending in a backslash: it joins to `abc\|ghi` — a LITERAL pipe in ERE —
# so both patterns silently stop matching, and the startup probe still says
# the file is fine. Materialising the list to a file and matching with
# `grep -iqE -f` has no such reading: every line is its own pattern. So the
# file form is what everything uses.
#
# What deliberately does NOT live here: what to DO about a hit. The callers do
# different things (withhold a comment and carry on, request changes,
# refuse to post at all, fail the whole run), and flattening those into one
# policy would be a behaviour change wearing a refactor's clothes.
#
# Nor a trap: this file never installs one. Its callers (pr-autoreview.sh
# among them) already own EXIT traps that clean their own temp files, and a
# lib-installed `trap ... EXIT` would replace theirs, leaking a PR diff into
# /tmp to save one line here.

# scan_patterns_load <patterns-file> <dest-file>
# Writes the active patterns (comments and blank lines removed) into <dest>,
# which the CALLER creates with mktemp and cleans up. Prints a diagnosis and
# returns non-zero when the file is missing, empty, or holds an invalid regex —
# every caller treats that as "refuse", never as "nothing to match".
#
# The blank-line strip is not tidiness: an empty pattern matches EVERYTHING, so
# one stray blank line would report every PR as a hit.
scan_patterns_load() {
  local src="${1-}" dest="${2-}"
  [ -n "$src" ] && [ -n "$dest" ] || { printf 'scan_patterns_load needs <src> <dest>'; return 1; }
  [ -r "$src" ] || { printf 'sensitive-patterns file missing (%s)' "$src"; return 1; }
  grep -vE '^[[:space:]]*(#|$)' "$src" > "$dest" || true
  [ -s "$dest" ] || { printf 'sensitive-patterns file empty (%s)' "$src"; return 1; }
  # Regex validity, probed on a fixed 2-byte input. Written EXACTLY like this
  # on one line: tests/scan-discipline.test.sh forbids piping into `grep -q`
  # across lib/, and its single exemption matches the literal `printf 'x`.
  local probe
  probe="$(printf 'x\n' | grep -iE -f "$dest" 2>&1 >/dev/null)"
  # shellcheck disable=SC2181  # the status belongs to the pipeline above
  [ $? -le 1 ] || { printf 'sensitive-patterns file contains an invalid regex (%s): %s' "$src" "$probe"; return 1; }
  return 0
}

# scan_text <patterns-file> <text>
# 0 = matched, 1 = clean, 2 = grep could not decide.
#
# ⚠️ `if scan_text ...; then` is WRONG for an outbound scan: it treats 2 as
# false, i.e. as clean, which is the exact fold this function exists to undo.
# Outbound callers want scan_hit_or_unknown below. This one is for callers
# that genuinely need the three answers apart, to report a different failure
# for each.
#
# The third answer is the point. A bare `if grep -qiE ...` folds grep's error
# status into "clean" — on an outbound scan that means a body nobody could
# check goes out as if it had been checked. Callers must treat 2 like a hit.
scan_text() {
  local pf="${1-}" text="${2-}" rc
  # -s as well as -r: `grep -f` with an EMPTY pattern file matches nothing and
  # exits 1, which reads as "clean". The load-time check cannot cover a file
  # emptied afterwards, and this is the one direction that must never happen
  # by accident.
  [ -r "$pf" ] && [ -s "$pf" ] || return 2
  grep -iqE -f "$pf" <<<"$text"
  rc=$?
  [ "$rc" -le 1 ] && return "$rc"
  return 2
}


# scan_hit_or_unknown <patterns-file> <text>
# True when the text matched OR when grep could not decide. This is the shape
# every outbound call site wants, and writing it out at each one is how call
# sites end up folding grep's error status into "clean" — which on an
# outbound scan means text nobody could check goes out as if it had been.
scan_hit_or_unknown() {
  scan_text "${1-}" "${2-}"
  [ "$?" -ne 1 ]
}
