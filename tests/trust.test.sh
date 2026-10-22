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
is 'text that is not JSON is not trusted'               "$(trusted 'not json' 'mallory' 7)" not-trusted
is 'an empty answer is not trusted'                     "$(trusted '' '' '')" not-trusted

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
printf 'x\n%s\n[owner__repo#1] WARNING: 9 PR(s) from forks were not reviewed\n' "$W" > "$T/round.log"
is 'the count is read from the last warning at the start of a line' "$(trust_warning_count "$T/round.log" 2>/dev/null)" 3
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
# draft when there is no file), list.rc is the exit code of the list, and
# merged.json answers the list of merged PRs (empty when there is no file).
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
    if [ -f "$T/view-\$3.json" ]; then emit "\$(cat "$T/view-\$3.json")"; else emit '{"isDraft":true}'; fi ;;
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
rm -f "$T/view-3.json"

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
set_list '[{"number":2,"author":{"login":"mallory"},"isCrossRepository":true,"labels":[]}]'
( exec 8>"$T/lock"; flock 8; exec sleep 20 ) &
HOLDER=$!
sleep 0.5
OUT="$(run_gate PRREVIEW_ONCE_PR=owner/repo#2 PRREVIEW_GATE_ONCE_WAIT=1)"
has 'a named PR with the lock held fails'   "$OUT" 'rc=75'
has '...and says why'                       "$OUT" 'still holds'
has '...and names the PR that was not reviewed' "$OUT" 'owner/repo#2 was not reviewed'
OUT="$(run_gate)"
has 'a round without a named PR still exits 0 when the lock is held' "$OUT" 'rc=0'
has '...as before'                          "$OUT" 'holds'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

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
has '...and the round ends well'                    "$OUT" 'rc=0'
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
( exec 8>"$T/lock"; flock 8; exec sleep 20 ) &
HOLDER=$!
sleep 0.5
ONCE_ENV=(PRREVIEW_GATE_ONCE_WAIT=1)
OUT="$(once --pr owner/repo#2)"
has 'once --pr with the lock held exits non-zero' "$OUT" 'rc=75'
has '...and says why'                             "$OUT" 'still holds'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ── prreview status ───────────────────────────────────────────────────────
mkdir -p "$H/.cache/pr-reviewer/gate-logs"
status() { env -i HOME="$H" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" PRREVIEW_PLATFORM=unsupported bash "$ROOT/prreview" status 2>&1; }
has 'status shows no skipped PRs before any round' "$(status)" 'Skipped PRs:  0'
printf 'WARNING: 5 PR(s) from forks were not reviewed. old\n' > "$H/.cache/pr-reviewer/gate-logs/round-a-1.log"
touch -t 202601010000 "$H/.cache/pr-reviewer/gate-logs/round-a-1.log"
printf '%s\n' "$(trust_warning 3)" > "$H/.cache/pr-reviewer/gate-logs/round-b-2.log"
OUT="$(status)"
has 'status shows the count of the newest round log' "$OUT" 'Skipped PRs:  3'
has '...and how to review one'                       "$OUT" 'prreview once --pr owner/repo#N'
printf 'PRREVIEW_GATE_REPOS=owner/repo\nPRREVIEW_GATE_FORK_PRS=1\n' > "$H/.config/pr-reviewer/config"
has 'status says when fork PRs are reviewed' "$(status)" 'Skipped PRs:  none, PRREVIEW_GATE_FORK_PRS=1 reviews fork PRs'

# ── prreview set ──────────────────────────────────────────────────────────
rm -f "$H/.config/pr-reviewer/config"
setting() { env -i HOME="$H" PATH="$T/bin:$PATH" GH_BIN="$T/bin/gh" PRREVIEW_PLATFORM=unsupported bash "$ROOT/prreview" "$@" 2>&1; }
has 'the list of trusted authors can be set'  "$(setting set PRREVIEW_GATE_REPOS owner/repo; setting set PRREVIEW_GATE_TRUSTED_AUTHORS 'alice bob')" 'PRREVIEW_GATE_TRUSTED_AUTHORS=alice bob'
is  '...and is read back'                      "$(setting get PRREVIEW_GATE_TRUSTED_AUTHORS)" 'alice bob'
has 'PRREVIEW_GATE_FORK_PRS takes 1'           "$(setting set PRREVIEW_GATE_FORK_PRS 1)" 'PRREVIEW_GATE_FORK_PRS=1'
has 'PRREVIEW_GATE_FORK_PRS refuses 2'         "$(setting set PRREVIEW_GATE_FORK_PRS 2)" 'takes 0 (off) or 1 (on)'
has 'PRREVIEW_GATE_ONCE_WAIT refuses a word'   "$(setting set PRREVIEW_GATE_ONCE_WAIT soon)" 'takes a whole number'
has 'PRREVIEW_GATE_ONCE_WAIT shows its default' "$(setting get PRREVIEW_GATE_ONCE_WAIT)" '300'

if [ "$FAILED" -eq 0 ]; then echo "PASS: trust"; else echo "FAIL: trust"; exit 1; fi
