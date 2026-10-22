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

# Tests and scripts start `bash` by name or by `#!/usr/bin/env bash`. Put the
# bash that runs this file first on PATH, so that bash is the one under test
# everywhere. On macOS a Homebrew bash can come before /bin/bash on PATH, and
# the suite would then test that bash and not the system's 3.2.
BASH_DIR="$(mktemp -d)" || exit 1
ln -s "$BASH" "$BASH_DIR/bash" || exit 1
PATH="$BASH_DIR:$PATH"

# Versions first, so a failure log shows which tools produced it. A missing
# tool is not an error here: the tests stub gh and flock, and the checks below
# report anything a test needs and lacks.
tool_version() {
  local label="$1" line; shift
  if ! command -v "$1" >/dev/null 2>&1; then printf '%-10s not found\n' "$label"; return 0; fi
  line="$("$@" 2>&1 | head -1)"
  printf '%-10s %s\n' "$label" "${line:-no version output}"
}
tool_version bash "$BASH" --version
tool_version gh gh --version
tool_version git git --version
tool_version jq jq --version
tool_version flock flock --version

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
LISTF="$(mktemp)"; trap 'rm -rf "$LISTF" "$BASH_DIR"' EXIT
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
  for f in "${SH[@]}"; do "$BASH" -n "$f" || rc=1; done
  return "$rc"
}
run "bash -n (${#SH[@]} scripts)" syntax_all

# Lint. A missing shellcheck is a failure, not a skip: a run without lint
# looks the same as a run with clean lint, and a CI job that lost the tool
# would stay green. (Do NOT start this comment with the linter's own name: a
# comment beginning `# shellcheck ...` is parsed as a DIRECTIVE, and this one
# made the file unparseable — which the tool reports as two errors against
# this file rather than as "your comment is the problem". Found the first time
# the linter was actually installed on the machine running this.)
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
  printf '%-28s FAIL (not installed)\n' "shellcheck"
  FAILED=1
fi

for t in tests/*.test.sh; do
  run "$(basename "$t")" "$BASH" "$t"
done

if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
