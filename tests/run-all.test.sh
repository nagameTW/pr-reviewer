#!/usr/bin/env bash
# tests/run-all.sh: it runs every script with the bash that runs it, fails when
# the linter is missing, and prints tool versions first.
#
# A CI job on macOS runs the suite with /bin/bash (3.2). That job tests bash
# 3.2 only if each test, and each `bash` a test starts, is that same bash.
#
# Each case runs a copy of run-all.sh in a small throwaway repo, so the
# case does not start the whole suite again.
#
# Run: bash tests/run-all.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
for h in ok bad is has; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A repo with one script, and one test that records which bash runs it.
REPO="$T/repo"
mkdir -p "$REPO/tests"
cp tests/run-all.sh "$REPO/tests/run-all.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$REPO/ok.sh"
cat > "$REPO/tests/probe.test.sh" <<'EOF'
#!/usr/bin/env bash
# The nested path is a symlink to $BASH, so compare the files, not the names.
# The symlink is gone when run-all.sh ends, so compare while the test runs.
nested="$(bash -c 'printf %s "$BASH"')"
{ printf 'test=%s\n' "$BASH"; if [ "$nested" -ef "$BASH" ]; then echo nested=same; else echo "nested=$nested"; fi; } > "$PROBE_OUT"
EOF
git -C "$REPO" init -q

# A `bash` that is not the one under test, first on PATH.
mkdir -p "$T/wrong"
printf '#!/bin/sh\necho WRONG-BASH\nexit 99\n' > "$T/wrong/bash"
chmod +x "$T/wrong/bash"

run_all() { PROBE_OUT="$T/probe" PATH="$1" "$BASH" "$REPO/tests/run-all.sh" 2>&1; }

# ── each test runs with the bash that runs run-all.sh ──────────────────────
OUT="$(run_all "$T/wrong:$PATH")"; RC=$?
is  'the run passes while another bash is first on PATH' "$RC" 0
has '...and prints ALL PASS' 'ALL PASS' "$OUT"
is  'a test runs with the bash that runs run-all.sh' "$(sed -n 's/^test=//p' "$T/probe" 2>/dev/null)" "$BASH"
is  'a bash a test starts is that same bash' "$(sed -n 's/^nested=//p' "$T/probe" 2>/dev/null)" same

# ── tool versions come first ───────────────────────────────────────────────
HEAD="$(printf '%s\n' "$OUT" | head -5)"
for t in bash gh git jq flock; do has "the first lines name $t" "$t" "$HEAD"; done
has 'the bash line is the bash under test' "$("$BASH" --version | head -1)" "$HEAD"

# ── no shellcheck: the run fails ───────────────────────────────────────────
# A PATH that holds git and the few tools run-all.sh calls, and no shellcheck.
mkdir -p "$T/nosc"
for n in git dirname basename mktemp rm sed cat ln head; do ln -s "$(command -v "$n")" "$T/nosc/$n"; done
ln -s "$BASH" "$T/nosc/bash"
OUT="$(run_all "$T/nosc")"; RC=$?
is  'a missing shellcheck makes the run fail' "$RC" 1
has '...and its line says FAIL' 'FAIL' "$(printf '%s\n' "$OUT" | grep '^shellcheck')"
has '...and ends with SOME CHECKS FAILED' 'SOME CHECKS FAILED' "$OUT"
has 'a missing tool prints as not found' 'not found' "$(printf '%s\n' "$OUT" | grep '^gh')"

# ── the temp directory goes away when the bash link cannot be made ──────────
# A PATH with a `ln` that fails. The run ends at once, so it must not leave
# the directory that holds the bash link.
mkdir -p "$T/noln" "$T/tmpd"
for n in git dirname mktemp rm; do ln -s "$(command -v "$n")" "$T/noln/$n"; done
printf '#!/bin/sh\nexit 1\n' > "$T/noln/ln"
chmod +x "$T/noln/ln"
TMPDIR="$T/tmpd" run_all "$T/noln" >/dev/null; RC=$?
is  'a bash link that cannot be made ends the run with status 1' "$RC" 1
is  '...and leaves no temp directory behind' "$(ls -A "$T/tmpd")" ''

if [ "$FAILED" -eq 0 ]; then echo "PASS: run-all"; else echo "FAIL: run-all"; exit 1; fi
