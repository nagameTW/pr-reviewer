# Configuration

Settings come from two layers. The first layer is a config file. The second layer is overrides in the environment.

- **The config file** is `~/.config/pr-reviewer/config`, with one `KEY=value` per
  line. `prreview` reads it before it starts the reviewer. `prreview setup` writes it. `prreview set <name> <value>` changes one
  line. `prreview get <name>` reads one. `prreview unset <name>` removes one.
  The reviewer takes a value literally. It removes no quotes and expands
  nothing.
- **The environment** overrides the file. A variable that is already set in
  the environment wins. So `PRREVIEW_GATE_PARALLEL=1 prreview once` works as
  you expect. The background service does not see the variables of your shell.
  Put a setting for the service in the file.
- **Required:** `PRREVIEW_GATE_REPOS`, and the sensitive-data patterns file.
  `prreview setup` writes that file for you.
- **`PATH`** is the exception. `prreview setup` records the `PATH` of the
  terminal. So the background service finds `gh` and `claude`. The reviewer uses
  that recorded value even when you run `prreview once` from a terminal. After
  you move a tool, run `prreview set PATH "$PATH"` or run `prreview setup` again.

| Variable | Default | What it does |
| --- | --- | --- |
| `PRREVIEW_GATE_REPOS` | none (required) | List of `owner/repo` names to review, separated by spaces |
| `PRREVIEW_GATE_TRUSTED_AUTHORS` | empty | Logins whose fork PRs are reviewed. Separate them with spaces or commas (see [Whose PRs it reviews](operations.md#whose-prs-it-reviews)) |
| `PRREVIEW_GATE_FORK_PRS` | `0` | `1` reviews PRs from forks like any other PR |
| `PRREVIEW_GATE_ONCE_WAIT` | `300` | Seconds that `prreview once --pr` waits for a running round. The value is a whole number. `0` means do not wait |
| `PRREVIEW_OWNER_LOGIN` | `gh api user` | The account whose marked comments count as comments of this reviewer. With a GitHub App set, only the comments of the App count |
| `PRREVIEW_REVIEW_APP_ID` | empty | ID of a GitHub App. When set, the reviewer posts comments as the App (see [Posting as a GitHub App](github-app.md)) |
| `PRREVIEW_REVIEW_APP_KEY` | empty | The private key file of the App |
| `PRREVIEW_REVIEW_APP_SLUG` | read from GitHub every round | The URL name of the App. Its comments have the author `<slug>[bot]`. Leave it unset, so that renaming the App cannot leave a stale value |
| `PRREVIEW_SENSITIVE_PATTERNS_FILE` | `~/.config/pr-reviewer/sensitive-patterns` | The regex list. The reviewer checks every PR title, PR description and linked issue against it. It also checks every comment that carries PR text or model output |
| `PRREVIEW_GATE_REPO_CONTEXT` | a sentence pointing at `CLAUDE.md`/`AGENTS.md`, `README`, `CONTRIBUTING` | Replaces the sentence that tells the model where the conventions of a repo live |
| `PRREVIEW_REVIEW_MODEL` | `claude-opus-5-5` | Model for the review, the refutation pass and the red team |
| `PRREVIEW_GATE_CHEAP_MODEL` | `claude-sonnet-5-5` | Model for the repair of unparseable output |
| `PRREVIEW_GATE_SAMPLES` | `1` | Review passes for each slice after the first round of a PR. The reviewer merges the findings of all passes |
| `PRREVIEW_GATE_SAMPLES_ROUND1` | `1` | Review passes for each slice in the first round of a PR |
| `PRREVIEW_GATE_ZERO_RECHECK_LINES` | `1000` | From this many changed lines, a first round gets at least two passes. `0` turns it off. The first round of a split-exempt PR gets two passes at any size |
| `PRREVIEW_GATE_REVIEW_TIMEOUT` | `900` | Seconds for each review call |
| `PRREVIEW_GATE_REPAIR_TIMEOUT` | `300` | Seconds for the call that repairs an unparseable answer |
| `PRREVIEW_GATE_VERIFY_MAX` | `6` | Most blocking findings that get a refutation call |
| `PRREVIEW_GATE_VERIFY_TIMEOUT` | `600` | Seconds for each refutation call |
| `PRREVIEW_GATE_CHUNK_MIN_LINES` | `300` | The reviewer slices diffs that are larger than this |
| `PRREVIEW_GATE_CHUNK_TARGET_LINES` | `250` | Target lines for each slice |
| `PRREVIEW_GATE_CHUNK_MAX` | `8` | Most slices for each PR |
| `PRREVIEW_GATE_MAX_REVIEW_LINES` | `2000` | Above this many changed lines, the reviewer asks for a split and does not review |
| `PRREVIEW_GATE_MAX_REVIEW_FILES` | `40` | The same ceiling in files. Localization data files do not count. They are still reviewed (see [How one round works](operations.md#how-one-round-works)) |
| `PRREVIEW_GATE_SPLIT_EXEMPT_RE` | lock files, `*.gen.ts`, `*.gen.js`, `*.gen.py`, `*.gen.go`, `*.snap`, `migrations/`, `generated/`, `__generated__/`, `dist/`, `build/`, `vendor/` | Extended regex for paths that count as generated. A PR over the ceiling is reviewed, and not asked to split, when every file matches |
| `PRREVIEW_GATE_FILE_CAP` | `7` | Most findings shown for one file. Blocking and non-blocking findings count separately. The rest fold into one line that still counts toward the verdict. `0` shows all |
| `PRREVIEW_GATE_COACH_MAX_LINES` | `300` | From this many changed lines, a HIGH finding about tests, conventions, wording or process no longer blocks (see [How one round works](operations.md#how-one-round-works)) |
| `PRREVIEW_GATE_HOLDOFF_FAIL` | `300` | Seconds that a head waits after a failed review or post (see [When something fails](operations.md#when-something-fails)) |
| `PRREVIEW_GATE_HOLDOFF_QUOTA` | `1800` | Seconds that a head waits after a usage-limit error |
| `PRREVIEW_GATE_HOLDOFF_MAX` | `3600` | Longest wait after repeated failures |
| `PRREVIEW_GATE_HOLDOFF_DIR` | `~/.cache/pr-reviewer/review-holdoff` | Where the reviewer keeps those holds, with the verdicts that wait to be posted again and the count of verdicts posted for each head |
| `PRREVIEW_GATE_PR_COOLDOWN_MIN` | `10` | Minutes that a PR waits after the last comment of the reviewer. This applies when the title, description or base branch changed and the head is the same. A push to the PR branch never waits. A push to the parent branch of a stacked PR can wait, because the reviewer compares only the head. The value is a whole number. `0` turns the wait off. `prreview once --pr` ignores it |
| `PRREVIEW_GATE_PARALLEL` | `2` | PRs that the reviewer reviews at the same time |
| `PRREVIEW_GATE_CALL_CAP` | `8` | Model calls in flight for one PR |
| `PRREVIEW_GATE_ROUND_BUDGET` | `900` | Seconds that a round may spend to start new reviews |
| `PRREVIEW_GATE_REDTEAM` | `0` | `1` adds a red-team call on PRs that are about to be approved (see [the red team](operations.md#optional-a-red-team-before-an-approval)) |
| `PRREVIEW_GATE_REDTEAM_MAX` | `3` | Most red-team candidates that get a refutation call |
| `PRREVIEW_GATE_REDTEAM_SPEC_MAX` | `80` | Most document paths (docs, specs, ADRs, schemas) that the red team sees |
| `PRREVIEW_GATE_SYMBOLS` | `1` | For each definition that the diff changes, the reviewer lists the references that the diff left untouched. It gives the list to the model. This costs no model usage. `0` turns it off |
| `PRREVIEW_GATE_VERIFY_LINES` | `0` | `1` drops a finding whose line number is past the end of the file that it cites |
| `PRREVIEW_GATE_WORKROOT` | `~/.cache/pr-reviewer/work` (under `$XDG_CACHE_HOME` when that is set) | Where the review clones and scratch files live. The path must be absolute |
| `PRREVIEW_GATE_LOCK` | `~/.cache/pr-reviewer/pr-autoreview.lock` | The lock that stops two rounds from running at the same time |
| `PRREVIEW_STATE_DIR` | `$XDG_STATE_HOME`, else `~/.local/state` | Where the reviewer puts state that must outlive a cleared cache, under `pr-reviewer/` |
| `PRREVIEW_GATE_CURSOR` | `pr-reviewer/gate-repo-cursor` in that directory | The file that records which repo the next round starts with |
| `PRREVIEW_GATE_CHECKS_DIR` | `checks/` next to the script | The checklist directory, with one file for each item (see [Adding your own checks](#adding-your-own-checks)) |
| `PRREVIEW_GATE_TITLE_CHECK` | `0` | `1` asks for Conventional Commits PR titles and skips PRs without one |
| `PRREVIEW_GATE_ISSUE_NOTE` | `0` | `1` adds a note when a PR links no issue |
| `PRREVIEW_GATE_TICKETS` | `0` | `1` opens follow-up issues for some findings that do not block (see [Follow-up issues](#follow-up-issues)). The token then needs the right to open issues |
| `PRREVIEW_GATE_ISSUE_MIN_SEVERITY` | `high` | Which of those findings get an issue: `critical`, `high`, `medium` or `low` |
| `PRREVIEW_GATE_DISARM_AUTO_MERGE` | `0` | `1` turns off an auto-merge that was armed on a head the reviewer has not reviewed yet. It does the same on a PR that it skips because of its author. The token then needs write access |
| `PRREVIEW_ALERT_REPO` | empty | `owner/repo` where the loop opens an issue when a round fails, or when `pr-autoreview.sh` itself no longer parses. The token then needs the right to open issues there. If empty, the loop only logs the failure. Use a repository that only you can read. Each alert issue records a time when the host was up |
| `PRREVIEW_ALERT_REPEAT_HOURS` | `6` | Hours between "Still failing" comments on an alert issue that is still open |
| `PRREVIEW_LOOP_INTERVAL` | `60` | Seconds between the checks of the loop for open PRs. A check that finds any PR the reviewer would read starts a round |
| `PRREVIEW_LOOP_IDLE_EVERY` | `15` | With no PR to review, the loop starts a round on one check in this many |
| `PRREVIEW_LOOP_ROUND_TIMEOUT` | `3900` | Seconds before the loop stops a round (see [When something fails](operations.md#when-something-fails)) |
| `PRREVIEW_LOOP_ROUND_KILL_AFTER` | `60` | Seconds that a round gets to exit after that. Then the loop kills it |
| `PRREVIEW_LOOP_READY_FAIL_LIMIT` | `5` | Checks in a row that `pr-autoreview.sh` may fail to parse before the loop files an alert issue in `PRREVIEW_ALERT_REPO` |
| `PRREVIEW_LOOP_KEEP_LOGS` | `500` | Round logs to keep. When `prreview` runs the service, its own log `gate.log` stays under 10 MB. The previous 10 MB go to `gate.log.1` |
| `PRREVIEW_CLONE_NET_TIMEOUT` | `600` | Seconds for one clone or fetch |

`GH_BIN` and `CLAUDE_BIN` point at the `gh` and `claude` binaries when they are
not the first ones on `PATH`. Other `PRREVIEW_` variables in the scripts are for
the tests and for unusual setups. A comment next to the line that reads each one
describes it. They may change between versions.

### Follow-up issues

With `PRREVIEW_GATE_TICKETS=1`, findings that do not block but should not be lost
go to a follow-up issue in the repo of the PR. Each PR has one open issue, and
later rounds append to it. The reviewer files these findings:

- On a ✅ Approved round, its MEDIUM findings.
- On a ❌ Changes requested round, the HIGH findings that the verdict shows as
  MEDIUM. They are of two kinds:
  - A finding about a file that no earlier round cited. The changes since the
    last reviewed round do not touch that file (see
    [Across rounds](operations.md#across-rounds)).
  - A finding that the model tagged as wording, judgment or a half-finished fix
    (see [How one round works](operations.md#how-one-round-works)).
- Every post-merge alert.

Blocking findings never get an issue. They are the verdict, and the comment
already lists them. Findings about tests, conventions, wording or process never
get one either. The same holds for doc findings that only maintainers read, and
for LOW findings.

`PRREVIEW_GATE_ISSUE_MIN_SEVERITY` then filters the MEDIUM findings. A HIGH shown
as MEDIUM because it came late (see [Across rounds](operations.md#across-rounds))
counts at its original HIGH. Every other finding counts as MEDIUM. So the default
`high` files only those late findings. The values `medium` and `low` file every
candidate. The value `critical` files none. The setting does not filter
post-merge alerts.

If the default branch of a repo has required status checks, the reviewer still
reviews without waiting for them. It reads code. The note at the bottom of every
verdict says so.


## Adding your own checks

The checklist is the `checks/` directory, with one Markdown file for each item.
The reviewer reads every `.md` file in it at the start of each round.

- **Add an item:** drop a file in `checks/`. The number at the front of the
  name is the item number. For example, `50-migrations.md` becomes item 50.
  Number your own items 50 and up. Then a built-in item that a later version adds
  cannot take the same number. Two files with one number stop the reviewer.
- **Remove an item:** delete its file. The other items keep their numbers.
- **Change an item:** edit its file. The text goes to the model as written.

Item 3 treats a host address in any RFC 1918 private range as a finding, in tests too. The exception is code that recognises or blocks private addresses, such as an SSRF guard (code that stops the server from fetching URLs on private networks), and the tests of that code. Item 3 also allows the address ranges and names that RFC 5737, RFC 3849 and RFC 2606 reserve for documentation. If your test fixtures use other ranges, edit `checks/03-sensitive-data.md` to match.

An item can apply to only some files. Say so in front matter. This item is sent
only when the PR changes a Python file:

```markdown
---
applies_to: *.py *.pyi
---
Python: a new function that opens a file, socket or subprocess closes it on
every path, including exceptions. A path that skips the close on an error is HIGH.
```

`*` matches across directories, so `*.py` also matches `src/app/main.py`.
An item without front matter is sent on every PR.

The reviewer refuses to start in these cases:

- The directory is missing or empty.
- A file name has no number.
- Front matter has a key other than `applies_to`.
- All the files together exceed 64 KiB.

This is on purpose. A review that quietly skipped a check would read as if it
had applied the check.

To keep your checklist outside the clone, copy `checks/` somewhere else. Then
point `PRREVIEW_GATE_CHECKS_DIR` at the copy. A copy does not follow updates.
When a new version rewords a built-in item, your copy keeps the old wording.
`prreview setup` lists the built-in items that your copy lacks. It offers to add
them. It never overwrites a file you have. It skips a built-in item when one of
your files already uses its number.

Two more places add rules for a single repo:

- **The conventions of the repo.** Write them in `CLAUDE.md`, `AGENTS.md`,
  `README` or `CONTRIBUTING`. Item 4 holds every diff to them.
- **`.github/review-checks.md` in the repo.** It is a plain list of extra checks
  that the repo wants on every PR. The model applies each one like a numbered
  item, with the same severities.

The reviewer reads these files from the newest commit of the default branch. So
a PR cannot loosen a check in the same diff that the reviewer checks. A parent
branch cannot loosen a check either. The file name can be in any letter case. A
change to the checks takes effect for every open PR at its next review,
including old branches. Merge the change first when the new checks must judge a
PR.

A `.github/review-checks.md` can be as short as this:

```markdown
- Every new HTTP handler checks the caller's role before it reads the
  database. A handler without that check is HIGH.
- Every migration can be rolled back. A migration with no down step is HIGH.
- User-facing text in `src/ui/` goes through `t()`. A hard-coded string is
  MEDIUM.
```

Put the severity in the check when it matters to you. Otherwise the model
chooses a severity in the same way as for the built-in items.


## Without prreview

`prreview` only writes settings and starts the loop. Everything also works from
environment variables. The scripts do not read the config file. A setting that
you made with `prreview set` has no effect when you run a script directly.
Export it as an environment variable. The reviewer refuses to start without a
sensitive-data patterns file. So copy the example first:

```bash
mkdir -p ~/.config/pr-reviewer ~/.cache/pr-reviewer
cp sensitive-patterns.example ~/.config/pr-reviewer/sensitive-patterns
export PRREVIEW_GATE_REPOS="your-name/your-repo"
bash pr-autoreview.sh                          # one round
nohup bash review-loop.sh >> ~/.cache/pr-reviewer/gate.log 2>&1 &   # the loop
```

The full output of each round goes to `~/.cache/pr-reviewer/gate-logs/`. The
output of the loop grows without limit here. Only the service that `prreview`
installs keeps `gate.log` under 10 MB. Any scheduler that runs
`pr-autoreview.sh` works in place of the loop. A lock stops two rounds from
overlapping.
