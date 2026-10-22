#!/usr/bin/env bash
# Who the reviewer reads: the trust rule (lib/trust.sh), the filter in the
# gate's PR loop, the second check in the review job, and
# `prreview once --pr owner/repo#N`. gh and claude are stubs, and the
# clone is a local repository, so nothing here uses the network or a model.
# Run: bash tests/trust.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "text containing '$3'" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "text without '$3'" "$2" ;; *) ok "$1" ;; esac; }
for h in ok bad is has lacks; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

# ── the rule: pr_author_trusted JSON ALLOWED TRIGGER ──────────────────────
if . lib/trust.sh 2>/dev/null; then ok 'lib/trust.sh loads'; else bad 'lib/trust.sh loads' 'a library file' 'missing'; fi
SAME='{"number":1,"author":{"login":"alice"},"isCrossRepository":false}'
FORK='{"number":2,"author":{"login":"Mallory"},"isCrossRepository":true}'
NOFIELD='{"number":3,"author":{"login":"mallory"}}'
trusted() { if pr_author_trusted "$@" 2>/dev/null; then echo trusted; else echo not-trusted; fi; }
is 'a PR from the same repository is trusted'           "$(trusted "$SAME" '' '')" trusted
is 'a PR from a fork is not trusted'                    "$(trusted "$FORK" '' '')" not-trusted
is 'a fork author on the list is trusted'               "$(trusted "$FORK" 'bob mallory' '')" trusted
is '...whatever the letter case of the login'           "$(trusted "$FORK" 'MALLORY' '')" trusted
is '...and the list may use commas'                     "$(trusted "$FORK" 'bob,mallory' '')" trusted
is 'a fork author that is not on the list stays out'    "$(trusted "$FORK" 'bob carol' '')" not-trusted
is 'a part of a login is not a login'                   "$(trusted "$FORK" 'mall' '')" not-trusted
is 'a fork PR that once --pr names is trusted'          "$(trusted "$FORK" '' 2)" trusted
is 'a trigger for another PR does not help'             "$(trusted "$FORK" '' 5)" not-trusted
is 'a missing isCrossRepository is not trusted'         "$(trusted "$NOFIELD" '' '')" not-trusted
is 'a missing author is not trusted'                    "$(trusted '{"number":4,"isCrossRepository":true}' 'mallory' '')" not-trusted
is 'a string where the boolean belongs is not trusted'  "$(trusted '{"number":5,"isCrossRepository":"false"}' '' '')" not-trusted
# Every path but the trigger needs the whole record: a whole PR number, a
# boolean fork flag, an author object and a login that is a non-empty string.
# A test that passes alone is not enough: an allowlisted login does not excuse
# a bad fork flag, and a same-repository flag does not excuse a bad author.
is 'a complete same-repository record is trusted'       "$(trusted '{"number":7,"isCrossRepository":false,"author":{"login":"alice"}}' '' '')" trusted
is 'a complete allowlisted fork record is trusted'      "$(trusted '{"number":7,"isCrossRepository":true,"author":{"login":"alice"}}' 'alice' '')" trusted
for F in '' ',"isCrossRepository":null' ',"isCrossRepository":"false"' ',"isCrossRepository":"true"' ',"isCrossRepository":0'; do
  is "an allowlisted author with this fork flag is not trusted: ${F:-missing}" \
     "$(trusted "{\"number\":6,\"author\":{\"login\":\"mallory\"}$F}" 'mallory' '')" not-trusted
done
for A in '' ',"author":null' ',"author":{}' ',"author":{"login":null}' ',"author":{"login":5}' ',"author":{"login":""}' ',"author":"alice"' ',"author":[]'; do
  is "a same-repository PR with this author is not trusted: ${A:-missing}" \
     "$(trusted "{\"number\":7,\"isCrossRepository\":false$A}" '' '')" not-trusted
done
for N in '' '"number":null,' '"number":"7",'; do
  is "a same-repository PR with this number is not trusted: ${N:-missing}" \
     "$(trusted "{${N}\"isCrossRepository\":false,\"author\":{\"login\":\"alice\"}}" '' '')" not-trusted
done
# The maintainer named the PR, so the other fields do not matter. The number
# must still be a whole number that equals the trigger.
is 'a named PR with a null author is trusted'           "$(trusted '{"number":2,"author":null}' '' 2)" trusted
is 'a named PR with only a number is trusted'           "$(trusted '{"number":2}' '' 2)" trusted
is 'a named PR with a bad fork flag is trusted'         "$(trusted '{"number":2,"isCrossRepository":"x","author":{"login":5}}' '' 2)" trusted
is 'a number in a string does not match the trigger'    "$(trusted '{"number":"2","author":null}' '' 2)" not-trusted
is 'a number with a fraction does not match the trigger' "$(trusted '{"number":2.5}' '' 2.5)" not-trusted
is 'a record without a number does not match the trigger' "$(trusted '{"author":null}' '' 2)" not-trusted
is 'text that is not JSON is not trusted'               "$(trusted 'not json' 'mallory' 7)" not-trusted
is 'an empty answer is not trusted'                     "$(trusted '' '' '')" not-trusted
is 'an answer of only white space is not trusted'       "$(trusted $' \n' '' '')" not-trusted
is 'text after a trusted record is not trusted'         "$(trusted '{"number":8,"isCrossRepository":false,"author":{"login":"alice"}} oops' '' '')" not-trusted

# ── the reference: owner/repo#N ───────────────────────────────────────────
ref() { trust_parse_pr_ref "$1" 2>/dev/null || echo rejected; }
is 'owner/repo#N is read'                   "$(ref 'owner/repo#12')" 'owner/repo 12'
is 'dots, dashes and underscores in the repo name are allowed' "$(ref 'my-org/my_repo.js#3')" 'my-org/my_repo.js 3'
for r in 'owner/repo' '#12' 'owner/repo#' 'owner/repo#0' 'owner/repo#012' 'owner/repo#12x' 'owner/repo# 12' \
         'owner#12' '/repo#12' 'owner/#12' 'a/b/c#12' 'owner/repo#1234567890' 'owner/repo#-1' \
         'https://github.com/owner/repo/pull/12' 'owner/repo#12;ls' 'owner/repo#12 extra' '' ' owner/repo#12' \
         'ow ner/repo#12' 'owner/repo#12
x'; do
  is "a bad reference is rejected: $(printf '%q' "$r")" "$(ref "$r")" rejected
done
is 'a repository on the list is found, in the list spelling' "$(trust_listed_repo 'OWNER/Repo' 'a/b owner/repo c/d')" 'owner/repo'
is 'a repository off the list is not found' "$(trust_listed_repo 'owner/other' 'a/b owner/repo' || echo none)" none
is 'part of a name is not a match' "$(trust_listed_repo 'owner/rep' 'owner/repo' || echo none)" none

# ── the plan: which numbers of a list are reviewed ────────────────────────
LIST='[{"number":1,"author":{"login":"alice"},"isCrossRepository":false,"labels":[]},
       {"number":2,"author":{"login":"mallory"},"isCrossRepository":true,"labels":[]},
       {"number":3,"author":{"login":"bob"},"isCrossRepository":true,"labels":[]},
       {"number":4,"labels":[]}]'
plan() { trust_plan_prs "$@" 2>/dev/null | tr '\n' ' '; }
is 'by default only the same-repository PR is reviewed' "$(plan "$LIST" '' 0 '')" 'review 1 skip 2 skip 3 skip 4 '
is 'a listed fork author is reviewed too'             "$(plan "$LIST" 'bob' 0 '')" 'review 1 skip 2 review 3 skip 4 '
is 'PRREVIEW_GATE_FORK_PRS=1 reviews every PR'         "$(plan "$LIST" '' 1 '')" 'review 1 review 2 review 3 review 4 '
is 'a named PR is the only one reviewed'               "$(plan "$LIST" '' 0 2)" 'review 2 '
is 'a named PR is reviewed whatever its other fields hold' "$(plan '[{"number":2,"author":null},{"number":3}]' '' 0 2)" 'review 2 '
is 'a named PR that is not open gives an empty plan'   "$(plan "$LIST" '' 0 9)" ''
is 'an empty list gives an empty plan'                 "$(plan '[]' '' 0 '')" ''
is 'a list that is not an array is refused'            "$(trust_plan_prs '{"a":1}' '' 0 '' >/dev/null 2>&1; echo $?)" 1
is 'text that is not JSON is refused'                  "$(trust_plan_prs 'oops' '' 0 '' >/dev/null 2>&1; echo $?)" 1
is 'an entry without a number is refused'              "$(trust_plan_prs '[{"author":{"login":"a"},"isCrossRepository":false}]' '' 0 '' >/dev/null 2>&1; echo $?)" 1

# ── the warning line, and the count that prreview status reads ─────────────
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
W="$(trust_warning 3 2>/dev/null)"
has 'the warning names the count'               "$W" 'WARNING: 3 PR(s) from forks were not reviewed'
has '...and the setting that reviews them all'  "$W" 'PRREVIEW_GATE_FORK_PRS=1'
has '...and the command that reviews one'       "$W" 'prreview once --pr owner/repo#N'
# Three kinds of line: a warning at the start of a line (3, then 7), and a
# warning behind a job prefix (9 before the 7, 11 after it). The answer is the
# last one at the start of a line: not the first (3), not the last of all (11).
W7="$(trust_warning 7 2>/dev/null)"
printf 'x\n%s\n[owner__repo#1] WARNING: 9 PR(s) from forks were not reviewed\n%s\n[owner__repo#2] WARNING: 11 PR(s) from forks were not reviewed\n' "$W" "$W7" > "$T/round.log"
is 'the count is read from the last warning at the start of a line' "$(trust_warning_count "$T/round.log" 2>/dev/null)" 7
is 'a log without the warning counts 0'    "$(trust_warning_count "$T/none.log" 2>/dev/null)" 0
. lib/loop.sh
printf '%s\n' "$W" > "$T/summary.log"
is 'the warning goes to gate.log'          "$(loop_gate_summary "$T/summary.log" | wc -l | tr -d ' ')" 1
printf '%s\n' 'owner/repo: not reviewed, fork PR by an author who is not trusted: #2 #3' > "$T/summary.log"
is 'the per-repository line stays out of gate.log' "$(loop_gate_summary "$T/summary.log" | wc -l | tr -d ' ')" 0

# ── the gate, run against stubs ───────────────────────────────────────────
mkdir -p "$T/bin" "$T/work" "$T/src"
( cd "$T/src" && git init -q -b main . && git config user.email a@users.noreply.github.com && git config user.name a \
  && echo hi > README.md && git add . && git commit -qm init ) || { echo "  FAIL could not make the test repository"; exit 1; }
cat > "$T/bin/claude" <<STUB_EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/claude.calls"
[ "\${1-}" = --version ] || exit 1
echo "2.1.305 (Claude Code)"
STUB_EOF
# A gh that answers from files in \$T and writes every call to gh.calls.
# list.json answers the open PR list, view-N.json answers `pr view N` (a
# draft when there is no file) and view-N.K.json answers its K-th call,
# list.rc is the exit code of the list, and
# merged.json answers the list of merged PRs (empty when there is no file).
# merge.rc is the exit code of `pr merge` (0 when there is no file).
cat > "$T/bin/gh" <<STUB_EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/gh.calls"
filter=""; prev=""
for a in "\$@"; do case "\$prev" in -q|--jq) filter="\$a" ;; esac; prev="\$a"; done
emit() { if [ -n "\$filter" ]; then jq -r "\$filter" <<<"\$1"; else printf '%s\n' "\$1"; fi; }
case "\$1 \$2" in
  "--version "*) printf 'gh version 2.63.0 (2024-11-27)\nhttps://github.com/cli/cli/releases/latest\n' ;;
  "repo clone") git clone -q "$T/src" "\$4" ;;
  "repo view") echo main ;;
  "pr list")
    case "\$*" in
      *"--state merged"*) if [ -f "$T/merged.json" ]; then cat "$T/merged.json"; else echo '[]'; fi ;;
      *) [ ! -s "$T/list.rc" ] || exit "\$(cat "$T/list.rc")"; emit "\$(cat "$T/list.json")" ;;
    esac ;;
  "pr view")
    k="\$(grep -c "^pr view \$3 " "$T/gh.calls")"
    if [ -f "$T/view-\$3.\$k.json" ]; then emit "\$(cat "$T/view-\$3.\$k.json")"
    elif [ -f "$T/view-\$3.json" ]; then emit "\$(cat "$T/view-\$3.json")"; else emit '{"isDraft":true}'; fi ;;
  "pr merge") [ ! -s "$T/merge.rc" ] || exit "\$(cat "$T/merge.rc")" ;;
  "pr comment") echo ok ;;
  "issue list") echo '[]' ;;
  "issue create") echo https://github.com/owner/repo/issues/99 ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$T/bin/claude" "$T/bin/gh"
printf '# patterns\nnever-matches-xyzzy\n' > "$T/patterns"
H="$T/home"; mkdir -p "$H"

# One round of the gate, in a clean environment; extra arguments are KEY=value
# settings. Prints the log and, on the last line, the exit code.
run_gate() {
  : > "$T/gh.calls"; : > "$T/claude.calls"
  env -i HOME="$H" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" CLAUDE_BIN="$T/bin/claude" \
    PRREVIEW_GATE_REPOS=owner/repo PRREVIEW_OWNER_LOGIN=owner PRREVIEW_SENSITIVE_PATTERNS_FILE="$T/patterns" \
    PRREVIEW_GATE_WORKROOT="$T/work" PRREVIEW_GATE_LOCK="$T/lock" "$@" bash "$ROOT/pr-autoreview.sh" 2>&1
  echo "rc=$?"
}
viewed() { grep -c "^pr view $1 " "$T/gh.calls" | tr -d ' '; }
set_list() { printf '%s\n' "$1" > "$T/list.json"; rm -f "$T/list.rc"; }
set_list '[{"number":1,"title":"A secret title","author":{"login":"alice"},"isCrossRepository":false,"labels":[]},
           {"number":2,"title":"Another secret title","author":{"login":"mallory"},"isCrossRepository":true,"labels":[]}]'

OUT="$(run_gate)"
is 'default: a same-repository PR gets its pre-check read' "$(viewed 1)" 1
is 'default: no pr view call is made for a fork PR'        "$(viewed 2)" 0
has 'default: the log names the skipped PR by number'       "$OUT" 'owner/repo: not reviewed, fork PR by an author who is not trusted: #2'
lacks 'default: ...and never by title'                      "$OUT" 'secret title'
has 'default: the round prints one warning with the count'  "$OUT" 'WARNING: 1 PR(s) from forks were not reviewed'
is 'default: ...exactly one'                                "$(grep -c '^WARNING: ' <<<"$OUT")" 1
has 'default: the round ends well'                          "$OUT" 'rc=0'
is 'default: the list is one call that asks for the author, the fork flag and the labels' \
   "$(grep -c '^pr list --repo owner/repo --state open --limit 1000 --json number,author,isCrossRepository,labels$' "$T/gh.calls")" 1

OUT="$(run_gate PRREVIEW_GATE_TRUSTED_AUTHORS="bob Mallory")"
is 'a listed author: the fork PR is read'  "$(viewed 2)" 1
lacks 'a listed author: no warning'         "$OUT" 'WARNING: '

OUT="$(run_gate PRREVIEW_GATE_FORK_PRS=1)"
is 'FORK_PRS=1: the fork PR is read'       "$(viewed 2)" 1
lacks 'FORK_PRS=1: no warning'              "$OUT" 'WARNING: '
OUT="$(run_gate PRREVIEW_GATE_FORK_PRS=0)"
is 'FORK_PRS=0 is the default'              "$(viewed 2)" 0

OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2)"
is 'a named fork PR is read'                "$(viewed 2)" 1
has 'a named PR that is a draft says so'    "$OUT" 'PR #2: is a draft, not reviewed until it is ready'
is '...and no other PR is'                  "$(viewed 1)" 0
lacks '...with no warning about the others' "$OUT" 'WARNING: '
has '...and the round exits 75, not 0'      "$OUT" 'rc=75'
has '...and says that the PR was not reviewed' "$OUT" 'owner/repo#2 was not reviewed'
OUT="$(run_gate PRREVIEW_ONCE_PR=OWNER/Repo#2)"
is 'the repository in the name may differ in letter case' "$(viewed 2)" 1
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#9)"
has 'a named PR that is not open is reported'  "$OUT" 'PR #9 is not open'
has '...and the round fails'                    "$OUT" 'rc=1'
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/other#2)"
has 'a named repository off the list is refused' "$OUT" 'is not in PRREVIEW_GATE_REPOS'
has '...with exit code 2'                        "$OUT" 'rc=2'
is '...before any gh call'                        "$(grep -vc '^--version$' "$T/gh.calls")" 0
OUT="$(run_gate PRREVIEW_ONCE_PR='owner/repo#2;ls')"
has 'a named PR in a bad form is refused'        "$OUT" 'rc=2'
OUT="$(run_gate PRREVIEW_GATE_ONCE_WAIT=soon)"
has 'a wait that is not a number is refused'     "$OUT" 'PRREVIEW_GATE_ONCE_WAIT must be a whole number'
has '...with exit code 2'                         "$OUT" 'rc=2'

# The list is the only source of the filter, and an unreadable one fails closed.
printf '1\n' > "$T/list.rc"
OUT="$(run_gate)"
has 'a failed list fails the round'   "$OUT" 'could not list open PRs'
is '...with no pr view call'           "$(grep -c '^pr view' "$T/gh.calls")" 0
set_list 'this is not JSON'
OUT="$(run_gate)"
has 'a list that does not parse fails the round' "$OUT" 'rc=1'
is '...with no pr view call'                      "$(grep -c '^pr view' "$T/gh.calls")" 0

# The review job looks again, with its own read of the PR, before any model call.
HEAD40=1111111111111111111111111111111111111111
set_list '[{"number":3,"author":{"login":"alice"},"isCrossRepository":false,"labels":[]}]'
cat > "$T/view-3.json" <<JSON_EOF
{"number":3,"headRefOid":"$HEAD40","baseRefOid":"$HEAD40","baseRefName":"main","isDraft":false,
 "reviews":[],"comments":[],"title":"t","body":"b","additions":1,"deletions":0,"changedFiles":1,
 "autoMergeRequest":null,"author":{"login":"mallory"},"isCrossRepository":true}
JSON_EOF
OUT="$(run_gate)"
has 'a stale list: the job sees the fork and stops'   "$OUT" 'PR #3: not reviewed, a fork PR whose author is not trusted'
is '...before any model call'                          "$(grep -vc '^--version$' "$T/claude.calls")" 0
is '...before the diff fetch'                          "$(grep -c '^api ' "$T/gh.calls")" 0
is '...and with no post, review or issue'              "$(grep -cE '^(pr comment|pr review|issue )' "$T/gh.calls")" 0
is '...after two read-only reads of the PR, the dispatcher and the job' "$(viewed 3)" 2
has '...and the round ends well'                       "$OUT" 'rc=0'
OUT="$(run_gate PRREVIEW_GATE_TRUSTED_AUTHORS=mallory)"
lacks 'the same PR with its author listed passes the job check' "$OUT" 'not reviewed, a fork PR'
# The line above holds when the job never runs. The job went on if it asked
# for the merge base, which is the first call after the check.
is '...and the job goes on: it asks for the merge base' \
   "$([ "$(grep -c '^api repos/owner/repo/compare/' "$T/gh.calls")" -ge 1 ] && echo yes || echo no)" yes
is '...after two reads of the PR' "$(viewed 3)" 2
rm -f "$T/view-3.json"

# ── auto-merge on a PR that is skipped ────────────────────────────────────
# With PRREVIEW_GATE_DISARM_AUTO_MERGE=1, a skipped PR must not keep an armed
# auto-merge: it merges on anyone's approve. The list holds the field, so the
# disarm is one `pr merge --disable-auto` call and nothing else. Only the
# skipped PR gets it.
ARMED='{"enabledAt":"2026-01-01T00:00:00Z","enabledBy":{"login":"owner"}}'
set_list "[{\"number\":1,\"title\":\"A secret title\",\"author\":{\"login\":\"alice\"},\"isCrossRepository\":false,\"labels\":[],\"autoMergeRequest\":null},
           {\"number\":2,\"title\":\"Another secret title\",\"author\":{\"login\":\"mallory\"},\"isCrossRepository\":true,\"labels\":[],\"autoMergeRequest\":$ARMED}]"
merges() { grep -c '^pr merge ' "$T/gh.calls" | tr -d ' '; }
OUT="$(run_gate PRREVIEW_GATE_DISARM_AUTO_MERGE=1)"
is 'disarm on: a skipped fork PR with auto-merge armed gets the disarm call' \
   "$(grep -c '^pr merge 2 --repo owner/repo --disable-auto$' "$T/gh.calls")" 1
is '...and that is the only disarm call'                  "$(merges)" 1
is '...with no pr view for it'                             "$(viewed 2)" 0
is '...no comment, no review and no issue'                 "$(grep -cE '^(pr comment|pr review|issue )' "$T/gh.calls")" 0
is '...no diff fetch'                                      "$(grep -c '^api ' "$T/gh.calls")" 0
is '...and the list call asks for autoMergeRequest too'    "$(grep -c '^pr list --repo owner/repo --state open --limit 1000 --json number,author,isCrossRepository,labels,autoMergeRequest$' "$T/gh.calls")" 1
has '...the log names the PR by number'                    "$OUT" 'PR #2: auto-merge was armed on a head this gate has not reviewed yet'
lacks '...and never by title'                              "$OUT" 'secret title'
has '...and the round ends well'                           "$OUT" 'rc=0'
OUT="$(run_gate PRREVIEW_GATE_DISARM_AUTO_MERGE=0)"
is 'disarm off: the same PR gets no call'                  "$(merges)" 0
is '...and the list call stays as before'                  "$(grep -c '^pr list --repo owner/repo --state open --limit 1000 --json number,author,isCrossRepository,labels$' "$T/gh.calls")" 1
OUT="$(run_gate)"
is 'disarm unset: the same PR gets no call'                "$(merges)" 0
OUT="$(run_gate PRREVIEW_GATE_DISARM_AUTO_MERGE=1 PRREVIEW_GATE_TRUSTED_AUTHORS=mallory)"
is 'disarm on: a PR the reviewer reads is left to the job'  "$(merges)" 0
OUT="$(run_gate PRREVIEW_GATE_DISARM_AUTO_MERGE=1 PRREVIEW_ONCE_PR=owner/repo#1)"
is 'disarm on: a round for a named PR disarms no other PR'  "$(merges)" 0
set_list '[{"number":2,"author":{"login":"mallory"},"isCrossRepository":true,"labels":[],"autoMergeRequest":null},
           {"number":4,"author":{"login":"mallory"},"isCrossRepository":true,"labels":[]}]'
OUT="$(run_gate PRREVIEW_GATE_DISARM_AUTO_MERGE=1)"
is 'disarm on: a skipped PR without armed auto-merge gets no call' "$(merges)" 0
is '...whether the field is null or missing'                        "$(viewed 4)" 0
set_list "[{\"number\":2,\"author\":{\"login\":\"mallory\"},\"isCrossRepository\":true,\"labels\":[],\"autoMergeRequest\":$ARMED}]"
printf '1\n' > "$T/merge.rc"
OUT="$(run_gate PRREVIEW_GATE_DISARM_AUTO_MERGE=1)"
has 'a disarm that fails is reported'                      "$OUT" 'disarming it FAILED'
has '...the PR is skipped fail closed'                      "$OUT" 'PR #2: auto-merge could not be disarmed'
has '...and the round fails'                                "$OUT" 'rc=1'
rm -f "$T/merge.rc"
# The review job reads the PR again. A PR that turned into a fork PR after the
# list gets the same disarm from the job, before it returns.
set_list '[{"number":3,"author":{"login":"alice"},"isCrossRepository":false,"labels":[]}]'
cat > "$T/view-3.json" <<JSON_EOF
{"number":3,"headRefOid":"$HEAD40","baseRefOid":"$HEAD40","baseRefName":"main","isDraft":false,
 "reviews":[],"comments":[],"title":"t","body":"b","additions":1,"deletions":0,"changedFiles":1,
 "autoMergeRequest":$ARMED,"author":{"login":"mallory"},"isCrossRepository":true}
JSON_EOF
OUT="$(run_gate PRREVIEW_GATE_DISARM_AUTO_MERGE=1)"
has 'a stale list, disarm on: the job stops the fork PR'    "$OUT" 'PR #3: not reviewed, a fork PR whose author is not trusted'
is '...and disarms its auto-merge once'                      "$(grep -c '^pr merge 3 --repo owner/repo --disable-auto$' "$T/gh.calls")" 1
is '...with no model call'                                   "$(grep -vc '^--version$' "$T/claude.calls")" 0
is '...and no diff fetch'                                    "$(grep -c '^api ' "$T/gh.calls")" 0
OUT="$(run_gate)"
is 'a stale list, disarm off: the job disarms nothing'       "$(merges)" 0
rm -f "$T/view-3.json"

# ── a named round ends well only when the PR has a verdict on its head ──────
# A draft, a skip by any check and a refusal leave the PR without a verdict,
# so the round exits 75 and says so. A head that already has a verdict from
# the reviewer counts as reviewed.
set_list '[{"number":2,"author":{"login":"mallory"},"isCrossRepository":true,"labels":[]}]'
INFO2="{\"number\":2,\"headRefOid\":\"$HEAD40\",\"baseRefOid\":\"$HEAD40\",\"baseRefName\":\"main\",\"title\":\"t\",\"body\":\"b\"}"
KEY2="$( . lib/tools.sh; . lib/merge.sh; . lib/prompt.sh; tools_resolve; prompt_review_key "$INFO2" main )"
is 'the test PR has a review key' "${#KEY2}" 53
view2() { # COMMENTS_JSON DRAFT: the answer of `pr view 2`
  jq -n --argjson c "$1" --argjson d "$2" --arg h "$HEAD40" '{number:2,headRefOid:$h,baseRefOid:$h,baseRefName:"main",
    isDraft:$d,reviews:[],comments:$c,title:"t",body:"b",additions:1,deletions:0,changedFiles:1,autoMergeRequest:null,
    author:{login:"mallory"},isCrossRepository:true}'
}
GATE_COMMENT="[{\"author\":{\"login\":\"owner\"},\"body\":\"<!-- pr-reviewer $KEY2 -->\\n\\n> **Automated review: ✅ Approved**\",\"createdAt\":\"2026-01-01T00:00:00Z\"}]"

# The dispatcher reads a draft.
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2)"
has 'a draft: the round exits 75'      "$OUT" 'rc=75'
# The dispatcher reads a ready PR, the job reads a draft.
view2 '[]' false > "$T/view-2.1.json"; view2 '[]' true > "$T/view-2.2.json"
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2)"
has 'a draft that only the job sees: the job says so'  "$OUT" '[owner__repo#2] PR #2: is a draft, not reviewed until it is ready'
has '...and the round exits 75'                         "$OUT" 'rc=75'
has '...and says that the PR was not reviewed'          "$OUT" 'owner/repo#2 was not reviewed'
rm -f "$T/view-2.1.json" "$T/view-2.2.json"
# A check of the job skips it: the title check posts a reminder and stops.
view2 '[]' false > "$T/view-2.json"
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2 PRREVIEW_GATE_TITLE_CHECK=1)"
has 'a skip by a check of the job: the job says so'     "$OUT" 'non-conventional title — reminder posted, not reviewed'
has '...and the round exits 75'                          "$OUT" 'rc=75'
set_list '[{"number":2,"author":{"login":"alice"},"isCrossRepository":false,"labels":[]}]'
OUT="$(run_gate PRREVIEW_GATE_TITLE_CHECK=1)"
has 'the same skip in a round with no named PR exits 0'  "$OUT" 'rc=0'
set_list '[{"number":2,"author":{"login":"mallory"},"isCrossRepository":true,"labels":[]}]'
# The reviewer's verdict is already on the head: the dispatcher sees it.
view2 "$GATE_COMMENT" false > "$T/view-2.json"
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2)"
has 'a head with a verdict: the dispatcher says so'      "$OUT" 'this head was already handled'
has '...and the round exits 0'                           "$OUT" 'rc=0'
lacks '...with no word about a missing review'           "$OUT" 'was not reviewed'
rm -f "$T/view-2.json"
# The dispatcher sees none, the job sees it.
view2 '[]' false > "$T/view-2.1.json"; view2 "$GATE_COMMENT" false > "$T/view-2.2.json"
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2)"
has 'a head with a verdict that only the job sees: the job says so' "$OUT" '[owner__repo#2] PR #2: this head was already handled'
has '...and the round exits 0'                           "$OUT" 'rc=0'
rm -f "$T/view-2.1.json" "$T/view-2.2.json"
# A verdict the job posts counts too. This pins the wiring: a full review
# needs a model.
is 'the job records its verdict comment for the named round' \
   "$(grep -A1 '^    RO_POSTED=1$' pr-autoreview.sh | tail -1)" '    note_answered'

# ── the post-merge scan ───────────────────────────────────────────────────
# The scan reads the merged PRs of the last 48 hours. It comments on a merged
# PR, fork or not, only when the reviewer's own last comment there is a blocking
# verdict. A comment by anyone else does not count.
# Trade-off: the merged list has no trust filter. The reviewer made the
# earlier verdict, so the alert goes to the same thread.
NOW="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
VERDICT='<!-- pr-reviewer 1111111111111111111111111111111111111111-abcdef012345 -->

> **Automated review: ❌ Changes requested**'
set_list '[]'
# #20: a merged fork PR, the reviewer's last verdict is a blocker.
# #21: a merged fork PR, only a stranger wrote a verdict-like comment.
# #22: a merged PR from the repository itself, the same blocker as #20.
jq -n --arg v "$VERDICT" '{number:20,isCrossRepository:true,author:{login:"mallory"},reviews:[],
  comments:[{author:{login:"owner"},body:$v,createdAt:"2026-01-01T00:00:00Z"}]}' > "$T/view-20.json"
jq -n --arg v "$VERDICT" '{number:21,isCrossRepository:true,author:{login:"mallory"},reviews:[],
  comments:[{author:{login:"mallory"},body:$v,createdAt:"2026-01-01T00:00:00Z"}]}' > "$T/view-21.json"
jq -n --arg v "$VERDICT" '{number:22,isCrossRepository:false,author:{login:"alice"},reviews:[],
  comments:[{author:{login:"owner"},body:$v,createdAt:"2026-01-01T00:00:00Z"}]}' > "$T/view-22.json"
merged() { # NUMBER...: the merged list holds these PRs, merged just now
  local n out="[]"
  for n in "$@"; do out="$(jq -c --argjson n "$n" --arg t "$NOW" '. + [{number:$n,mergedAt:$t}]' <<<"$out")"; done
  printf '%s\n' "$out" > "$T/merged.json"
}
posted() { grep -c "^pr comment $1 " "$T/gh.calls" | tr -d ' '; }
filed()  { grep -c '^issue create ' "$T/gh.calls" | tr -d ' '; }

merged 21
OUT="$(run_gate PRREVIEW_GATE_TICKETS=1)"
is 'a merged fork PR with no verdict by the reviewer gets no comment' "$(posted 21)" 0
is '...and no follow-up ticket'                                        "$(filed)" 0
has '...and the round ends well'                                       "$OUT" 'rc=0'

merged 20 22
OUT="$(run_gate PRREVIEW_GATE_TICKETS=1)"
is 'a merged fork PR with a blocking verdict by the reviewer gets the comment' "$(posted 20)" 1
is '...as a merged PR from the repository itself does'                          "$(posted 22)" 1
is '...and each of them gets a follow-up ticket'                                "$(filed)" 2
has '...and the log says so'                                                    "$OUT" 'PR #20: merged with an unresolved blocking verdict'

merged 20
OUT="$(run_gate PRREVIEW_GATE_TICKETS=1 PRREVIEW_ONCE_PR=owner/repo#2)"
is 'a round for a named PR does not list merged PRs' "$(grep -c -e '--state merged' "$T/gh.calls")" 0
is '...does not read one'                             "$(viewed 20)" 0
is '...and posts no comment'                          "$(posted 20)" 0
is '...and files no ticket'                           "$(filed)" 0
rm -f "$T/merged.json" "$T/view-20.json" "$T/view-21.json" "$T/view-22.json"

# ── the lock: once --pr waits, and fails when it cannot get it ─────────────
# hold_lock starts a background process that takes the lock of the gate. The
# process writes $T/held after flock succeeds, and hold_lock returns when it
# sees that file, so the gate cannot take the lock first. A fixed sleep
# would race the holder on a slow machine.
hold_lock() {
  local i=0
  rm -f "$T/held"
  ( exec 8>"$T/lock"; flock 8 && : > "$T/held"; exec sleep 20 ) &
  HOLDER=$!
  while [ ! -e "$T/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$T/held" ] || bad 'a background process takes the lock' 'a marker file within 10 seconds' 'no marker file'
}
release_lock() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }
set_list '[{"number":2,"author":{"login":"mallory"},"isCrossRepository":true,"labels":[]}]'
hold_lock
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2 PRREVIEW_GATE_ONCE_WAIT=1)"
has 'a named PR with the lock held fails'   "$OUT" 'rc=75'
has '...and says why'                       "$OUT" 'still holds'
has '...and names the PR that was not reviewed' "$OUT" 'owner/repo#2 was not reviewed'
# 0 means do not wait. The default wait is 300 seconds, so a run that waits
# at all takes far longer than the limit below.
START=$SECONDS
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2 PRREVIEW_GATE_ONCE_WAIT=0)"
has 'a wait of 0 with the lock held fails at once'  "$OUT" 'rc=75'
has '...and says why'                                 "$OUT" 'owner/repo#2 was not reviewed'
is '...without a wait'                                "$([ $((SECONDS - START)) -lt 10 ] && echo fast || echo slow)" fast
OUT="$(run_gate)"
has 'a round without a named PR still exits 0 when the lock is held' "$OUT" 'rc=0'
has '...as before'                          "$OUT" 'holds'
release_lock

# ── prreview once --pr ────────────────────────────────────────────────────
mkdir -p "$H/.config/pr-reviewer"
printf 'PRREVIEW_GATE_REPOS=owner/repo\n' > "$H/.config/pr-reviewer/config"
chmod 600 "$H/.config/pr-reviewer/config"
once() { # ARGS...: prreview once ARGS; prints the output and the exit code
  : > "$T/gh.calls"; : > "$T/claude.calls"
  env -i HOME="$H" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" CLAUDE_BIN="$T/bin/claude" PRREVIEW_PLATFORM=unsupported \
    PRREVIEW_OWNER_LOGIN=owner PRREVIEW_SENSITIVE_PATTERNS_FILE="$T/patterns" \
    PRREVIEW_GATE_WORKROOT="$T/work" PRREVIEW_GATE_LOCK="$T/lock" "${ONCE_ENV[@]}" bash "$ROOT/prreview" once "$@" 2>&1
  echo "rc=$?"
}
ONCE_ENV=(PRREVIEW_X=1)
OUT="$(once --pr owner/repo#2)"
is 'prreview once --pr: the named fork PR is read' "$(viewed 2)" 1
has '...and a draft is not reported as reviewed'     "$OUT" 'rc=75'
view2 "$GATE_COMMENT" false > "$T/view-2.json"
OUT="$(once --pr owner/repo#2)"
has '...and a PR with a verdict on its head ends well' "$OUT" 'rc=0'
rm -f "$T/view-2.json"
for r in 'owner/repo' '#12' 'owner/repo#0' 'owner/repo#12x' 'https://github.com/owner/repo/pull/2' 'owner/repo#2;ls' ''; do
  OUT="$(once --pr "$r")"
  has "once --pr rejects $(printf '%q' "$r")" "$OUT" 'owner/repo#N'
  is  "...with a non-zero exit code"           "$(grep -c '^rc=0$' <<<"$OUT")" 0
  is  "...and without starting the reviewer"    "$(wc -c < "$T/claude.calls" | tr -d ' ')" 0
done
OUT="$(once --pr)"
has 'once --pr without a value is rejected'      "$OUT" 'owner/repo#N'
OUT="$(once --pr owner/other#4)"
has 'once --pr for a repository off the list is rejected' "$OUT" 'is not one of the repositories'
is '...without starting the reviewer'             "$(wc -c < "$T/claude.calls" | tr -d ' ')" 0
OUT="$(once whatever)"
has 'once with any other argument is rejected'   "$OUT" 'usage: prreview once'
is '...without starting the reviewer'             "$(wc -c < "$T/claude.calls" | tr -d ' ')" 0
hold_lock
ONCE_ENV=(PRREVIEW_GATE_ONCE_WAIT=1)
OUT="$(once --pr owner/repo#2)"
has 'once --pr with the lock held exits non-zero' "$OUT" 'rc=75'
has '...and says why'                             "$OUT" 'still holds'
release_lock

# ── a loop round is never a named round ────────────────────────────────────
# Only `prreview once --pr` names a PR. A value left in the environment of the
# loop, or of `prreview run`, must not name one in every round. A probe stands
# in for pr-autoreview.sh and for review-loop.sh and writes what it sees.
LD="$T/loop-dir"; mkdir -p "$LD/lib" "$LD/home"
cp "$ROOT/review-loop.sh" "$ROOT/prreview" "$LD/"
cp "$ROOT"/lib/*.sh "$LD/lib/"
cat > "$LD/pr-autoreview.sh" <<'PROBE_EOF'
#!/usr/bin/env bash
REPOS="owner/repo"
echo "once_pr=[${PRREVIEW_ONCE_PR-unset}]" >> "$LOOP_PROBE"
PROBE_EOF
set_list '[{"number":1,"author":{"login":"alice"},"isCrossRepository":false,"labels":[]}]'
LOOP_PROBE="$T/loop.probe"; : > "$LOOP_PROBE"
env -i HOME="$LD/home" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" CLAUDE_BIN="$T/bin/claude" \
  PRREVIEW_ONCE_PR=owner/repo#2 LOOP_PROBE="$LOOP_PROBE" PRREVIEW_LOOP_INTERVAL=1 \
  bash "$LD/review-loop.sh" "$LD/logs" >/dev/null 2>&1 &
LOOP_PID=$!
for _ in $(seq 1 100); do [ -s "$LOOP_PROBE" ] && break; sleep 0.1; done
kill "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null
has 'the loop ran a round' "$(cat "$LOOP_PROBE")" 'once_pr='
is '...and the round names no PR, whatever the loop inherited' "$(head -1 "$LOOP_PROBE")" 'once_pr=[]'
LD2="$T/run-dir"; mkdir -p "$LD2/lib" "$LD2/home"
cp "$ROOT/prreview" "$ROOT/pr-autoreview.sh" "$LD2/"
cp "$ROOT"/lib/*.sh "$LD2/lib/"
printf '#!/usr/bin/env bash\necho "once_pr=[${PRREVIEW_ONCE_PR-unset}]" >> "$LOOP_PROBE"\n' > "$LD2/review-loop.sh"
: > "$LOOP_PROBE"
env -i HOME="$LD2/home" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" PRREVIEW_PLATFORM=unsupported \
  PRREVIEW_ONCE_PR=owner/repo#2 LOOP_PROBE="$LOOP_PROBE" bash "$LD2/prreview" run >/dev/null 2>&1
is 'prreview run starts the loop with no PR named' "$(head -1 "$LOOP_PROBE")" 'once_pr=[]'

# ── prreview status ───────────────────────────────────────────────────────
mkdir -p "$H/.cache/pr-reviewer/gate-logs"
status() { env -i HOME="$H" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" PRREVIEW_PLATFORM=unsupported "$@" bash "$ROOT/prreview" status 2>&1; }
has 'status shows no skipped PRs before any round' "$(status)" 'Skipped PRs:  0'
printf 'WARNING: 5 PR(s) from forks were not reviewed. old\n' > "$H/.cache/pr-reviewer/gate-logs/round-a-1.log"
touch -t 202601010000 "$H/.cache/pr-reviewer/gate-logs/round-a-1.log"
printf '%s\n' "$(trust_warning 3)" > "$H/.cache/pr-reviewer/gate-logs/round-b-2.log"
OUT="$(status)"
has 'status shows the count of the newest round log' "$OUT" 'Skipped PRs:  3'
has '...and how to review one'                       "$OUT" 'prreview once --pr owner/repo#N'
printf 'PRREVIEW_GATE_REPOS=owner/repo\nPRREVIEW_GATE_FORK_PRS=1\n' > "$H/.config/pr-reviewer/config"
has 'status says when fork PRs are reviewed' "$(status)" 'Skipped PRs:  none, PRREVIEW_GATE_FORK_PRS=1 reviews fork PRs'
# The round lets an exported value win over the settings file, so status does too.
has 'status: an exported 0 wins over a 1 in the file' "$(status PRREVIEW_GATE_FORK_PRS=0)" 'Skipped PRs:  3'
printf 'PRREVIEW_GATE_REPOS=owner/repo\n' > "$H/.config/pr-reviewer/config"
has 'status: an exported 1 counts when the file has none' "$(status PRREVIEW_GATE_FORK_PRS=1)" 'Skipped PRs:  none, PRREVIEW_GATE_FORK_PRS=1 reviews fork PRs'

# ── prreview set ──────────────────────────────────────────────────────────
rm -f "$H/.config/pr-reviewer/config"
setting() { env -i HOME="$H" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" PRREVIEW_PLATFORM=unsupported bash "$ROOT/prreview" "$@" 2>&1; }
has 'the list of trusted authors can be set'  "$(setting set PRREVIEW_GATE_REPOS owner/repo; setting set PRREVIEW_GATE_TRUSTED_AUTHORS 'alice bob')" 'PRREVIEW_GATE_TRUSTED_AUTHORS=alice bob'
is  '...and is read back'                      "$(setting get PRREVIEW_GATE_TRUSTED_AUTHORS)" 'alice bob'
has 'PRREVIEW_GATE_FORK_PRS takes 1'           "$(setting set PRREVIEW_GATE_FORK_PRS 1)" 'PRREVIEW_GATE_FORK_PRS=1'
has 'PRREVIEW_GATE_FORK_PRS refuses 2'         "$(setting set PRREVIEW_GATE_FORK_PRS 2)" 'takes 0 (off) or 1 (on)'
has 'PRREVIEW_GATE_ONCE_WAIT refuses a word'   "$(setting set PRREVIEW_GATE_ONCE_WAIT soon)" 'takes a whole number'
has 'PRREVIEW_GATE_ONCE_WAIT refuses 5m'        "$(setting set PRREVIEW_GATE_ONCE_WAIT 5m)" 'takes a whole number'
has 'PRREVIEW_GATE_ONCE_WAIT refuses a negative number' "$(setting set PRREVIEW_GATE_ONCE_WAIT -1)" 'takes a whole number'
has 'PRREVIEW_GATE_ONCE_WAIT shows its default' "$(setting get PRREVIEW_GATE_ONCE_WAIT)" '300'
has 'PRREVIEW_GATE_ONCE_WAIT takes 0 (do not wait)' "$(setting set PRREVIEW_GATE_ONCE_WAIT 0)" 'PRREVIEW_GATE_ONCE_WAIT=0'

if [ "$FAILED" -eq 0 ]; then echo "PASS: trust"; else echo "FAIL: trust"; exit 1; fi
