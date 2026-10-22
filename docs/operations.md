# Operating the reviewer

This page holds the details behind the [README](../README.md). It covers who gets reviewed, what one round does, what happens when something fails, and where the files live.

## Whose PRs it reviews

The reviewer reads a PR in three cases:

- The PR comes from a branch of the repository itself, not from a fork.
- The author's login is in `PRREVIEW_GATE_TRUSTED_AUTHORS`.
- You named the PR with `prreview once --pr owner/repo#N`.

It skips every other PR. In practice, a skipped PR comes from a fork, and its
author is not on the list. Anyone can open a fork PR. Each push to it would
start a new model call on your account.

The reviewer posts nothing on a skipped PR. There is one exception. With
`PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, the reviewer turns off an auto-merge that
is armed on a skipped PR. That is one `gh pr merge --disable-auto` call. The
skipped PR gets nothing else. Only a user with write access to the repository
can arm auto-merge.

The loop that starts the rounds applies the same rule to its check, with the
same two settings. So a skipped PR does not start a round each minute. The loop
keeps its idle schedule.

One case differs. `PRREVIEW_GATE_DISARM_AUTO_MERGE=1` is set, and auto-merge is
armed on the PR. Then the loop counts that PR as work, draft or not. The disarm
runs within one interval. The loop does not count any other draft PR, because
the round skips it.

The scan of merged PRs does not look at the author. The round log names a
skipped PR by number and never by title. A round that skips PRs prints one
`WARNING:` line with the count. `prreview status` shows the count for the last
round.

To review one outside PR, name it:

```bash
./prreview once --pr owner/repo#12
```

The command reviews the current head of that PR and no other PR. When the
author pushes again, the reviewer skips the new head until you run the command
again. If a round is running, the command waits for it for up to
`PRREVIEW_GATE_ONCE_WAIT` seconds (300 by default). A value of `0` means do not
wait. If the command cannot get the lock in that time, it prints the reason and
exits with code 75. Then you know the reviewer did not review the PR. The
command rejects anything that is not `owner/repo#N` for a repository you
review.

The exit code says whether the reviewer has posted a verdict on the PR:

- `0`: the reviewer has a verdict comment on the current head, from this run
  or an earlier one. A verdict is an approval or a request for changes.
- `75`: the reviewer has no verdict on the current head, and nothing failed.
  The PR can be a draft, or a check can have skipped it. The command prints the
  reason.
- `1`: the PR is not open, or the reviewer could not read it.

A notice is not a verdict. The title format reminder and the sensitive-data
notice are notices. Suppose a check posts a notice and stops. Then the command
gives `75` on the first run. It gives `75` on every later run, until someone
fixes the title or description and the reviewer posts a verdict. The loop still
posts a notice once for each head.

To review the PRs of one fork author every time, put the login in
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
- The rule treats everyone who can push to the repository as trusted. Suppose a
  workflow of yours builds branches from outside input, for example with
  `pull_request_target`. Then a branch of the repository can carry outside text.
- The list is a setting of the machine that runs the reviewer. When several
  maintainers each run a reviewer, each one sets the list.
- The reviewer decides on the list that it reads at the start of the round of
  the repository. A PR can turn into a fork PR after that read. Then the
  reviewer reads the PR once with `gh pr view`. The review job checks the rule
  again and stops. That PR gets no model call and no post. With
  `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, the job also turns off its auto-merge.


## Terms

This page and the README use these words in one sense each.

| Term | Meaning |
| --- | --- |
| **Gate** | The name that the code and its settings use for the reviewer: `pr-autoreview.sh`, the `PRREVIEW_GATE_*` settings and `gate.log`. It only comments. It does not block or merge anything. So its log calls the comment a review-only verdict. |
| **Head** | The latest commit on the branch of a PR. The reviewer reviews heads, not branches. |
| **Trusted author** | The author of a PR that comes from a branch of the repository itself, or a login in `PRREVIEW_GATE_TRUSTED_AUTHORS`. The reviewer reviews a PR that `prreview once --pr` names as if its author were trusted. |
| **Round** | One run of `pr-autoreview.sh`. It goes over every listed repo. It reviews each PR from a trusted author whose head has no comment yet. The loop checks once a minute for open PRs that the reviewer would read (see [Whose PRs it reviews](#whose-prs-it-reviews)). It starts a round when it finds any. A fork PR that the reviewer skips does not count. The exception is `PRREVIEW_GATE_DISARM_AUTO_MERGE=1` with auto-merge armed on it. A draft PR does not count, with the same exception. With none to review, the loop starts a round on only every 15th check. The log of the loop counts checks. So `[round 12]` there is the 12th check, whether or not a round ran. For a single PR, "round 2" means the second verdict comment on it. The next verdict follows a push, an edited title, description or base branch, or a push to the parent branch of a stacked PR. An edit that leaves the head unchanged waits for the cooldown first (`PRREVIEW_GATE_PR_COOLDOWN_MIN`). A push to the parent branch of a stacked PR waits for it too. |
| **Slice** | Part of a large diff. Its own model call reviews it (`PRREVIEW_GATE_CHUNK_*`). |
| **Verdict** | The first line of the comment: ✅ Approved or ❌ Changes requested. It is text in a comment. It is not a GitHub review state. |
| **Blocking finding** | A CRITICAL or HIGH finding that counts toward ❌ Changes requested. MEDIUM and LOW findings are listed and do not change the verdict. |
| **Refutation** | A second model call on one blocking finding that tries to prove it wrong. The reviewer drops a refuted finding. |
| **Hold** | A wait before the reviewer tries the same head again after a failed attempt (see [When something fails](#when-something-fails)). |
| **Owner login** | The account whose comments the reviewer treats as its own earlier verdicts (`PRREVIEW_OWNER_LOGIN`, or the App). |

`pr-autoreview.sh` reads the settings named `PRREVIEW_GATE_*`. `review-loop.sh`
reads the settings named `PRREVIEW_LOOP_*`. It starts the rounds.


## How one round works

1. **Pick.** For each repo, list the open PRs with their authors in one call.
   Keep a PR when it meets all three conditions:
   - Its author is trusted.
   - It is not a draft.
   - Its current head has no comment from this reviewer yet.

   Before any model call, the job checks the author again with its own read of
   the PR. The comment carries a hidden marker. The marker holds the head SHA
   and a hash of the title, description and base branch. For a stacked PR, it
   also holds the base commit. Only comments by the own account of the reviewer
   count. A comment from another App that carries the marker gets a `WARNING`
   line in the log. The reviewer reviews the head anyway, however many such
   comments there are.

   The reviewer also keeps a count of the verdicts it posted for each head. The
   count is in the hold directory (`PRREVIEW_GATE_HOLDOFF_DIR`). At two
   verdicts for one head, the list of App logins (`PRREVIEW_REVIEW_APP_SLUG`)
   is probably wrong, and the reviewer does not see its own comments. The head
   then counts as handled. The reviewer makes no review and no model call for
   it, and logs a `WARNING` line in every round. It reviews the head again
   after the author pushes.

   The count file stays while its PR is open. The reviewer removes it when
   both conditions are true:
   - The PR is not open.
   - The file is three days old or more.

   A repo with 1000 or more open PRs keeps all its count files, because the
   list of open PRs may be cut off. If the hold directory cannot be written, or
   the count file name cannot be built for the owner and repo, the reviewer
   skips the PR before any model call. The round then fails, so the failure
   alert runs.

   A PR on hold after a failure waits out its hold (see
   [When something fails](#when-something-fails)).
2. **Scan.** Check the title and description of the PR against your
   sensitive-patterns file. A match stops the review of that PR. The round reads
   the title and body of the issue that the PR links. It runs the same check on
   them, before any model call.
3. **Build.** Prepare the tree in these steps:
   - Update the local clone of the repo. Add a worktree for the PR. Check out
     the merge base of the PR in it. Apply the diff of the PR on top. The
     reviewer never checks out the branch of the author.
   - Then, for every PR, copy the convention files from the newest commit of the
     default branch. The match ignores file name case. The copy removes a file
     that the tree has and the default branch lacks. It adds a file that only the
     default branch has.
   - The copy comes after the diff. So a convention file that is newer on the
     default branch cannot make the diff fail to apply. If a step of the copy
     fails, the round skips that PR and tries again next round.
   - The reviewer fetches the diff once, for the exact head commit that the
     verdict will name. It reads the list of changed files from that same diff.
     A push that lands during the round cannot swap in another head.
   - The round skips the PR and tries again next round in three cases. It cannot
     find the merge base. Or it cannot fetch the diff. Or the diff holds a
     different number of files than GitHub reports for the PR.
   - A symlink to a regular file inside the clone is fine. An example is
     `AGENTS.md -> CLAUDE.md`. Any other symlink stops the review. These
     symlinks stop it:
     - A link that points outside the clone, into `.git` or nowhere.
     - A link to a folder, because a path through a folder link can climb out
       with `..`.
     - A link from a convention file to anything but another convention file
       that git tracks. The convention files are `CLAUDE.md`,
       `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`, anything under `.claude/`,
       a README or CONTRIBUTING file, and `.github/review-checks.md`. The PR
       could edit any other file, and so write the rules that judge it.
   - The read access of the model is limited by path, and a link can lead it
     past that limit. A symlink that the PR adds gets a comment that asks the
     author to fix or remove it. A symlink already on the base branch stops
     every PR against that branch, with no comment. The round log names the
     link. The round counts as failed (see
     [When something fails](#when-something-fails)).
4. **Slice.** Cut a diff of more than 300 lines by file into slices of about 250
   lines. A round has at most 8 slices. A PR over 2000 changed lines or 40 files
   gets a "please split" comment and no review. Three exceptions apply:
   - At least 90% of the changed lines are deletions.
   - The PR touches only lock files, generated code, snapshots or migrations.
   - Its description has a paragraph that starts with `split-exempt:` and says
     why the PR cannot be split.

   The reviewer reviews these PRs in full. In the first round, each slice gets
   two passes.
5. **Review.** Claude Code reads the tree and the diff. It answers with JSON.
   The JSON holds a verdict, findings with severity, file, line and fix, and
   what it could not verify. The slices run in parallel.
6. **Verify.** The reviewer drops findings that do not have the expected shape.
   It drops findings that cite a file that does not exist. Each blocking finding
   then gets its own call that tries to refute it. The limit is
   `PRREVIEW_GATE_VERIFY_MAX` (6) in a round. The reviewer drops a refuted
   finding. Any finding beyond the cap stands.
7. **Post.** Render one comment. Escape the model text (see
   [SECURITY.md](../SECURITY.md)). Scan the comment against your patterns. Post
   it. The end of the round prints the model usage and the cost of the round.

CRITICAL and HIGH findings block. MEDIUM and LOW findings are listed under the
verdict and do not block. Two kinds of HIGH finding are listed and do not block:

- On a PR of 300 changed lines or more (`PRREVIEW_GATE_COACH_MAX_LINES`), some
  HIGH findings do not block. They are findings about tests, conventions,
  wording or process. They also include findings about a doc or code comment that
  only maintainers read. The comment still shows them as HIGH, marked not
  blocking. On a smaller PR they block like any other HIGH. The prompt tells the
  model which of the two cases applies.
- On any PR, a HIGH finding that the model tags as wording, judgment or a
  half-finished fix. The comment shows it as MEDIUM, with its original severity
  next to it.

"Block" here only decides the verdict. The reviewer itself never stops a merge.

### Optional: a red team before an approval

The refutation calls in step 6 can only remove findings. The red team is the
one step that looks for a defect that the review missed. It runs only on a
round that is about to post ✅ Approved.

It is off by default, because it adds cost and time to every approval. On a
small clean test PR (Run C in [Cost](trust-cost-limits.md#cost)), the review cost $0.34 and the
red-team call cost $0.23. These figures come from a test PR in September and
October 2026, before v0.2.0 changed the default models. Current costs can
differ. Each candidate that it raises adds one refutation call. So at most
three more calls follow. The red-team call runs after the review. The refutation
calls run together after it. So an approval can take up to twice
`PRREVIEW_GATE_VERIFY_TIMEOUT` (1200 seconds) longer to appear.


## Across rounds

Every push is a new round. The blocking findings of the previous round go back
into the prompt. The prompt asks the model to say which ones are fixed. It also
asks the model to repeat each unfixed one, word for word, with a `Carried over:`
prefix. The aim is that the author sees the same finding and not a rewording of
it. The harness does not check that the model does this.

From round 2 on, a new blocking finding can be about a file that the changes
since the last reviewed round did not touch. If no earlier round cited that
file, the comment shows the finding as MEDIUM. The finding was just as visible
in round 1. The author should not pay a round for a miss of the reviewer.
CRITICAL findings are never lowered.

Suppose a PR is merged. The last comment of the reviewer on it is one of these:
❌ Changes requested, ❌ Please split, ⛔ Review withheld or ⛔ Refused. Then the
next round posts one alert comment on the merged PR. With
`PRREVIEW_GATE_TICKETS=1` it also opens a follow-up issue. The check reads the
first 10 merged PRs that `gh pr list` returns. `gh pr list` sorts them by when
they were opened. The check alerts on those merged in the last 48 hours. A PR
opened long before it was merged can fall outside those 10.


## When something fails

The reviewer does not post a verdict that it could not reach. Instead, this
happens:

- **Some slices of a large diff fail.** The reviewer posts the slices that worked
  as one comment. The comment always says ❌ Changes requested, whatever the
  slices found. It lists the files that no slice reviewed. Push again to review
  the whole diff.
- **The review fails outright.** Every call fails or times out, or the answer
  still cannot be parsed after the repair call. The reviewer posts nothing for
  that head. The head goes on hold. The hold is 5 minutes
  (`PRREVIEW_GATE_HOLDOFF_FAIL`), or 30 minutes after a usage-limit error
  (`PRREVIEW_GATE_HOLDOFF_QUOTA`). Each repeat of the same reason doubles the
  wait, up to an hour (`PRREVIEW_GATE_HOLDOFF_MAX`). The round log says when the
  next attempt is due. To retry at once, delete the files named
  `<repo>-<PR number>-*` in `~/.cache/pr-reviewer/review-holdoff/`. A new push
  starts over with no hold. So does an edited title, description or base branch,
  and a push to the parent branch of a stacked PR. The cooldown for those edits
  and that push (`PRREVIEW_GATE_PR_COOLDOWN_MIN`) is a separate wait.
- **Posting the comment fails.** The reviewer keeps the finished comment. The head
  goes on the same hold as above (5 minutes, doubling on repeats). The next
  attempt after that posts the kept comment. It does not call the model again.
- **The comment matches your sensitive-data patterns, or the scan cannot run.**
  The reviewer posts a short notice instead. The full text goes only to the round
  log, in a directory that only you can read.
- **Something stops a PR or a whole repo from being reviewed at all.** These
  cases are of this kind:
  - A repo or a PR that cannot be read.
  - A merge base that cannot be found.
  - A diff that cannot be fetched whole.
  - A symlink on the base branch.
  - An App token that cannot be created.
  - A hold directory that cannot be written.
  - A review job that crashes.

  The round finishes the other PRs. Then it exits with an error. If you set
  `PRREVIEW_ALERT_REPO`, `review-loop.sh` then opens one issue there. It opens no
  second issue while that issue is open. Closing the issue re-arms the alert.
  While the issue stays open and rounds keep failing, it gets a "Still failing"
  comment at most every 6 hours (`PRREVIEW_ALERT_REPEAT_HOURS`). Without
  `PRREVIEW_ALERT_REPO`, the failure appears only in the log.
- **A round runs longer than `PRREVIEW_LOOP_ROUND_TIMEOUT`** (3900 seconds). The
  loop kills it and counts it as failed. The default leaves room for a first
  round on a diff near the 2000-line ceiling. Two passes over eight slices make
  16 calls. At 8 calls in flight, that is two waves of
  `PRREVIEW_GATE_REVIEW_TIMEOUT`.


## Watching a round

`prreview logs` shows the own log of the service, a few lines for each round.
The full output of each round is in `~/.cache/pr-reviewer/gate-logs/round-*.log`.

With no open PR, `prreview once` prints only `ROUND USAGE: 0 call(s)`. That is
not an error.

A round that reviews one PR prints a log like this sample. The cost comes from
a test PR in September and October 2026, before v0.2.0 changed the default
models. Current costs can differ.

```text
[your-name__your-repo#3] PR #3: refutation upheld CRITICAL app/store.py:30 (refuted=false, confidence 0.97)
[your-name__your-repo#3] PR #3: refutation upheld HIGH app/store.py:29 (refuted=false, confidence 0.95)
[your-name__your-repo#3] https://github.com/your-name/your-repo/pull/3#issuecomment-…
[your-name__your-repo#3] PR #3: review-only verdict comment posted (verdict=request_changes)
ROUND USAGE: 3 call(s)  in=28 out=6978 cache_read=347346 cache_write=40101  cost=$0.75
  review       1 call(s)  $0.44
  verify       2 call(s)  $0.31
```

If you run `prreview once` again without a push, the head already has its
comment. The reviewer skips the PR. With the service installed, `prreview once`
right after setup usually prints `this head was already handled` for every PR.
The service got there first. If it prints
`another pr-autoreview run holds … — exiting`, the service is in the middle of
a round. `prreview logs -f` shows that round. To try `once` on its own, run
`prreview stop` first. Then run `prreview start` afterwards. A stopped service
stays stopped.


## Command rules

These rules hold for every `prreview` command except `set`. A check runs before `prreview` reads the settings, so it cannot change the service or the settings.

- If any argument is `-h` or `--help`, the command prints its usage, exits with code 0 and does nothing else. `prreview --version` works like `prreview version`.
- Otherwise a command rejects an argument that it does not take. It prints `unknown argument:` and the usage of the command, and it exits with code 2. It changes nothing: the service and the settings stay as they were.

`prreview set <name> <value>` follows other rules, because its value can be any text:

- Only the first argument is checked for `-h` and `--help`. `prreview set --help` prints the usage and exits with code 0. In `prreview set model --help`, `--help` is the value, and `prreview` stores it. A setting that takes a number or a path rejects that value.
- The check for unknown arguments never rejects an argument of `set`. A wrong name or value fails inside `set`, with a message that starts with `prreview:` and exit code 1. Fewer than two arguments also exit with code 1.

- A command that changes a setting restarts the service when the service runs. The loop keeps its old settings until it restarts. `prreview repos add`, `prreview repos remove`, `prreview set` and `prreview unset` are such commands.


## Where to run it

Run it on a machine only you use. The background service runs as your user. It
uses your `gh` login, your Claude Code login and, if you set one up, the private
key of a GitHub App. Anyone who can act as that user can post as you.

launchd or systemd starts the service, not your shell. So the service does not
see variables that your shell profile exports. Log in with `gh auth login` and
`claude auth login`. A `GH_TOKEN` or `ANTHROPIC_API_KEY` that exists only in your
shell never reaches the service. But `prreview once` in that same terminal does
see it. To use an API key, run `prreview run` from a terminal that has the key.
Or run `claude auth login` to store a login. On a machine with no browser, such
as a server you reach over SSH, `claude auth login` prints a link to open on
another device. Claude Code also runs with no settings sources. So nothing in
`~/.claude/settings.json` (model, permissions, hooks, `env`) applies to a review.

The reviewer clones over the protocol that `gh config get git_protocol` reports.
It fetches with the login of `gh`. With `ssh`, the background service would need
your SSH key with no prompt. A systemd user service has no ssh-agent. So
`prreview setup` offers to switch `gh` to `https` when you choose the background
service. `prreview start` offers it when it installs the service and stdin is a
terminal. With no terminal, `prreview start` prints the command and goes on. The
switch changes `gh` for all programs, not only this one. The command is
`gh config set git_protocol https -h github.com`.

On Linux, a separate account for the reviewer keeps it apart. This page calls the
account `reviewer`. Log in to that account directly, for example over SSH. Do not
switch to it with `su` or `sudo -iu`. A switched session has no
`XDG_RUNTIME_DIR`. So `systemctl --user` cannot reach the service manager of the
account, and `prreview setup` cannot install the service. If switching is the
only way in, run:

```bash
sudo loginctl enable-linger reviewer      # once, from an admin account
export XDG_RUNTIME_DIR=/run/user/$(id -u) # in the reviewer's session
./prreview setup
```

## Where it keeps its files

| Path | What is there |
| --- | --- |
| `~/.config/pr-reviewer/` | `config`, `sensitive-patterns`, your copy of the checklist in `checks/`, and the key of a GitHub App as `app.pem` |
| `~/.cache/pr-reviewer/` | The log `gate.log` of the service, round logs in `gate-logs/`, holds and counts of posted verdicts in `review-holdoff/`, and the round lock |
| `~/.cache/pr-reviewer/work/` | Review clones and the scratch files of each round (`PRREVIEW_GATE_WORKROOT`). The path is under `$XDG_CACHE_HOME` when that is set |
| `~/.local/state/pr-reviewer/` | Which repo the next round starts with. The path is under `$XDG_STATE_HOME` when that is set |
| `~/Library/LaunchAgents/local.pr-reviewer.plist` | The background service on macOS |
| `~/.config/systemd/user/pr-reviewer.service` | The background service on Linux |


## Removing it

`prreview uninstall` removes only the background service. To remove everything,
run:

```bash
cd ~/pr-reviewer
./prreview uninstall
rm -rf ~/.config/pr-reviewer ~/.cache/pr-reviewer ~/.local/state/pr-reviewer
rm -f ~/.local/bin/prreview
cd ~ && rm -rf ~/pr-reviewer
```

The first `rm` also deletes your checklist copy and the key of the App. Keep
anything you want first. If `XDG_CACHE_HOME` or `XDG_STATE_HOME` is set, or you
set `PRREVIEW_GATE_WORKROOT`, remove those directories too. If you ran
`loginctl enable-linger` only for the reviewer, `sudo loginctl disable-linger
"$USER"` undoes it. A GitHub App stays on GitHub until you delete it on its
settings page. If you added a `PATH` line to `~/.zshrc` for `~/.local/bin`,
remove it by hand when nothing else uses that directory.
