#!/usr/bin/env bash
# The review checklist is a directory of Markdown files, one per item
# (lib/review-spec.sh review_checks_render). These pin how a directory turns
# into the numbered list the model reads, and that every broken directory is
# refused rather than half-read. Run: bash tests/review-checks.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. lib/review-spec.sh || { echo "lib/review-spec.sh missing"; exit 1; }
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
refused() { # $1 label, $2 dir, $3 text the reason must contain
  local err
  if err="$(review_checks_render "$2" 2>&1 >/dev/null)"; then
    bad "$1" 'a refusal' 'it rendered'
  else
    case "$err" in *"$3"*) ok "$1" ;; *) bad "$1" "a reason naming '$3'" "$err" ;; esac
  fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ── numbering and order ───────────────────────────────────────────────────
mkdir "$T/order"
printf 'First.\n' > "$T/order/01-first.md"
printf 'Second.\n' > "$T/order/02-second.md"
printf 'Second b.\n' > "$T/order/02b-second-b.md"
printf 'Tenth.\n' > "$T/order/10-tenth.md"
printf 'Third.\n' > "$T/order/3-third.md"
# By number, not by name: "3-" sorts after "10-" as text. And 2 before 2b
# whatever the locale, where a collation that skips punctuation would read
# "02-second" and "02b-second-b" as "02second" and "02bsecondb".
is 'the number is the name before the dash, zeros dropped, in number order' \
   "$(LC_ALL=en_US.UTF-8 review_checks_render "$T/order")" \
   "$(printf '1. First.\n2. Second.\n2b. Second b.\n3. Third.\n10. Tenth.')"

mkdir "$T/multi"
printf '\n\nFirst line.\nSecond line.\n\n\n' > "$T/multi/05-multi.md"
is 'leading and trailing blank lines are layout; lines in between stay' \
   "$(review_checks_render "$T/multi")" "$(printf '5. First line.\nSecond line.')"

mkdir "$T/text"
printf 'Keep $HOME, `x` and \\n as written.\n' > "$T/text/01-literal.md"
is 'the text is sent as written, never expanded' \
   "$(review_checks_render "$T/text")" '1. Keep $HOME, `x` and \n as written.'

# ── applies_to ────────────────────────────────────────────────────────────
mkdir "$T/lang"
printf 'Always.\n' > "$T/lang/01-always.md"
printf -- '---\napplies_to: *.py *.pyi\n---\nPython rules.\n' > "$T/lang/13-python.md"
printf -- '---\napplies_to: *.ts\n---\n\nTypeScript rules.\n' > "$T/lang/14-typescript.md"
is 'a PR that changes a .py file gets the Python item, not the TypeScript one' \
   "$(review_checks_render "$T/lang" "$(printf 'README.md\nsrc/app/main.py')")" \
   "$(printf '1. Always.\n13. Python rules.')"
is 'the glob crosses directories' \
   "$(review_checks_render "$T/lang" 'a/b/c/d.pyi' | tail -1)" '13. Python rules.'
is 'a PR with no matching file gets only the unconditional items' \
   "$(review_checks_render "$T/lang" 'docs/x.md')" '1. Always.'
is 'no changed-path list (startup, replay): every item is rendered' \
   "$(review_checks_render "$T/lang" | cut -c1-3 | tr '\n' ' ')" '1.  13. 14. '
mkdir "$T/only-lang"
cp "$T/lang/13-python.md" "$T/lang/14-typescript.md" "$T/only-lang/"
is 'a PR no item applies to is refused, not reviewed with an empty list' \
   "$(review_checks_render "$T/only-lang" 'docs/x.md' 2>&1 >/dev/null || echo refused)" \
   "$(printf "no item in %s applies to this PR's files\nrefused" "$T/only-lang")"
# The glob must match the path, not files in the current directory.
# Run from a directory holding z.py: a glob expanded there would become the
# literal z.py and stop matching src/a.py.
is 'a glob is never expanded against the working directory' \
   "$(cd "$T/lang" && touch z.py && review_checks_render "$T/lang" 'src/a.py')" "$(printf '1. Always.\n13. Python rules.')"

# ── refusals ──────────────────────────────────────────────────────────────
refused 'a directory that does not exist is refused' "$T/nope" 'does not exist'
mkdir "$T/empty"
refused 'a directory with no .md file is refused' "$T/empty" 'no .md files'
mkdir "$T/misnamed"; printf 'x\n' > "$T/misnamed/python.md"
refused 'a file with no item number is refused' "$T/misnamed" 'name it like'
mkdir "$T/dup"; printf 'a\n' > "$T/dup/02-a.md"; printf 'b\n' > "$T/dup/002-b.md"
refused 'two files with one item number are refused' "$T/dup" 'is taken'
mkdir "$T/blank"; printf '\n\n' > "$T/blank/01-blank.md"
refused 'an empty item is refused' "$T/blank" 'is empty'
mkdir "$T/typo"; printf -- '---\napplies-to: *.py\n---\nx\n' > "$T/typo/01-typo.md"
refused 'a misspelled front-matter key is refused, not ignored' "$T/typo" 'unknown front-matter line'
mkdir "$T/open"; printf -- '---\napplies_to: *.py\n' > "$T/open/01-open.md"
refused 'front matter with no closing line is refused' "$T/open" 'no closing'
mkdir "$T/bare"; printf -- '---\n---\nx\n' > "$T/bare/01-bare.md"
refused 'front matter with no applies_to is refused' "$T/bare" 'without applies_to'
mkdir "$T/big"
head -c "$REVIEW_CHECKS_MAX_BYTES" /dev/zero | tr '\000' 'a' > "$T/big/01-a.md"
printf 'b\n' > "$T/big/02-b.md"
refused 'a directory over the size limit is refused' "$T/big" 'bytes together'

# ── the stock directory ───────────────────────────────────────────────────
is 'the stock checks/ renders 1-12 plus 2b' \
   "$(review_checks_render checks | grep -oE '^[0-9]+[a-z]?\.' | tr '\n' ' ')" \
   '1. 2. 2b. 3. 4. 5. 6. 7. 8. 9. 10. 11. 12. '

# ── the startup check in pr-autoreview.sh, run as written ─────────────────
# It sits below the single-instance lock, out of reach of the startup smoke
# test, so its lines are cut out and run here.
START="$(awk '/^CHECKS_DIR="\$\{PRREVIEW_GATE_CHECKS_DIR/,/refusing to run/' pr-autoreview.sh)"
run_start() { # $1 = PRREVIEW_GATE_CHECKS_DIR, $2 = directory to start in
  (cd "$2" && PRREVIEW_GATE_CHECKS_DIR="$1" SCRIPT_DIR="$OLDPWD" bash -c \
     ". \"\$SCRIPT_DIR/lib/review-spec.sh\"; $START
      printf '%s' \"\$CHECKS_DIR\"" 2>/dev/null)
}
is 'a checks directory that does not exist stops the gate with status 2' \
   "$(run_start "$T/missing" "$T" >/dev/null; echo $?)" 2
is 'a relative checks directory is made absolute before any PR is reviewed' \
   "$(run_start lang "$T")" "$T/lang"

if [ "$FAILED" -eq 0 ]; then echo "PASS: review checks"; else echo "FAIL: review checks"; exit 1; fi
