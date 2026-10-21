#!/usr/bin/env bash
# The review key when the step that makes its digest fails.
#
# The key is `<head sha>-<12 hex of a digest of title, body, base>`. The
# digest is `jq ... | sha256sum | cut -c1-12` inside a command substitution,
# so a stage that dies does not change the exit status of the function. A key
# of `<head sha>-` is still a non-empty string, and grep -F finds it inside
# every marker the gate ever posted for that head. The real function and the
# real KEY line of pr-autoreview.sh run here, with a stub on PATH that makes
# one stage fail. A missing digest must give no key, as a missing base commit
# does: the job then skips the PR and the dispatcher does not call it handled.
#
# The last cases pin the guard behind a head that is not a full SHA. The key
# does not check the head. The diff fetch does, before anything is reviewed.
#
# Run: bash tests/review-key-digest.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
for h in ok bad is has; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

. lib/prompt.sh || { echo "FAIL: could not source lib/prompt.sh"; exit 1; }
. lib/merge.sh  || { echo "FAIL: could not source lib/merge.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_JQ="$(command -v jq)"

# One directory per injected failure. Every stub writes $STUB_FIRED when it
# runs, so a case whose stub never ran cannot pass by doing nothing.
STUBS="$TMP/stubs"
mkdir -p "$STUBS/sha-exit1" "$STUBS/sha-silent" "$STUBS/jq-digest"
printf '#!/bin/bash\n: > "$STUB_FIRED"\ncat >/dev/null\nexit 1\n' > "$STUBS/sha-exit1/sha256sum"
printf '#!/bin/bash\n: > "$STUB_FIRED"\ncat >/dev/null\nexit 0\n' > "$STUBS/sha-silent/sha256sum"
# Fails only the digest call, the one that takes `--arg extra`.
printf '#!/bin/bash\ncase "$*" in *"--arg extra"*) : > "$STUB_FIRED"; exit 5 ;; esac\nexec %q "$@"\n' "$REAL_JQ" > "$STUBS/jq-digest/jq"
chmod +x "$STUBS"/*/*

# $1 = stub directory name, then the command. Runs it with that stub first on
# PATH and says whether the stub ran.
FIRED="$TMP/fired"
under() {
  local stub="$1"; shift
  rm -f "$FIRED"
  ( PATH="$STUBS/$stub:$PATH"; export STUB_FIRED="$FIRED"; "$@" )
}
fired() { [ -e "$FIRED" ] && echo yes || echo no; }

H40=0123456789abcdef0123456789abcdef01234567
B40=89abcdef0123456789abcdef0123456789abcdef
PRJ="{\"headRefOid\":\"$H40\",\"title\":\"fix: keep the key\",\"body\":\"Line one.\\nLine two, ünïcode.\",\"baseRefName\":\"main\",\"baseRefOid\":\"$B40\"}"
STK="$(jq -c '.baseRefName = "feat/parent"' <<<"$PRJ")"
# The v0.2.0 key of PRJ (tests/prompt.test.sh has the same line).
V020_KEY="$H40-7df6371f5f84"
is 'baseline: the key of an ordinary PR, no stub' "$(prompt_review_key "$PRJ" main)" "$V020_KEY"

# ── the function: a broken digest step gives no key ─────────────────────────
for J in "$PRJ" "$STK"; do
  kind="base $(jq -r .baseRefName <<<"$J")"
  for stub in sha-exit1 sha-silent jq-digest; do
    OUT="$(under "$stub" prompt_review_key "$J" main)"; RC=$?
    is "$kind, $stub: the stub ran" "$(fired)" yes
    is "$kind, $stub: no key (fail closed)" "$RC:$OUT" '1:'
  done
done

# ── the dispatcher: a head is not handled on the strength of a broken digest ─
# The gate posted a verdict for the ordinary key. The author then edits the
# title, so the healthy key is a new one and the head must be reviewed again.
M="pr-reviewer"
AUTHORS="review-bot"
HANDLED="$(jq -c --arg b "<!-- $M $V020_KEY -->" '. + {comments: [{author: {login: "review-bot"}, body: $b}], reviews: []}' <<<"$PRJ")"
EDITED="$(jq -c '.title = "fix: a title written after the review"' <<<"$HANDLED")"
is 'healthy digest: the unedited head is handled' \
   "$(prompt_head_handled "$HANDLED" "$M" "$AUTHORS" main && echo yes || echo no)" yes
is 'healthy digest: the edited title makes it unhandled' \
   "$(prompt_head_handled "$EDITED" "$M" "$AUTHORS" main && echo yes || echo no)" no
for stub in sha-exit1 sha-silent jq-digest; do
  is "$stub: an edited title is not called handled" \
     "$(under "$stub" prompt_head_handled "$EDITED" "$M" "$AUTHORS" main && echo yes || echo no)" no
done

# ── the job: its own KEY line, lifted from pr-autoreview.sh ─────────────────
KEY_SRC="$(awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }' pr-autoreview.sh | grep -E '^  KEY="\$\(prompt_review_key ')"
is 'the job KEY line was found' "$([ -n "$KEY_SRC" ] && echo yes)" yes
note_skip() { echo "skip: $1"; }
eval "key_block() { $KEY_SRC
echo \"reached \$KEY\"; }"
# shellcheck disable=SC2034  # read by the lifted line
DEFAULT_BRANCH=main
# shellcheck disable=SC2034
INFO="$PRJ"
is 'the job KEY line with no stub gets the key' "$(key_block)" "reached $V020_KEY"
for stub in sha-exit1 sha-silent jq-digest; do
  OUT="$(under "$stub" key_block)"
  has "$stub: the job skips with a fail-closed note" '(fail closed)' "$OUT"
  case "$OUT" in *reached*) bad "$stub: the job never reaches the code after the key" "got: $OUT" ;; *) ok "$stub: the job never reaches the code after the key" ;; esac
done

# ── behind the key: a head that is not a full SHA never reaches the review ──
# `.headRefOid` read from a PR with no such field prints `null`, and the key
# takes it as it is. The diff fetch is the guard: it needs a full SHA for the
# head and calls gh only after that.
GH="$TMP/gh"
printf '#!/bin/bash\n: > "%s"\nexit 1\n' "$TMP/gh-called" > "$GH"; chmod +x "$GH"
for head in null '' HEAD "${H40%?}"; do
  rm -f "$TMP/gh-called"
  pr_diff_pinned owner/repo "$B40" "$head" "$TMP/pr.diff" 1 >/dev/null; RC=$?
  is "head '$head': the diff fetch refuses with status 1" "$RC" 1
  is "head '$head': gh is never called" "$([ -e "$TMP/gh-called" ] && echo yes || echo no)" no
done
is "head null: the merge base is not looked up either" "$(merge_base_sha owner/repo "$B40" null; echo "rc=$?")" 'rc=1'

if [ "$FAILED" -eq 0 ]; then echo "PASS: review key digest"; else echo "FAIL: review key digest"; exit 1; fi
