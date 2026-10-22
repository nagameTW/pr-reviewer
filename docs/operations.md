# Operating the reviewer

This page holds the details behind the [README](../README.md): who gets reviewed, what one round does, what happens when something fails, and where the files live.

## Whose PRs it reviews

The reviewer reads a PR in three cases:

- The PR comes from a branch of the repository itself, not from a fork.
- The author's login is in `PRREVIEW_GATE_TRUSTED_AUTHORS`.
- You named the PR with `prreview once --pr owner/repo#N`.

It skips every other PR. In practice, a skipped PR comes from a fork, and its
author is not on the list. Anyone can open a fork PR, and each push to it would
start a new model call on your account.

The reviewer posts nothing on a skipped PR. One exception exists. With
`PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, the reviewer turns off an auto-merge that
is armed on a skipped PR. That is one `gh pr merge --disable-auto` call, and
the skipped PR gets nothing else. Only a user with write access to the
repository can arm auto-merge. The loop that starts the rounds
applies the same rule to its check, with the same two settings. A skipped PR
then does not start a round each minute, and the loop keeps its idle schedule.
The exception is `PRREVIEW_GATE_DISARM_AUTO_MERGE=1` with auto-merge armed on
the PR: the loop counts that PR as work, draft or not, so the disarm runs
within one interval. The loop does not count any other draft PR, because the
round skips it.
The scan of merged PRs does not look at the author. The round log names a
skipped PR by number and never by title. A round that skips PRs prints one `WARNING:` line with the
count, and `prreview status` shows the count for the last round.

To review one outside PR, name it:

```bash
./prreview once --pr owner/repo#12
```

The command reviews the current head of that PR and no other PR. When the
author pushes again, the new head is skipped until you run the command again.
If a round is running, the command waits for it up to `PRREVIEW_GATE_ONCE_WAIT`
seconds (300 by default). A value of `0` means do not wait. If the command
cannot get the lock in that time, it prints the reason and exits with code 75,
so you know the PR was not reviewed. It rejects
anything that is not `owner/repo#N` for a repository you review.

The exit code says if the reviewer has posted a verdict on the PR:

- `0`: the reviewer has a verdict comment on the current head, from this run
  or an earlier one. A verdict is an approve or a request for changes.
- `75`: the reviewer has no verdict on the current head, and nothing failed.
  The PR can be a draft, or a check can have skipped it. The command prints the
  reason.
- `1`: the PR is not open, or the reviewer could not read it.

A notice is not a verdict. The title format reminder and the sensitive-data
notice are notices. A check that posts a notice and stops gives `75` on the
first run, and `75` on every later run, until the title or description is
fixed and the reviewer posts a verdict. The loop still posts a notice once per
head.

To review the PRs of one fork author each time, put the login in
`PRREVIEW_GATE_TRUSTED_AUTHORS`:

```bash
./prreview set PRREVIEW_GATE_TRUSTED_AUTHORS "alice bob"
```

Write each login as `gh pr list --json author` prints it. Separate logins with
spaces or commas. Letter case does not matter. To review every PR, as the
reviewer did before this rule, set `PRREVIEW_GATE_FORK_PRS=1`.

Four limits apply:

- Do not add an account only because it contributed once. List only accounts
  that you would let push to the repository.
- The rule treats everyone who can push to the repository as trusted. If a
  workflow of yours builds branches from outside input, for example with
  `pull_request_target`, a branch of the repository can carry outside text.
- The list is a setting of the machine that runs the reviewer. When several
  maintainers each run a reviewer, each one sets the list.
- The reviewer decides on the list it reads at the start of the repository's
  round. If a PR turns into a fork PR after that read, the reviewer reads the
  PR once with `gh pr view`. The review job then checks the rule again and
  stops. That PR gets no model call and no post. With
  `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, the job also turns off its auto-merge.


## Terms

This page and the README use these words in one sense each.

| Term | Meaning |
| --- | --- |
| **Gate** | The name the code and its settings use for the reviewer: `pr-autoreview.sh`, the `PRREVIEW_GATE_*` settings, `gate.log`. It only comments; it does not block or merge anything, which is why its log calls the comment a review-only verdict. |
| **Head** | The latest commit on a PR's branch. The reviewer reviews heads, not branches. |
| **Trusted author** | The author of a PR that comes from a branch of the repository itself, or a login in `PRREVIEW_GATE_TRUSTED_AUTHORS`. A PR that `prreview once --pr` names is reviewed as if its author were trusted. |
| **Round** | One run of `pr-autoreview.sh`. It goes over every listed repo and reviews each PR from a trusted author whose head has no comment yet. The loop checks once a minute for open PRs that the reviewer would read (see [Whose PRs it reviews](#whose-prs-it-reviews)) and starts a round when it finds any. A fork PR that the reviewer skips does not count, unless `PRREVIEW_GATE_DISARM_AUTO_MERGE=1` and auto-merge is armed on it. A draft PR does not count, with the same exception. With none to review, the loop starts a round only on every 15th check. The loop's log counts checks, so `[round 12]` there is the 12th check, whether or not a round ran. For a single PR, "round 2" means the second verdict comment on it: a push, an edited title, description or base branch, or (for a stacked PR) a push to its parent branch leads to the next one. An edit that leaves the head unchanged waits for the cooldown first (`PRREVIEW_GATE_PR_COOLDOWN_MIN`). So can a push to the parent branch of a stacked PR. |
| **Slice** | Part of a large diff, reviewed by its own model call (`PRREVIEW_GATE_CHUNK_*`). |
| **Verdict** | The first line of the comment: ✅ Approved or ❌ Changes requested. It is text in a comment, not a GitHub review state. |
| **Blocking finding** | A CRITICAL or HIGH finding that counts toward ❌ Changes requested. MEDIUM and LOW are listed without changing the verdict. |
| **Refutation** | A second model call on one blocking finding that tries to prove it wrong. A refuted finding is dropped. |
| **Hold** | A wait before the reviewer tries the same head again after a failed attempt (see [When something fails](#when-something-fails)). |
| **Owner login** | The account whose comments the reviewer treats as its own earlier verdicts (`PRREVIEW_OWNER_LOGIN`, or the App). |

Settings named `PRREVIEW_GATE_*` are read by `pr-autoreview.sh`, and `PRREVIEW_LOOP_*`
by `review-loop.sh`, which starts the rounds.


## How one round works

1. **Pick.** For each repo, list the open PRs with their authors in one call.
   Keep the PRs from a trusted author that are not drafts and whose current
   head has no comment from this reviewer yet. The job checks the author
   again, with its own read of the PR, before any model call. The comment
   carries a hidden marker with the head SHA and a hash of the title,
   description and base branch (for a stacked PR, also the base commit), and
   only comments by the reviewer's own account count. A PR on hold after a
   failure waits out its hold (see [When something fails](#when-something-fails)).
2. **Scan.** Check the PR's title and description against your
   sensitive-patterns file. A hit stops the review of that PR. The title and
   body of the issue the PR links get the same check when the round reads
   them, before any model call.
3. **Build.** Update the local clone of the repo, add a per-PR worktree, check
   out the merge base of the PR in it, and apply the PR's diff on top. The
   author's branch is never checked out. Then, for every PR, the convention
   files are copied from the newest commit of the default branch, matched
   without regard to file name case. A file the tree has and the default
   branch lacks is removed. A file only the default branch has is added. The
   copy comes after the diff, so a convention file that is newer on the default
   branch cannot make the diff fail to apply. If a step of the copy fails, the
   round skips that PR and tries again next round.
   The diff is fetched once, for the exact head commit the verdict will name,
   and the list of changed files is read from that same diff. A push that
   lands during the round cannot swap in another head. If the merge base
   cannot be found, if the diff cannot be fetched, or if it holds a different
   number of files than GitHub reports for the PR, the round skips that PR and
   tries again next round.
   A symlink to a regular file inside the clone, such as
   `AGENTS.md -> CLAUDE.md`, is fine. Any other symlink stops the review: one
   that points outside the clone, into `.git` or nowhere; one to a folder,
   since a path through a folder link can climb out with `..`; and one from a
   convention file (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`,
   anything under `.claude/`, a README or CONTRIBUTING file,
   `.github/review-checks.md`) to anything but another convention file that git
   tracks, since the PR could edit any other file and so write the rules it is
   judged by. The model's
   read access is limited by path, and a link can lead it past that limit. A
   symlink the PR adds gets a comment asking the author to fix or remove it. One already on the
   base branch stops every PR against that branch with no comment: the round
   log names the link, and the round counts as failed (see
   [When something fails](#when-something-fails)).
4. **Slice.** A diff of more than 300 lines is cut by file into slices of about
   250 lines, at most 8. A PR over 2000 changed lines or 40 files gets a
   "please split" comment instead of a review, unless at least 90% of its
   changed lines are deletions, it touches only lock files, generated code,
   snapshots or migrations, or its description has a paragraph starting with
   `split-exempt:` that says why it cannot be split. Those are reviewed in
   full, with two passes over each slice in the first round.
5. **Review.** Claude Code reads the tree and the diff and answers with JSON:
   a verdict, findings with severity, file, line and fix, and what it could not
   verify. The slices run in parallel.
6. **Verify.** Findings that do not have the expected shape, or cite a file
   that does not exist, are dropped. Each blocking finding then gets its own
   call that tries to refute it, up to `PRREVIEW_GATE_VERIFY_MAX` (6) a round; a
   refuted finding is dropped, and any beyond the cap stand.
7. **Post.** Render one comment, scan it against your patterns, and post it.
   Each round's model usage and cost is printed at the end.

CRITICAL and HIGH findings block; MEDIUM and LOW are listed under the verdict
without blocking. Two kinds of HIGH are listed without blocking:

- On a PR of 300 changed lines or more (`PRREVIEW_GATE_COACH_MAX_LINES`), a HIGH
  about tests, conventions, wording or process, or about a doc or code comment
  that only maintainers read. It is still shown as HIGH, marked not blocking.
  On a smaller PR it blocks like any other HIGH, and the prompt tells the
  model which of the two applies.
- On any PR, a HIGH the model tags as wording, judgment or a half-finished
  fix. It is shown as MEDIUM with its original severity next to it.

"Block" here only decides the verdict: the reviewer itself never stops a
merge.

### Optional: a red team before an approval

The refutation calls in step 6 can only remove findings. The red team is the
one step that looks for a defect the review missed, and it runs only on a
round that is about to post ✅ Approved.

It is off by default because it adds cost and time to every approval. In
Run C, a small clean PR in the test repo, the review cost $0.34 and the
red-team call $0.23. These figures were measured on a test PR in September and
October 2026, before v0.2.0 changed the default models. Current costs can
differ. Each candidate it raises adds one refutation call, so at most three
more. The red-team call runs after the review, and the refutation calls run
together after it, so an approval can take up to twice
`PRREVIEW_GATE_VERIFY_TIMEOUT` (1200 seconds) longer to appear.


## Across rounds

Every push is a new round, and the previous round's blocking findings go back
into the prompt. The prompt asks the model to say which ones are fixed, and to
repeat each one that is not, word for word, with a `Carried over:` prefix. The
aim is that the author sees the same finding, not a rewording of it. The
harness does not check that the model does this.

From round 2 on, a new blocking finding about a file that the changes since
the last reviewed round did not touch and that no earlier round cited is
shown as MEDIUM. It was just as visible in round 1, and the author should
not pay a round for the reviewer missing it. CRITICAL findings are never
lowered.

If a PR is merged while the reviewer's last comment on it is ❌ Changes
requested, ❌ Please split, ⛔ Review withheld or ⛔ Refused, the next round
posts one alert comment on the merged PR. With `PRREVIEW_GATE_TICKETS=1` it also
opens a follow-up issue. The check reads the first 10 merged PRs that
`gh pr list` returns, which sorts them by when they were opened, and alerts on
those merged in the last 48 hours. A PR opened long before it was merged can
fall outside those 10.


## When something fails

The reviewer does not post a verdict it could not reach. What happens instead:

- **Some slices of a large diff fail.** The slices that worked are posted as
  one comment. It always says ❌ Changes requested, whatever they found, and
  lists the files no slice reviewed; push again to review the whole diff.
- **The review fails outright**: every call fails or times out, or the answer
  still cannot be parsed after the repair call. Nothing is posted for that
  head, and the head goes on hold: 5 minutes (`PRREVIEW_GATE_HOLDOFF_FAIL`), or 30 minutes after
  a usage-limit error (`PRREVIEW_GATE_HOLDOFF_QUOTA`). Each repeat of the same
  reason doubles the wait, up to an hour (`PRREVIEW_GATE_HOLDOFF_MAX`). The round
  log says when the next attempt is due. To retry at once, delete the files
  named `<repo>-<PR number>-*` in
  `~/.cache/pr-reviewer/review-holdoff/`. A new push, or an
  edited title, description or base branch, or a push to the parent branch of a
  stacked PR, starts over with no hold. The cooldown for an edited title,
  description or base branch, or a push to the parent branch of a stacked PR
  (`PRREVIEW_GATE_PR_COOLDOWN_MIN`), is a separate wait.
- **Posting the comment fails.** The finished comment is kept, and the head
  goes on the same hold as above (5 minutes, doubling on repeats). The next
  attempt after that posts the kept comment without calling the model again.
- **The comment matches your sensitive-data patterns**, or the scan cannot
  run. A short notice is posted instead, and the full text goes only to the
  round log, in a directory only you can read.
- **Something stops a PR or a whole repo from being reviewed at all**: a repo
  or a PR that cannot be read, a merge base that cannot be found, a diff that
  cannot be fetched whole, a symlink on the base branch, an App token that
  cannot be created, a review job that crashes. The round finishes the other
  PRs and then exits with an error. `review-loop.sh` then opens one issue in
  `PRREVIEW_ALERT_REPO` if you set it; it opens no second one while that issue is
  open, and closing it re-arms the alert. While it stays open and rounds keep
  failing, it gets a "Still failing" comment at most every 6 hours
  (`PRREVIEW_ALERT_REPEAT_HOURS`). Without `PRREVIEW_ALERT_REPO`, the failure is only in
  the log.
- **A round runs longer than `PRREVIEW_LOOP_ROUND_TIMEOUT`** (3900 seconds). The
  loop kills it and counts it as failed. The default leaves room for a first
  round on a diff near the 2000-line ceiling: two passes over eight slices is
  16 calls, which at 8 calls in flight is two waves of
  `PRREVIEW_GATE_REVIEW_TIMEOUT`.


## Where to run it

Run it on a machine only you use. The background service runs as your user,
with your `gh` login, your Claude Code login and, if you set one up, a GitHub
App's private key; anyone who can act as that user can post as you.

The service is started by launchd or systemd, not by your shell, so it does
not see variables your shell profile exports. Log in with `gh auth login` and
`claude auth login`: a `GH_TOKEN` or `ANTHROPIC_API_KEY` that exists only
in your shell never reaches the service, although `prreview once` in that same
terminal does see it. On a machine with no browser, such as a server you
reach over SSH, `claude auth login` prints a link to open on another device.
Claude Code also runs with no settings sources, so nothing in
`~/.claude/settings.json` (model, permissions, hooks, `env`) applies to a
review.

On Linux, a separate account for the reviewer, called `reviewer` below, is a
good way to keep it to itself. Log in to that account directly, for example
over SSH, rather than switching to it with `su` or `sudo -iu`. A switched session has no
`XDG_RUNTIME_DIR`, so `systemctl --user` cannot reach the account's service
manager and `prreview setup` cannot install the service. If switching is the only
way in:

```bash
sudo loginctl enable-linger reviewer      # once, from an admin account
export XDG_RUNTIME_DIR=/run/user/$(id -u) # in the reviewer's session
./prreview setup
```

## Where it keeps its files

| Path | What is there |
| --- | --- |
| `~/.config/pr-reviewer/` | `config`, `sensitive-patterns`, your copy of the checklist in `checks/`, and a GitHub App's key as `app.pem` |
| `~/.cache/pr-reviewer/` | The service's log `gate.log`, round logs in `gate-logs/`, holds in `review-holdoff/`, and the round lock |
| `~/.cache/pr-reviewer/work/` | Review clones and each round's scratch files (`PRREVIEW_GATE_WORKROOT`); under `$XDG_CACHE_HOME` when that is set |
| `~/.local/state/pr-reviewer/` | Which repo the next round starts with; under `$XDG_STATE_HOME` when that is set |
| `~/Library/LaunchAgents/local.pr-reviewer.plist` | The background service on macOS |
| `~/.config/systemd/user/pr-reviewer.service` | The background service on Linux |


## Removing it

`prreview uninstall` removes only the background service. To remove everything:

```bash
cd ~/pr-reviewer
./prreview uninstall
rm -rf ~/.config/pr-reviewer ~/.cache/pr-reviewer ~/.local/state/pr-reviewer
rm -f ~/.local/bin/prreview
cd ~ && rm -rf ~/pr-reviewer
```

The first `rm` also deletes your checklist copy and the App's key; keep
anything you want first. If `XDG_CACHE_HOME` or `XDG_STATE_HOME` is set, or
you set `PRREVIEW_GATE_WORKROOT`, remove those directories too. If you ran
`loginctl enable-linger` only for the reviewer, `sudo loginctl disable-linger
"$USER"` undoes it. A GitHub App stays on GitHub until you delete it on its
settings page. If you added a `PATH` line to `~/.zshrc` for `~/.local/bin`,
remove it by hand when nothing else uses that directory.

