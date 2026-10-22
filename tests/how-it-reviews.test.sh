#!/usr/bin/env bash
# docs/how-it-reviews.md has a table of the standards that checks/*.md cite
# (section "Editions", under "Security standards the checks cite"). This test
# keeps the table and the checks in step, in both directions:
#   - every standard and edition that a check cites has a row in the table
#   - every row in the table is cited by at least one check
# Each row also needs a date in the "Checked" column. That date records when
# a person compared the edition with the official page.
#
# A "standard and edition" is one line "Name|Edition". The edition of an ID
# that carries a year (A05:2025, API1:2023, LLM01:2026) is that year. ASI IDs,
# CWE numbers and the MCP URL carry none, so the edition comes from the
# heading line of the same check file. An RFC number is its own edition.
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

# IDs that a check names only to say they are a different risk. Counting
# them would demand a 2025 row for the LLM list. checks/02b-ai-agent-security.md
# says "LLM06:2025 and LLM06:2026 are different risks".
CONTRAST='LLM06:2025'

# Prints the IDs that match $1, one per line, without the character in front.
ids() { grep -ohE "(^|[^A-Za-z0-9])$1" checks/*.md | sed 's/^[^A-Za-z0-9]//'; }
# Prints the first value of $1 in checks/*.md, or nothing.
first() { grep -ohE "$1" checks/*.md | head -1; }

cited() {
  ids 'A[0-9]{2}:[0-9]{4}'    | sed 's/.*:/OWASP Top 10|/'
  ids 'API[0-9]{1,2}:[0-9]{4}' | sed 's/.*:/OWASP API Security Top 10|/'
  ids 'LLM[0-9]{2}:[0-9]{4}'  | grep -vxF "$CONTRAST" | sed 's/.*:/OWASP Top 10 for LLM Applications|/'
  if [ -n "$(ids 'ASI[0-9]{2}')" ]; then
    printf 'OWASP Top 10 for Agentic Applications|%s\n' \
      "$(first 'OWASP Top 10 for Agentic Applications [0-9]{4}' | sed 's/.* //')"
  fi
  if [ -n "$(ids 'CWE-[0-9]+')" ]; then
    printf 'CWE Top 25|%s\n' "$(first 'CWE Top 25:[0-9]{4}' | sed 's/.*://')"
  fi
  grep -ohE 'modelcontextprotocol\.io/specification/[0-9]{4}-[0-9]{2}-[0-9]{2}' checks/*.md \
    | sed 's#.*/#Model Context Protocol specification|#'
  ids 'RFC ?[0-9]+' | sed -E 's/RFC ?/RFC /; s/$/|as numbered/'
}

# The table: one "Name|Edition" per row, and the "Checked" cell of each row.
table() {
  awk -F'|' -v want="$1" '
    /^### Editions/ { on = 1; next }
    /^#/         { on = 0 }
    on && /^\| / && $2 !~ /^ *(Standard|-+) *$/ {
      for (i = 2; i <= 4; i++) gsub(/^ +| +$/, "", $i)
      if (want == "keys") print $2 "|" $3
      else                print $2 "|" $3 "|" $4
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
if [ -z "$MISSING" ]; then ok 'every standard that a check cites has a row in the table'
else bad 'a check cites a standard (Name|Edition) that the table does not list' "$MISSING"; fi
if [ -z "$EXTRA" ]; then ok 'every row in the table is cited by a check'
else bad 'the table lists a standard (Name|Edition) that no check cites' "$EXTRA"; fi

NODATE="$(awk -F'|' '$3 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ { print $1 "|" $2 }' "$T/rows" 2>/dev/null)"
# The third field is "Name|Edition|Checked": awk splits on |, so field 3 is Checked.
if [ -z "$NODATE" ]; then ok 'every row has a check date (YYYY-MM-DD)'
else bad 'a row has no check date' "$NODATE"; fi

if [ "$FAILED" -eq 0 ]; then echo "PASS"; else exit 1; fi
