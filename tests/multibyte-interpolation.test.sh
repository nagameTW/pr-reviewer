#!/usr/bin/env bash
# Guards one recurring bug class, not one bug.
#
# In a UTF-8 locale, homebrew bash 5.3 on macOS parses an unbraced expansion
# immediately followed by a multibyte character by rolling the first byte of
# that character INTO the variable name. Under `set -u` the mangled name is
# unbound and the whole job dies on the spot with `<name>�: unbound
# variable`. The same line is fine under LC_ALL=C and on Linux, so testing on
# Linux alone does not catch it.
#
# The blast direction is what earns a machine check: the death can land
# late in a round, after the part that looks like the work, so the gate
# looks like it worked and only a side effect silently never happens.
#
# Rule: an expansion directly followed by a non-ASCII character is written
# `${VAR}`, never `$VAR`. ASCII neighbours are fine and stay untouched.
#
# Run: bash tests/multibyte-interpolation.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Derived, never hand-maintained. A script added later and never added to a
# hand-kept copy of this list would sit outside the rule while the test
# reported a pass. Everything tracked outside
# tests/ is in scope; the test files themselves are excluded because they
# hand-write broken fixtures on purpose.
#
# Through a FILE, not `< <(git ls-files)`: a process substitution's exit status
# is invisible, so a failed listing would read as "no files, nothing wrong".
LISTF="$(mktemp)"; trap 'rm -f "$LISTF"' EXIT
# `prreview` has no .sh suffix, so it is named.
# Test files are exempt in any tests/ directory, for the
# reason above.
git ls-files --cached --others --exclude-standard '*.sh' prreview | grep -vE '(^|/)tests/' > "$LISTF" || { echo "FAIL: git ls-files failed — refusing to report a pass"; exit 1; }
FILES=()
while IFS= read -r f; do [ -e "$f" ] && FILES+=("$f"); done < "$LISTF"
[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: no shell scripts found — this check tested nothing"; exit 1; }

fail=0
for f in "${FILES[@]}"; do
  [ -e "$f" ] || continue
  hits="$(perl -ne 'print "$ARGV:$.: $&\n" if /\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7F])/' "$f")"
  if [ -n "$hits" ]; then
    echo "FAIL unbraced expansion touching a multibyte character (dies under set -u in a UTF-8 locale on bash 5.3/macOS):"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fail=1
  fi
done

# The check must be able to see the pattern at all: a probe string with the
# exact shape has to hit, or a perl/regex regression turns this whole file
# into a silent pass.
probe='x $VARéx'
if ! printf '%s\n' "$probe" | perl -ne 'exit 1 unless /\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7F])/'; then
  echo "FAIL self-probe: the detector no longer matches its own target shape"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "multibyte-interpolation: ok"
fi
exit "$fail"
