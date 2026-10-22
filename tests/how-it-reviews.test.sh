#!/usr/bin/env bash
# docs/how-it-reviews.md has a table of the standards that checks/*.md cite
# (section "Editions", under "Security standards the checks cite"). This test
# keeps the table and the checks in step, in both directions:
#   - every standard and edition that a check file cites has a row in the table,
#     and that row lists the file in its "Check files" cell
#   - every row in the table, and every file in its "Check files" cell, is
#     backed by a check file that cites the standard
# Each row also needs a date in the "Checked" column. That date records when
# a person compared the edition with the official page.
#
# A citation is one line "Name|Edition|file". The edition of an ID that
# carries a year (A05:2025, API1:2023, LLM01:2026) is that year. ASI IDs and
# CWE numbers carry none, so the edition comes from the heading lines in
# checks/*.md. If the headings state two editions, the test needs a row for
# each. The MCP URL carries its date. An RFC number is its own edition.
#
# Run: bash tests/how-it-reviews.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DOC=docs/how-it-reviews.md
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; shift; [ "$#" -eq 0 ] || printf '%s\n' "$@" | sed 's/^/         /'; FAILED=1; }

T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT

# Prints the text of check file $1 without the citations that only point at
# another ID. Each removal is limited to one file and one sentence:
#   - 02b: "LLM06:2025 and LLM06:2026 are different risks" names the 2025 ID
#     only to say that it is a different risk. The test drops that one ID.
#   - 03 and 10: "A01:2025 and API7:2023 in item 2" points at checks/02.
strip() {
  case "$1" in
    checks/02b-ai-agent-security.md)
      sed 's/LLM06:2025 \(and LLM06:2026 are different risks\)/\1/' "$1" ;;
    checks/03-sensitive-data.md|checks/10-tool-surface.md)
      sed 's/A01:2025 and API7:2023 in item 2//' "$1" ;;
    *) cat "$1" ;;
  esac
}

# Prints the IDs that match $1 on stdin, one per line, without the character in front.
ids() { grep -oE "(^|[^A-Za-z0-9])$1" | sed 's/^[^A-Za-z0-9]//'; }
# Prints every distinct value of $1 in checks/*.md, one per line.
all_values() { grep -ohE "$1" checks/*.md | LC_ALL=C sort -u; }
# Prints "Name|Edition" for each edition that the heading lines of checks/*.md
# state for $1. $2 is a sed script that cuts the edition out of a heading.
# With no heading it prints "Name|(no edition heading)", which has no table row.
heading_editions() {
  local found
  found="$(all_values "$2" | sed "$3")"
  if [ -n "$found" ]; then printf '%s\n' "$found" | sed "s/^/$1|/"
  else printf '%s|(no edition heading)\n' "$1"; fi
}

# One "Name|Edition" per standard that stdin (a check file) cites.
cited_in() {
  local text; text="$(cat)"
  printf '%s\n' "$text" | ids 'A[0-9]{2}:[0-9]{4}'     | sed 's/.*:/OWASP Top 10|/'
  printf '%s\n' "$text" | ids 'API[0-9]{1,2}:[0-9]{4}' | sed 's/.*:/OWASP API Security Top 10|/'
  printf '%s\n' "$text" | ids 'LLM[0-9]{2}:[0-9]{4}'   | sed 's/.*:/OWASP Top 10 for LLM Applications|/'
  if [ -n "$(printf '%s\n' "$text" | ids 'ASI[0-9]{2}')" ]; then
    heading_editions 'OWASP Top 10 for Agentic Applications' \
      'OWASP Top 10 for Agentic Applications [0-9]{4}' 's/.* //'
  fi
  if [ -n "$(printf '%s\n' "$text" | ids 'CWE-[0-9]+')" ]; then
    heading_editions 'CWE Top 25' 'CWE Top 25:[0-9]{4}' 's/.*://'
  fi
  printf '%s\n' "$text" \
    | grep -oE 'modelcontextprotocol\.io/specification/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | sed 's#.*/#Model Context Protocol specification|#'
  printf '%s\n' "$text" | ids 'RFC ?[0-9]+' | sed -E 's/RFC ?/RFC /; s/$/|as numbered/'
}

# One "Name|Edition|file" per standard and check file.
cited() {
  local f
  for f in checks/*.md; do
    strip "$f" | cited_in | LC_ALL=C sort -u | sed "s#\$#|$f#"
  done
}

# The table. "keys" prints one "Name|Edition|file" per file in the "Check
# files" cell. "all" prints "Name|Edition|Checked" once per row. "nofiles"
# prints "Name|Edition" for a row whose "Check files" cell names no file.
table() {
  awk -F'|' -v want="$1" '
    /^### Editions/ { on = 1; next }
    /^#/         { on = 0 }
    on && /^\| / && $2 !~ /^ *(Standard|-+) *$/ {
      for (i = 2; i <= 5; i++) gsub(/^ +| +$/, "", $i)
      if (want == "all") { print $2 "|" $3 "|" $4; next }
      if (want == "nofiles") { if ($5 !~ /`/) print $2 "|" $3; next }
      n = split($5, part, "`")
      for (i = 2; i <= n; i += 2) print $2 "|" $3 "|" part[i]
    }' "$DOC"
}

if [ ! -f "$DOC" ]; then
  bad "$DOC exists" "the file is missing"
  echo "SOME CHECKS FAILED"
  exit 1
fi

cited | LC_ALL=C sort -u > "$T/cited"
table keys | LC_ALL=C sort -u > "$T/table"
table all > "$T/rows"

# An empty list on either side would make both comparisons pass.
[ -s "$T/cited" ] || { bad "checks/*.md cite at least one standard" "the scan found none"; echo "SOME CHECKS FAILED"; exit 1; }
[ -s "$T/table" ] || { bad "$DOC has a standards table" "no row found under '### Editions'"; echo "SOME CHECKS FAILED"; exit 1; }

MISSING="$(LC_ALL=C comm -23 "$T/cited" "$T/table")"
EXTRA="$(LC_ALL=C comm -13 "$T/cited" "$T/table")"
if [ -z "$MISSING" ]; then ok 'every standard that a check file cites is in the table, with that file'
else bad 'a check file cites a standard (Name|Edition|file) that the table does not list' "$MISSING"; fi
if [ -z "$EXTRA" ]; then ok 'every file in the table is a check file that cites that standard'
else bad 'the table lists a standard (Name|Edition|file) that the check file does not cite' "$EXTRA"; fi

NODATE="$(awk -F'|' '$3 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ { print $1 "|" $2 }' "$T/rows" 2>/dev/null)"
# The third field is "Name|Edition|Checked": awk splits on |, so field 3 is Checked.
if [ -z "$NODATE" ]; then ok 'every row has a check date (YYYY-MM-DD)'
else bad 'a row has no check date' "$NODATE"; fi

NOFILES="$(table nofiles)"
if [ -z "$NOFILES" ]; then ok 'every row names at least one check file'
else bad 'a row names no check file' "$NOFILES"; fi

if [ "$FAILED" -eq 0 ]; then echo "PASS"; else exit 1; fi
