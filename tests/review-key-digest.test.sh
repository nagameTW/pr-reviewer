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
# The head part of the key has the same fault. It comes from its own
# `jq -r .headRefOid` call. If that call prints nothing the key is `-<digest>`,
# and if the field is missing the key is `null-<digest>`. grep -F anchors the
# key on the left with the marker and a space, so such a key cannot match the
# marker of a head that has its SHA. It matches a marker the gate posted under
# the same fault: the two notices that go out before the diff fetch carry
# `$MARKER $KEY`. Then any later head with the same title, description and
# base is called handled and never reviewed. The key gives no key unless the
# head is a full SHA. The diff fetch is a second guard, behind the key.
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
. lib/tools.sh  || { echo "FAIL: could not source lib/tools.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_JQ="$(command -v jq)"

# One directory per injected failure. Every stub writes $STUB_FIRED when it
# runs, so a case whose stub never ran cannot pass by doing nothing.
STUBS="$TMP/stubs"
mkdir -p "$STUBS/sha-exit1" "$STUBS/sha-silent" "$STUBS/jq-digest" "$STUBS/jq-head-exit1" "$STUBS/jq-head-silent"
printf '#!/bin/bash\n: > "$STUB_FIRED"\ncat >/dev/null\nexit 1\n' > "$STUBS/sha-exit1/sha256sum"
printf '#!/bin/bash\n: > "$STUB_FIRED"\ncat >/dev/null\nexit 0\n' > "$STUBS/sha-silent/sha256sum"
# Fails only the digest call, the one that takes `--arg extra`.
printf '#!/bin/bash\ncase "$*" in *"--arg extra"*) : > "$STUB_FIRED"; exit 5 ;; esac\nexec %q "$@"\n' "$REAL_JQ" > "$STUBS/jq-digest/jq"
# Fails only the read of the head, `jq -r .headRefOid`: with a status, and
# with an empty answer and status 0.
printf '#!/bin/bash\ncase "$*" in "-r .headRefOid") : > "$STUB_FIRED"; exit 5 ;; esac\nexec %q "$@"\n' "$REAL_JQ" > "$STUBS/jq-head-exit1/jq"
printf '#!/bin/bash\ncase "$*" in "-r .headRefOid") : > "$STUB_FIRED"; exit 0 ;; esac\nexec %q "$@"\n' "$REAL_JQ" > "$STUBS/jq-head-silent/jq"
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

# ── the head part: a key without a full head SHA is no key ───────────────────
# D is the digest part of the key of PRJ. H2 is another head of the same PR
# with the same title, description and base, so it has the same D.
D="${V020_KEY#*-}"
H2=fedcba9876543210fedcba9876543210fedcba98
PRJ2="$(jq -c --arg h "$H2" '.headRefOid = $h' <<<"$PRJ")"
with_marker() { # $1 = PR json, $2 = marker text: the PR json plus one gate comment
  jq -c --arg b "<!-- $M $2 -->" '. + {comments: [{author: {login: "review-bot"}, body: $b}], reviews: []}' <<<"$1"
}
handled() { prompt_head_handled "$@" && echo yes || echo no; }

# The marker of a head that has its SHA never matches a key without one.
for stub in jq-head-exit1 jq-head-silent; do
  is "$stub: the stub ran" "$(under "$stub" prompt_review_key "$PRJ" main >/dev/null; fired)" yes
  is "$stub: the marker of another head does not match" \
     "$(under "$stub" handled "$(with_marker "$PRJ" "$H2-$D")" "$M" "$AUTHORS" main)" no
done

# A marker the gate posted under that fault matches the key of any other head
# of the same PR that fails the same way.
HEADLESS="$(with_marker "$PRJ2" "-$D")"
is 'a healthy key does not match the marker that has no head' "$(handled "$HEADLESS" "$M" "$AUTHORS" main)" no
for stub in jq-head-exit1 jq-head-silent; do
  OUT="$(under "$stub" prompt_review_key "$PRJ" main)"; RC=$?
  is "$stub: no key (fail closed)" "$RC:$OUT" '1:'
  is "$stub: a later head is not handled on the strength of that marker" \
     "$(under "$stub" handled "$HEADLESS" "$M" "$AUTHORS" main)" no
done

# The head field is missing, empty or not a full SHA: the same.
H40_UPPER="$(printf '%s' "$H40" | tr a-f A-F)"
for head in null '' HEAD "${H40%?}" "${H40}0" "$H40_UPPER"; do
  J="$(jq -c --arg h "$head" '.headRefOid = $h' <<<"$PRJ")"
  OUT="$(prompt_review_key "$J" main)"; RC=$?
  is "head '$head': no key (fail closed)" "$RC:$OUT" '1:'
done
OUT="$(prompt_review_key "$(jq -c 'del(.headRefOid)' <<<"$PRJ")" main)"; RC=$?
is 'head field missing: no key (fail closed)' "$RC:$OUT" '1:'
OUT="$(prompt_review_key "$(jq -c '.headRefOid = null' <<<"$PRJ")" main)"; RC=$?
is 'head field null: no key (fail closed)' "$RC:$OUT" '1:'
for head in null '' HEAD; do
  J="$(with_marker "$(jq -c --arg h "$head" '.headRefOid = $h' <<<"$PRJ")" "$head-$D")"
  is "head '$head': a marker with that head does not make it handled" "$(handled "$J" "$M" "$AUTHORS" main)" no
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
for stub in sha-exit1 sha-silent jq-digest jq-head-exit1 jq-head-silent; do
  OUT="$(under "$stub" key_block)"
  has "$stub: the job skips with a fail-closed note" '(fail closed)' "$OUT"
  case "$OUT" in *reached*) bad "$stub: the job never reaches the code after the key" "got: $OUT" ;; *) ok "$stub: the job never reaches the code after the key" ;; esac
done

# ── behind the key: a head that is not a full SHA never reaches the review ──
# The key refuses such a head (above). The diff fetch is a second guard: it
# needs a full SHA for the head and calls gh only after that.
GH="$TMP/gh"
printf '#!/bin/bash\n: > "%s"\nexit 1\n' "$TMP/gh-called" > "$GH"; chmod +x "$GH"
for head in null '' HEAD "${H40%?}"; do
  rm -f "$TMP/gh-called"
  pr_diff_pinned owner/repo "$B40" "$head" "$TMP/pr.diff" 1 >/dev/null; RC=$?
  is "head '$head': the diff fetch refuses with status 1" "$RC" 1
  is "head '$head': gh is never called" "$([ -e "$TMP/gh-called" ] && echo yes || echo no)" no
done
is "head null: the merge base is not looked up either" "$(merge_base_sha owner/repo "$B40" null; echo "rc=$?")" 'rc=1'

# ── golden keys: the exact key for edge-case input, through every hash tool ─
# Each value below came from prompt_review_key as it is now. The input JSON is
# in the test, so a reader can check a value by hand: the digest is the first
# 12 hex digits of SHA-256 over `title \n body \n base branch \n`. A PR whose
# base is not the default branch adds `base commit \n`. jq -r adds the last
# newline. A change of the key shows up here as a changed value, not as a
# silent drift.
# Each case runs once per hash tool, with a PATH that holds only that tool,
# jq and cut, as tests/tool-fallbacks.test.sh does.
SHA2_BASE="$(tools_resolve >/dev/null 2>&1; [ -n "$SHA256_BIN" ] && printf '%s%s' "$(command -v "${SHA256_BIN%% *}")" "${SHA256_BIN#"${SHA256_BIN%% *}"}")"
[ -n "$SHA2_BASE" ] || { echo "  FAIL this machine has no SHA-256 command"; echo "FAIL: review key digest"; exit 1; }
HASHES="sha256sum gsha256sum shasum"
for t in $HASHES; do
  mkdir -p "$TMP/hash-$t"
  # shasum needs -a 256 first. A call that drops it fails, as on a real Mac.
  case "$t" in shasum) pre='[ "$1 $2" = "-a 256" ] || exit 2; shift 2; ' ;; *) pre='' ;; esac
  printf '#!/bin/bash\n%sexec %s "$@"\n' "$pre" "$SHA2_BASE" > "$TMP/hash-$t/$t"
  printf '#!/bin/bash\nexec %q "$@"\n' "$REAL_JQ" > "$TMP/hash-$t/jq"
  printf '#!/bin/bash\nexec %q "$@"\n' "$(command -v cut)" > "$TMP/hash-$t/cut"
  chmod +x "$TMP/hash-$t"/*
done
B2=fedcba9876543210fedcba9876543210fedcba98
key_rc() { local out rc; tools_resolve >/dev/null 2>&1; out="$(prompt_review_key "$1" main)"; rc=$?; printf '%s:%s' "$rc" "$out"; }
# golden NAME JSON DIGEST: @HEAD@, @BASE@ and @BASE2@ in JSON stand for full
# SHAs. DIGEST is the 12 hex digits after the head, or empty when the key is
# no key (status 1, nothing printed).
golden() {
  local t j want
  j="${2//@HEAD@/$H40}"; j="${j//@BASE@/$B40}"; j="${j//@BASE2@/$B2}"
  if [ -n "$3" ]; then want="0:$H40-$3"; else want='1:'; fi
  for t in $HASHES; do
    # hash -r: the shell must not reuse a path it learned from the full PATH.
    # shellcheck disable=SC2123  # the PATH of this case holds one hash tool
    is "$t alone: $1" "$(PATH="$TMP/hash-$t"; hash -r; key_rc "$j")" "$want"
  done
}

# No base commit, or a title jq cannot join to a string: no key.
golden 'baseRefOid missing: no key' \
  '{"headRefOid":"@HEAD@","title":"t","body":"b","baseRefName":"main"}' ''
golden 'baseRefOid null: no key' \
  '{"headRefOid":"@HEAD@","title":"t","body":"b","baseRefName":"main","baseRefOid":null}' ''
golden 'title is a number: no key' \
  '{"headRefOid":"@HEAD@","title":42,"body":"b","baseRefName":"main","baseRefOid":"@BASE@"}' ''

# An empty body, a null body and a missing body are one key.
golden 'empty body' \
  '{"headRefOid":"@HEAD@","title":"t","body":"","baseRefName":"main","baseRefOid":"@BASE@"}' cf0da5c8a2cf
golden 'null body' \
  '{"headRefOid":"@HEAD@","title":"t","body":null,"baseRefName":"main","baseRefOid":"@BASE@"}' cf0da5c8a2cf
golden 'body missing' \
  '{"headRefOid":"@HEAD@","title":"t","baseRefName":"main","baseRefOid":"@BASE@"}' cf0da5c8a2cf

# Multi-byte characters: accented letters, math symbols and an emoji, in title
# and body.
golden 'accented letters, math symbols and emoji in title and body' \
  '{"headRefOid":"@HEAD@","title":"café naïve façade 🚀","body":"∑ ∂ →\ncafé façade 🎉.","baseRefName":"main","baseRefOid":"@BASE@"}' 3fcaebfdcedb
# The key hashes the decoded text, so the escaped and the literal emoji agree.
golden 'emoji as a JSON surrogate pair escape' \
  '{"headRefOid":"@HEAD@","title":"\ud83d\ude80","body":"","baseRefName":"main","baseRefOid":"@BASE@"}' 7f56826e7820
golden 'the same emoji as literal UTF-8' \
  '{"headRefOid":"@HEAD@","title":"🚀","body":"","baseRefName":"main","baseRefOid":"@BASE@"}' 7f56826e7820

# Newlines and carriage returns reach the digest as they are.
golden 'CRLF and LF in title and body' \
  '{"headRefOid":"@HEAD@","title":"a\r\nb","body":"x\r\ny\nz\r","baseRefName":"main","baseRefOid":"@BASE@"}' a2aa832f6921
# Trade-off: the digest joins title, body and base branch with a newline and
# escapes nothing, so a newline that moves from the title into the body gives
# the same key. Both inputs below have the digest input "a\nb\nc\nmain\n".
golden 'title "a\nb", body "c"' \
  '{"headRefOid":"@HEAD@","title":"a\nb","body":"c","baseRefName":"main","baseRefOid":"@BASE@"}' 5e57c96dfe27
golden 'title "a", body "b\nc": the same key' \
  '{"headRefOid":"@HEAD@","title":"a","body":"b\nc","baseRefName":"main","baseRefOid":"@BASE@"}' 5e57c96dfe27

# Only the base changes. The base branch name is part of every digest, so a
# PR into feat/parent has another key than a PR into main. For a stacked PR
# the base commit is part of the digest too. For a PR into the default branch
# it is not: that key is the same for any base commit.
golden 'base main' \
  '{"headRefOid":"@HEAD@","title":"t","body":"b","baseRefName":"main","baseRefOid":"@BASE@"}' 7ed1dd102b1d
golden 'base main, another base commit: the same key' \
  '{"headRefOid":"@HEAD@","title":"t","body":"b","baseRefName":"main","baseRefOid":"@BASE2@"}' 7ed1dd102b1d
golden 'base feat/parent: another key than base main' \
  '{"headRefOid":"@HEAD@","title":"t","body":"b","baseRefName":"feat/parent","baseRefOid":"@BASE@"}' ca2a8f32c314
golden 'base feat/parent, another base commit: another key' \
  '{"headRefOid":"@HEAD@","title":"t","body":"b","baseRefName":"feat/parent","baseRefOid":"@BASE2@"}' a657e15ac910

# Only whitespace in the body changes. The body is hashed byte for byte: no
# trimming and no folding of spaces, so a whitespace edit asks for a new review.
golden 'body "Line one.\nLine two."' \
  '{"headRefOid":"@HEAD@","title":"t","body":"Line one.\nLine two.","baseRefName":"main","baseRefOid":"@BASE@"}' fc7f3f63baf2
golden 'body with two spaces before "two": another key' \
  '{"headRefOid":"@HEAD@","title":"t","body":"Line one.\nLine  two.","baseRefName":"main","baseRefOid":"@BASE@"}' 55766796b4b3

if [ "$FAILED" -eq 0 ]; then echo "PASS: review key digest"; else echo "FAIL: review key digest"; exit 1; fi
