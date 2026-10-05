#!/usr/bin/env bash
# Everything this repo can check without network, gh, or the App key.
# Run before opening a PR and before merging.
#
# One command, no dependencies beyond bash and the tools the scripts already
# require, so a local run and a CI run check exactly the same things.
#
# Run: bash tests/run-all.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

FAILED=0
run() {
  printf '%-28s ' "$1"
  shift
  if out="$("$@" 2>&1)"; then
    printf 'ok\n'
  else
    printf 'FAIL\n'
    sed 's/^/    /' <<<"$out"
    FAILED=1
  fi
}

# Syntax first: a parse error makes every test below meaningless.
# Read loop rather than `mapfile`, which is bash 4+ — these checks also get run
# on macOS's bash 3.2, and the first version of this file used mapfile, failed
# to collect anything, skipped `bash -n` entirely, and still printed ALL PASS.
# A check that collects nothing must not pass, so: empty list is fatal,
# never a silent pass.
# Through a FILE, not `< <(git ls-files)`: a process substitution's exit status
# is invisible to `set -e` and to pipefail, so a git that dies part way through
# leaves a non-empty but TRUNCATED list — this runner then lints a subset and
# prints ALL PASS. Same class as the mapfile bug above, same lesson.
LISTF="$(mktemp)"; trap 'rm -f "$LISTF"' EXIT
git ls-files --cached --others --exclude-standard '*.sh' prreview > "$LISTF" || { echo "git ls-files failed — refusing to report a pass"; exit 1; }
SH=()
while IFS= read -r f; do SH+=("$f"); done < "$LISTF"
[ "${#SH[@]}" -gt 0 ] \
  || { echo "no .sh files found — refusing to report a pass"; exit 1; }
# ONE FILE PER CALL. `bash -n a.sh b.sh` reads only a.sh and turns the rest
# into positional parameters, so the obvious batch form silently checks the
# first script and green-lights the other ten. Caught by appending a syntax
# error to a script and watching this file still print ALL PASS.
syntax_all() {
  local f rc=0
  for f in "${SH[@]}"; do bash -n "$f" || rc=1; done
  return "$rc"
}
run "bash -n (${#SH[@]} scripts)" syntax_all

# Lint, if the tool is present — not a hard requirement, the box may not have
# it. (Do NOT start this comment with the linter's own name: a comment
# beginning `# shellcheck ...` is parsed as a DIRECTIVE, and this one made the
# file unparseable — which the tool reports as two errors against this file
# rather than as "your comment is the problem". Found the first time the
# linter was actually installed on the machine running this.)
#
# -S warning, not the default: the repo carries style/info findings
# (SC2015's A && B || C, SC2006 backticks, SC2001 sed-vs-expansion) that are
# either deliberate or cosmetic, and a gate nobody can get green is a gate
# people learn to skip. Errors and warnings are the "this is probably wrong"
# bar and they are held at zero.
# SC1091: sourced lib/ files are resolved at runtime, not by the linter.
if command -v shellcheck >/dev/null; then
  run "shellcheck" shellcheck -S warning -e SC1091 "${SH[@]}"
else
  printf '%-28s skipped (not installed)\n' "shellcheck"
fi

for t in tests/*.test.sh; do
  run "$(basename "$t")" bash "$t"
done

if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
