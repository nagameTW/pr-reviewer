#!/usr/bin/env bash
# Every tempfile a reviewer either reads (the diff, the intent, a slice) or
# whose content decides a verdict (the raw model output, the sensitive-patterns
# file the outbound scan trusts) has to live outside /tmp. Every process on the
# machine can write to /tmp, so a file there is one a prompt-injected model
# with any way to write could forge.
# A machine check outlives a review round.
#
# Run: bash tests/tmp-discipline.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
ok()   { printf '  ok   %s\n' "$*"; }

# script | the variable holding its confined root | variables to track
#
# One table rather than pr-autoreview.sh alone: the
# same diff moved nine scripts off /tmp and only one of them was pinned, so
# the others could go back to `mktemp -d /tmp/...` with the suite still
# green.
#
# NOT tracked, and still in /tmp deliberately: pr-autoreview.sh's per-call
# USAGE_DIR and QUOTA_DIR marker directories (empty files, counted, never
# read as content) and PROT_ERR (a stderr capture, printed to the run's own
# log, never fed to a model or read back as a verdict) — moving those buys
# nothing since a forged one has nothing to forge. CRASH_DIR and REPAIR_ERR
# are NOT in that list: both already live under $GATE_SCRATCH (the crash
# count decides whether an alert fires), they are simply not part of this
# table.
TRACKED=(
  "pr-autoreview.sh|GATE_SCRATCH|PATS_FILE DIFF_DIR CONV_LIST SLICE_DIR INTENT_DIR TREE_LIST REVIEW_ERR SLICE_RAW_F SLICE_JSONS RT_OUT RT_ERR V_FILE_OUT V_FILE_ERR"
  "owner-alert.sh|ALERT_WORKROOT|PATS_FILE"
)

N_CHECKED=0
for row in "${TRACKED[@]}"; do
  IFS='|' read -r script root vars <<<"$row"
  [ -f "$script" ] || { fail "$script is in the tracked table but not in the tree — renamed or deleted without updating this test"; continue; }
  for v in $vars; do
    # POSITIVE assertion, not "does the line say /tmp":
    # the old spelling only rejected a literal /tmp/, so dropping the template
    # entirely — `DIFF="$(mktemp)"`, which lands in $TMPDIR or /tmp — passed
    # while the summary line below still claimed everything was confined.
    if ! grep -qE "^[[:space:]]*${v}=\"\\\$\\(mktemp( -d)? \"\\\$${root}/" "$script"; then
      fail "$script: $v is not built as mktemp under \"\$$root/\" — a reviewer-visible or verdict-carrying tempfile outside the confined root can be forged by anything else that writes to /tmp"
      grep -nE "^[[:space:]]*${v}=" "$script" | sed 's/^/      /'
    fi
    N_CHECKED=$((N_CHECKED + 1))
  done
done
[ "$RC" = 0 ] && ok "all $N_CHECKED tracked tempfiles across ${#TRACKED[@]} scripts are built under their script's confined root"

# The table has to describe variables that actually exist, or every grep above
# found nothing to match against and the whole check passes vacuously.
MISSING=0
for row in "${TRACKED[@]}"; do
  IFS='|' read -r script _root vars <<<"$row"
  [ -f "$script" ] || continue
  for v in $vars; do
    grep -qE "^[[:space:]]*${v}=" "$script" \
      || { fail "$script: tracked variable $v no longer exists — renamed? this check is testing nothing for it"; MISSING=$((MISSING + 1)); }
  done
done
[ "$RC" = 0 ] && [ "$MISSING" = 0 ] && ok "every tracked variable is still present in its script"

# ---------------------------------------------------------------------------
# Derived sweep over EVERY script, not just the table. The
# table above is hand-maintained: a NEW script
# with its own tempfiles can ship a bare, untemplated `mktemp -d` — which
# defaults straight to $TMPDIR (usually /tmp) and carries no literal "/tmp"
# string for a naive grep to catch — and the table never sees it. That is
# exactly how one script shipped ("the check's table
# never got this script, so it does not apply to it at all"). The file list
# is derived from git ls-files so nobody has to remember to add a row for the
# sweep to bite; the table keeps the stronger positive assertion (the right
# variable under the right root) for the scripts it names.
#
# Through a FILE, not `< <(git ls-files)`: a process substitution's exit
# status is invisible, so a failed listing would read as "no files, nothing
# wrong".
LISTF="$(mktemp)"; trap 'rm -f "$LISTF"' EXIT
# `prreview` has no .sh suffix, so it is named.
# Test files are exempt in any tests/ directory: they
# write the patterns this scan forbids as fixtures.
git ls-files --cached --others --exclude-standard '*.sh' prreview | grep -vE '(^|/)tests/' > "$LISTF" || { echo "FAIL: git ls-files failed — refusing to report a pass"; exit 1; }
FILES=()
while IFS= read -r f; do [ -e "$f" ] && FILES+=("$f"); done < "$LISTF"
[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: no shell scripts found — this check tested nothing"; exit 1; }

# The one exemption list, scoped to pr-autoreview.sh alone so a new script
# cannot borrow the names: USAGE_DIR/QUOTA_DIR are per-call marker
# directories (empty files, counted, never read as content) and PROT_ERR is
# a stderr capture printed to the run's own log, never fed to a model or
# read back as a verdict — a forged one has nothing to forge. Same three
# names the table's header comment keeps; everything else that mktemps, in
# any script, is expected to be off /tmp with no exception filed.
EXEMPT_VARS=(USAGE_DIR QUOTA_DIR PROT_ERR)
exempt_pattern="$(IFS='|'; echo "${EXEMPT_VARS[*]}")"

# Catches an explicit `/tmp/` template anywhere in the mktemp call, AND a
# bare `mktemp` / `mktemp -d` (short flags only, no template at all) — the
# latter is the shape a literal-"/tmp/" grep cannot see. The bare-call side
# terminates on a shell metacharacter (`)`, `&&`, `||`, `;`, a redirect, a
# backtick), not only `)` — `mktemp -d 2>/dev/null || echo fallback` has no
# template either, and the first version of this regex missed it for exactly
# that reason (caught live).
BARE='\$\(mktemp([[:space:]]+-[a-zA-Z])*[[:space:]]*(\)|&&|\|\||;|2>|1>|>|<|`)'
TEMPLATED_TMP='\$\(mktemp[^)]*/tmp/'
SWEPT=0
for f in "${FILES[@]}"; do
  HIT="$(grep -nE "$BARE|$TEMPLATED_TMP" "$f")"
  if [ "$f" = "pr-autoreview.sh" ] && [ -n "$HIT" ]; then
    HIT="$(grep -vE "^[0-9]+:[[:space:]]*($exempt_pattern)=" <<<"$HIT")"
  fi
  if [ -n "$HIT" ]; then
    fail "$f builds a tempfile that lands in /tmp (explicit /tmp/ template, or bare mktemp with no template) — anything on the machine can write there, so a reviewer's input or verdict could be forged; build it under the script's confined root and add the variable to the TRACKED table above"
    sed 's/^/      /' <<<"$HIT"
  fi
  SWEPT=$((SWEPT + 1))
done
[ "$RC" = 0 ] && ok "swept $SWEPT scripts from git ls-files: no bare or /tmp-templated mktemp outside the named exemptions"

# BSD mktemp (macOS) replaces only a TRAILING run of X's: `name-XXXX.diff` is
# one fixed file name there, and two parallel jobs collide on it.
SUFFIXED="$(grep -nE 'mktemp[^|;]*XXX+[^X"'"'"' )]' "${FILES[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
if [ -n "$SUFFIXED" ]; then
  fail "a mktemp template has text after its X's, which BSD mktemp leaves as a fixed name:"
  sed 's/^/      /' <<<"$SUFFIXED"
else
  ok "every mktemp template ends in its X's"
fi

[ "$RC" = 0 ] && echo "tmp-discipline: all checks passed"
exit "$RC"
