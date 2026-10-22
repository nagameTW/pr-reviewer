# Configuration

Settings come from two layers: a config file, and overrides in the environment.

- **The config file** is `~/.config/pr-reviewer/config`, one `KEY=value` per
  line. `prreview setup` writes it. `prreview set <name> <value>` changes one
  line, `prreview get <name>` reads one, and `prreview unset <name>` removes
  one. A value is taken literally: no quotes, nothing expanded.
- **The environment** overrides the file. A variable that is already set in
  the environment wins, so `PRREVIEW_GATE_PARALLEL=1 prreview once` works as
  you expect. The background service does not see your shell's variables, so
  put a setting you want it to use in the file.
- **Required:** `PRREVIEW_GATE_REPOS`, and the sensitive-data patterns file,
  which `prreview setup` writes for you.
- **`PATH`** is the exception. `prreview setup` records the terminal's `PATH`
  so the background service finds `gh` and `claude`, and that recorded value is
  used even when you run `prreview once` from a terminal. After you move a
  tool, run `prreview set PATH "$PATH"` or `prreview setup` again.

| Variable | Default | What it does |
| --- | --- | --- |
| `PRREVIEW_GATE_REPOS` | none (required) | Space-separated `owner/repo` list to review |
| `PRREVIEW_GATE_TRUSTED_AUTHORS` | empty | Logins whose fork PRs are reviewed, separated by spaces or commas (see [Whose PRs it reviews](operations.md#whose-prs-it-reviews)) |
| `PRREVIEW_GATE_FORK_PRS` | `0` | `1` reviews PRs from forks like any other PR |
| `PRREVIEW_GATE_ONCE_WAIT` | `300` | Seconds that `prreview once --pr` waits for a running round. A whole number; `0` means do not wait |
| `PRREVIEW_OWNER_LOGIN` | `gh api user` | The account whose marked comments count as this reviewer's own; with a GitHub App set, only the App's comments count |
| `PRREVIEW_REVIEW_APP_ID` | empty | A GitHub App's ID; when set, comments are posted as the App (see [Posting as a GitHub App](github-app.md)) |
| `PRREVIEW_REVIEW_APP_KEY` | empty | The App's private key file |
| `PRREVIEW_REVIEW_APP_SLUG` | read from GitHub every round | The App's URL name; its comments are authored by `<slug>[bot]`. Leave it unset, so renaming the App cannot leave a stale one |
| `PRREVIEW_SENSITIVE_PATTERNS_FILE` | `~/.config/pr-reviewer/sensitive-patterns` | The regex list that every comment carrying PR text or model output, and every PR title and description and every linked issue, is checked against |
| `PRREVIEW_GATE_REPO_CONTEXT` | a sentence pointing at `CLAUDE.md`/`AGENTS.md`, `README`, `CONTRIBUTING` | Replaces the sentence that tells the model where a repo's conventions live |
| `PRREVIEW_REVIEW_MODEL` | `claude-opus-5-5` | Model for the review, the refutation pass and the red team |
| `PRREVIEW_GATE_CHEAP_MODEL` | `claude-sonnet-5-5` | Model for repairing unparseable output |
| `PRREVIEW_GATE_SAMPLES` | `1` | Review passes per slice after a PR's first round; findings are merged across passes |
| `PRREVIEW_GATE_SAMPLES_ROUND1` | `1` | Review passes per slice in a PR's first round |
| `PRREVIEW_GATE_ZERO_RECHECK_LINES` | `1000` | From this many changed lines, a first round gets at least two passes; `0` turns it off |
| `PRREVIEW_GATE_REVIEW_TIMEOUT` | `900` | Seconds per review call |
| `PRREVIEW_GATE_REPAIR_TIMEOUT` | `300` | Seconds for the call that repairs an unparseable answer |
| `PRREVIEW_GATE_VERIFY_MAX` | `6` | Most blocking findings that get a refutation call |
| `PRREVIEW_GATE_VERIFY_TIMEOUT` | `600` | Seconds per refutation call |
| `PRREVIEW_GATE_CHUNK_MIN_LINES` | `300` | Diffs larger than this are sliced |
| `PRREVIEW_GATE_CHUNK_TARGET_LINES` | `250` | Target lines per slice |
| `PRREVIEW_GATE_CHUNK_MAX` | `8` | Most slices per PR |
| `PRREVIEW_GATE_MAX_REVIEW_LINES` | `2000` | Above this many changed lines, ask for a split instead of reviewing |
| `PRREVIEW_GATE_MAX_REVIEW_FILES` | `40` | The same ceiling in files |
| `PRREVIEW_GATE_SPLIT_EXEMPT_RE` | lock files, `*.gen.ts`, `*.gen.js`, `*.gen.py`, `*.gen.go`, `*.snap`, `migrations/`, `generated/`, `__generated__/`, `dist/`, `build/`, `vendor/` | Extended regex for paths that count as generated: a PR over the ceiling whose every file matches is reviewed instead of asked to split |
| `PRREVIEW_GATE_FILE_CAP` | `7` | Most findings shown for one file, counted separately for blocking and not blocking; the rest fold into one line that still counts toward the verdict. `0` shows all |
| `PRREVIEW_GATE_COACH_MAX_LINES` | `300` | From this many changed lines, a HIGH about tests, conventions, wording or process no longer blocks (see [How one round works](operations.md#how-one-round-works)) |
| `PRREVIEW_GATE_HOLDOFF_FAIL` | `300` | Seconds a head waits after a failed review or post (see [When something fails](operations.md#when-something-fails)) |
| `PRREVIEW_GATE_HOLDOFF_QUOTA` | `1800` | Seconds a head waits after a usage-limit error |
| `PRREVIEW_GATE_HOLDOFF_MAX` | `3600` | Longest wait after repeated failures |
| `PRREVIEW_GATE_HOLDOFF_DIR` | `~/.cache/pr-reviewer/review-holdoff` | Where those holds are kept, along with verdicts waiting to be posted again |
| `PRREVIEW_GATE_PR_COOLDOWN_MIN` | `10` | Minutes a PR waits after the reviewer's last comment when its title, description or base branch changed and the head is the same. A push to the PR branch never waits. A push to the parent branch of a stacked PR can wait, because only the head is compared. A whole number; `0` turns the wait off. `prreview once --pr` ignores it |
| `PRREVIEW_GATE_PARALLEL` | `2` | PRs reviewed at the same time |
| `PRREVIEW_GATE_CALL_CAP` | `8` | Model calls in flight for one PR |
| `PRREVIEW_GATE_ROUND_BUDGET` | `900` | Seconds a round may spend starting new reviews |
| `PRREVIEW_GATE_REDTEAM` | `0` | `1` adds a red-team call on PRs about to be approved (see [the red team](operations.md#optional-a-red-team-before-an-approval)) |
| `PRREVIEW_GATE_REDTEAM_MAX` | `3` | Most red-team candidates that get a refutation call |
| `PRREVIEW_GATE_REDTEAM_SPEC_MAX` | `80` | Most document paths (docs, specs, ADRs, schemas) the red team is shown |
| `PRREVIEW_GATE_SYMBOLS` | `1` | Lists, for each definition the diff changes, the references it left untouched, and gives the list to the model; no model cost. `0` turns it off |
| `PRREVIEW_GATE_VERIFY_LINES` | `0` | `1` drops a finding whose line number is past the end of the file it cites |
| `PRREVIEW_GATE_WORKROOT` | `~/.cache/pr-reviewer/work` | Where the review clones and scratch files live; must be absolute |
| `PRREVIEW_GATE_LOCK` | `~/.cache/pr-reviewer/pr-autoreview.lock` | The lock that keeps two rounds from running at once |
| `PRREVIEW_STATE_DIR` | `$XDG_STATE_HOME`, else `~/.local/state` | Where state that must outlive a cleared cache goes, under `pr-reviewer/` |
| `PRREVIEW_GATE_CURSOR` | `pr-reviewer/gate-repo-cursor` in that directory | The file that records which repo the next round starts with |
| `PRREVIEW_GATE_CHECKS_DIR` | `checks/` next to the script | The checklist directory, one file per item (see [Adding your own checks](#adding-your-own-checks)) |
| `PRREVIEW_GATE_TITLE_CHECK` | `0` | `1` asks for Conventional Commits PR titles and skips PRs without one |
| `PRREVIEW_GATE_ISSUE_NOTE` | `0` | `1` adds a note when a PR links no issue |
| `PRREVIEW_GATE_TICKETS` | `0` | `1` opens follow-up issues for some findings that do not block (see [Follow-up issues](#follow-up-issues)); the token then needs to open issues |
| `PRREVIEW_GATE_ISSUE_MIN_SEVERITY` | `high` | Which of those findings get an issue: `critical`, `high`, `medium` or `low` |
| `PRREVIEW_GATE_DISARM_AUTO_MERGE` | `0` | `1` turns off an auto-merge that was armed on a head the reviewer has not reviewed yet, and on a PR it skips because of its author; the token then needs write access |
| `PRREVIEW_ALERT_REPO` | empty | `owner/repo` where the loop opens an issue when a round fails, or when `pr-autoreview.sh` itself no longer parses (the token then needs to open issues there); empty only logs it. Use a private repository. Each alert issue records a time when the host was up. |
| `PRREVIEW_ALERT_REPEAT_HOURS` | `6` | Hours between "Still failing" comments on an alert issue that is still open |
| `PRREVIEW_LOOP_INTERVAL` | `60` | Seconds between the loop's checks for open PRs; a check that finds any PR the reviewer would read starts a round |
| `PRREVIEW_LOOP_IDLE_EVERY` | `15` | With no PR to review, start a round only on every this-many-th check |
| `PRREVIEW_LOOP_ROUND_TIMEOUT` | `3900` | Seconds before the loop stops a round (see [When something fails](operations.md#when-something-fails)) |
| `PRREVIEW_LOOP_ROUND_KILL_AFTER` | `60` | Seconds a round gets to exit after that before it is killed |
| `PRREVIEW_LOOP_READY_FAIL_LIMIT` | `5` | Checks in a row that `pr-autoreview.sh` may fail to parse before the loop files an alert issue in `PRREVIEW_ALERT_REPO` |
| `PRREVIEW_LOOP_KEEP_LOGS` | `500` | Round logs to keep. When `prreview` runs the service, its own log, `gate.log`, is kept under 10 MB, with the previous 10 MB in `gate.log.1` |
| `PRREVIEW_CLONE_NET_TIMEOUT` | `600` | Seconds for one clone or fetch |

`GH_BIN` and `CLAUDE_BIN` point at the `gh` and `claude` binaries when they are
not the first ones on `PATH`. Other `PRREVIEW_` variables in the scripts are for
the tests and for unusual setups; they are described next to the line that
reads them and may change between versions.

### Follow-up issues

With `PRREVIEW_GATE_TICKETS=1`, findings that do not block but should not be lost
go to a follow-up issue in the PR's repo, one open issue per PR that later
rounds append to:

- On a ✅ Approved round, its MEDIUM findings.
- On a ❌ Changes requested round, the HIGH findings shown as MEDIUM instead:
  one about a file the changes since the last reviewed round do not touch
  and no earlier round cited (see
  [Across rounds](operations.md#across-rounds)),
  or one the model tagged as wording, judgment or a half-finished fix (see
  [How one round works](operations.md#how-one-round-works)).
- Every post-merge alert.

Blocking findings never get an issue: they are the verdict, and the comment
already lists them. Neither do findings about tests, conventions, wording or
process, doc findings only maintainers read, or LOW findings.

`PRREVIEW_GATE_ISSUE_MIN_SEVERITY` then filters the MEDIUM findings. A HIGH shown
as MEDIUM because it came late (see [Across rounds](operations.md#across-rounds)) counts
at its original HIGH; every other one counts as MEDIUM. So the default `high` files
only those late findings, `medium` and `low` file every candidate, and
`critical` files none. Post-merge alerts are not filtered.

If a repo's default branch has required status checks, the reviewer still
reviews without waiting for them. It reads code, and the note at the bottom of
every verdict says so.


## Adding your own checks

The checklist is the `checks/` directory, one Markdown file per item. The
reviewer reads every `.md` file in it at the start of each round.

- **Add an item:** drop a file in `checks/`. The number at the front of the
  name is the item number, so `50-migrations.md` becomes item 50. Number your
  own items 50 and up, so a built-in item a later version adds cannot take
  the same number: two files with one number stop the reviewer.
- **Remove an item:** delete its file. The other items keep their numbers.
- **Change an item:** edit its file. The text goes to the model as written.

An item that only matters for some files can say so in front matter. This one
is sent only when the PR changes a Python file:

```markdown
---
applies_to: *.py *.pyi
---
Python — a new function that opens a file, socket or subprocess closes it on
every path, including exceptions. A path that skips the close on an error is HIGH.
```

`*` matches across directories, so `*.py` also matches `src/app/main.py`.
An item without front matter is sent on every PR.

The reviewer refuses to start when the directory is missing or empty, when a
file name has no number, when front matter has a key other than `applies_to`,
or when all the files together exceed 64 KiB. A review that quietly skipped a
check would still read as if it had applied it.

To keep your checklist outside the clone, copy `checks/` somewhere else and
point `PRREVIEW_GATE_CHECKS_DIR` at the copy. A copy does not follow updates: when
a new version rewords a built-in item, your copy keeps the old wording.
`prreview setup` lists built-in items your copy lacks and offers to add them. It
never overwrites a file you have, and skips a built-in item whose number one
of your files already uses.

Two more places add rules for a single repo:

- **The repo's own conventions.** Write them in `CLAUDE.md`, `AGENTS.md`,
  `README` or `CONTRIBUTING`. Item 4 holds every diff to them.
- **`.github/review-checks.md` in the repo.** A plain list of extra checks this
  repo wants on every PR. The model applies each one like a numbered item,
  with the same severities.

These files are read from the newest commit of the default branch, so a PR
cannot loosen a check in the same diff it is reviewed against. A parent branch
cannot loosen a check either. The file name can be in any letter case. A change
to the checks takes effect for every open PR at its next review, including old
branches. Merge it first when a PR must be judged by the new checks.

A `.github/review-checks.md` can be as short as this:

```markdown
- Every new HTTP handler checks the caller's role before it reads the
  database. A handler without that check is HIGH.
- Every migration can be rolled back. A migration with no down step is HIGH.
- User-facing text in `src/ui/` goes through `t()`. A hard-coded string is
  MEDIUM.
```

Put the severity in the check when you care about it; otherwise the model
chooses one the same way it does for the built-in items.


## Without prreview

`prreview` only writes settings and starts the loop. Everything also works from
environment variables. The reviewer refuses to start without a
sensitive-data patterns file, so copy the example first:

```bash
mkdir -p ~/.config/pr-reviewer ~/.cache/pr-reviewer
cp sensitive-patterns.example ~/.config/pr-reviewer/sensitive-patterns
export PRREVIEW_GATE_REPOS="your-name/your-repo"
bash pr-autoreview.sh                          # one round
nohup bash review-loop.sh >> ~/.cache/pr-reviewer/gate.log 2>&1 &   # the loop
```

Each round's full output goes to `~/.cache/pr-reviewer/gate-logs/`. The
loop's own output grows without limit here: only the service `prreview` installs
keeps `gate.log` under 10 MB. Any scheduler that runs `pr-autoreview.sh`
works in place of the loop, and a lock stops two rounds from overlapping.

