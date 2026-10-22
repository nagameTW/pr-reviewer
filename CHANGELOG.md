# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- CI runs the test suite on macOS with `/bin/bash`, which is bash 3.2. The
  job installs jq, gh, flock, shellcheck and coreutils with Homebrew and does
  not put the coreutils `gnubin` directory on `PATH`.
- `prreview once --pr owner/repo#N` reviews one PR now, a fork PR included.
  It reviews that PR and no other, and it waits for a running round with
  `flock -w`. If it cannot get the lock in `PRREVIEW_GATE_ONCE_WAIT` seconds
  (300 by default), it prints the reason and exits with code 75. It rejects
  any value that is not `owner/repo#N` for a repository on your list. It
  exits 0 only when the reviewer has a verdict (approve or request changes)
  on the current head. A notice alone, such as the title format reminder or
  the sensitive-data notice, gives 75 on every run. `PRREVIEW_GATE_ONCE_WAIT=0`
  means do not wait: the round tries the lock once with `flock -n`.
  `PRREVIEW_ONCE_PR` is set by `prreview once --pr` only. The loop clears it
  for every round, and `prreview set` and the settings file refuse it.
- `PRREVIEW_GATE_TRUSTED_AUTHORS` lists the logins whose fork PRs are
  reviewed. `PRREVIEW_GATE_FORK_PRS=1` reviews every PR, as before.
- `prreview status` shows how many PRs the last round skipped. A round that
  skips PRs prints one `WARNING:` line with the count.

### Changed

- `tests/run-all.sh` fails when `shellcheck` is not installed. It used to
  skip the lint step. It prints the versions of bash, gh, git, jq and flock
  first, and it runs every test with the bash that runs it.
- `prreview setup` no longer installs the background service by default. The
  question defaults to `n` while no service is installed, and to `y` once one
  is, so pressing Enter keeps what you have. A new service reviews every open
  PR in the listed repositories as soon as it starts, so installing it is now
  a choice. To install it later, run `prreview start`.
- The question that switches `gh` to `https` moved from the GitHub step to the
  service. It is asked only when `gh` clones over `ssh` and you answer `y` to
  the service question, or when `prreview start` installs the service from a
  terminal. The switch changes `gh` for all programs, so a user who answers
  `n` no longer sees it, and `gh config set` is not called. With no terminal
  on stdin, `prreview start` prints the `gh config set` command and goes on.
  It asks nothing when it starts a service that is installed.
- The reviewer reviews only PRs from a trusted author. A PR is trusted when it
  comes from a branch of the repository itself, when the author is in
  `PRREVIEW_GATE_TRUSTED_AUTHORS`, or when `prreview once --pr` names it. A PR
  from a fork is skipped otherwise, and nothing is posted on it. The round log
  names a skipped PR by number only. One `gh pr list` call now reads the
  number, the author, the fork flag and the labels, and the filter runs on that
  answer, so a skipped PR gets no call of its own, except the disarm of an
  armed auto-merge (see Security). The review job checks the
  rule again before any model call. A PR that `prreview once --pr` names needs
  only a whole number. Every other PR needs a number, a boolean fork flag, an
  author object and a non-empty login. If one is missing or has the wrong
  type, the PR is not trusted, even when its author is on the list. A PR whose
  author account was deleted can come back with no login. The reviewer then
  skips it, unless `prreview once --pr` names it. Set `PRREVIEW_GATE_FORK_PRS=1`
  to bring back the old behavior. A fork PR that was open before the upgrade
  keeps its earlier comment, and its new heads are skipped.
- `prreview once --pr` exits 0 only when the reviewer has a verdict (approve
  or request changes) on the current head, from this run or an earlier one.
  Before, it also exited 0 for a draft and for a PR that a check skipped,
  such as the title format check. Now it prints the reason and exits 75, the
  code of a lock that stays held. A PR that is not open still exits 1. A
  notice alone, such as the title format reminder, is not a verdict. It gives
  75 on every run.
- The loop starts a round only when an open PR passes the same rule. Before,
  it counted every open PR, so one fork PR left open started a round each
  minute, with the scan of merged PRs and up to ten reads each time. The count
  reads `PRREVIEW_GATE_TRUSTED_AUTHORS` and `PRREVIEW_GATE_FORK_PRS` from the
  same environment as the round, and it asks for up to 1000 PRs, as the round
  does. The count applies the same rule, so a PR with a missing field or a
  wrong type counts 0. A draft PR counts 0 too, because the round skips it.
  Only a boolean `isDraft` that is true makes a PR a draft. If the field is
  missing or has another type, the PR counts, and the round decides. The count
  asks for `isDraft` in the same `gh pr list` call. With
  `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, it asks for `autoMergeRequest` too, and
  a skipped fork PR with auto-merge armed counts as work. The round then runs
  within one interval and turns the auto-merge off. A list the loop cannot
  read counts as work. The scan of merged PRs does not look at the author. The
  count needs `jq`. If `jq` is
  missing, the loop stops at startup and names it, as it does for the timeout
  command.
- The reviewer finds `gtimeout` and `gsha256sum` on its own. At startup it uses
  `timeout` or `gtimeout` for deadlines. It uses `sha256sum`, `gsha256sum` or
  `shasum -a 256` for the review key digest, whichever it finds first. When only
  Homebrew's `g` names are on `PATH`, `prreview setup` on macOS no longer asks
  you to put the coreutils `gnubin` directory on `PATH`. A machine with
  coreutils missing but `shasum` present now passes the check too. The review
  key is the same through all three hash commands, so no open PR is reviewed
  again. If no timeout command or no hash command is found, the reviewer stops
  at startup and names the missing tool.
- Every PR now gets its convention files from the newest commit of the default
  branch. Before, a PR into the default branch got them at its merge base, and
  only a PR based on another branch got the default branch's. The files are
  `CLAUDE.md`, `AGENTS.md`, anything under `.claude/`, README, CONTRIBUTING and
  `.github/review-checks.md`, and now also `CLAUDE.local.md` and `.mcp.json`.
  The reviewer copies them after it applies the PR's diff, so a newer file on
  the default branch cannot make the diff fail. A file the default branch
  lacks is removed from the review tree, and a file only the default branch
  has is added. Names match in any letter case, so an edit to `readme.md` is
  reverted too. Before, only the exact case counted. A stacked PR that changes
  README is reviewed with its diff applied now. Before, it fell back to a
  review against the base branch. There is no switch to turn this off. An old
  branch is reviewed with today's rules, and a PR is reviewed again under new
  rules only when something else starts a new round. This is intended. A
  symlink from a convention file now needs a target that git tracks under
  any letter case of a convention name. The note to the model says that a path
  the default branch lacks is absent from the tree. The log line about the
  copy appears only when a convention file changed.

### Fixed

- With `PRREVIEW_GATE_VERIFY_LINES=1`, the line-number check failed on bash
  3.2, the bash that macOS ships. Bash 3.2 ended a command substitution at the
  `)` of a `case` pattern and printed a syntax error. The loop that counts the
  lines of each cited file now writes the pattern with a leading `(`. The check
  is off by default.

### Security

- The reviewer now scans the title and body of the issue a PR links against
  your sensitive patterns. The README already said so, but only the PR's own
  title and description were scanned, and the linked issue text reached the
  model without a scan. On a match, or when the scan cannot run, the reviewer
  posts a "Review withheld" notice that does not quote the value, and it does
  not review the PR. To get a new review, edit the issue, then push a commit
  or edit the PR description.

- A fork PR no longer reaches a model by default. Before, anyone who could
  open a PR on a watched repository made the reviewer read the diff and call
  the model, and each push to the PR or edit of its title or description
  started another call on the operator's account. Now the reviewer skips a fork
  PR unless the author is trusted or `prreview once --pr` names it. The rule
  assumes that everyone who can push to the repository is trusted. A
  repository whose workflows build branches from outside input breaks that
  assumption.
- With `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, the reviewer turns off an
  auto-merge that is armed on a PR it skips because of its author. Before, a
  skipped fork PR kept its auto-merge, and any approve could merge a head that
  nobody had reviewed. The round now asks for `autoMergeRequest` in the same
  `gh pr list` call. A skipped PR with armed auto-merge gets one
  `gh pr merge --disable-auto` call and no other call. A skipped PR without it
  gets none. Only a user with write access can arm auto-merge. The review job
  does the same when a PR turns into a fork PR after the list. A head that an
  earlier `prreview once --pr` reviewed also loses its auto-merge, because the
  list does not show that review.

## [0.2.2] - 2026-10-22

### Security

- A failed or partial `cat` while the reviewer built a slice could drop the
  hunks of one file. A large diff is split into slices, and each slice is
  built by joining part files. If `cat` failed to read or write one part,
  for example because the disk was full, the slice was shorter but not
  empty. The reviewer then reviewed a slice that lacked a file and gave a
  verdict on the whole diff. This needs a failed read or write of a scratch
  file. Now the reviewer keeps a slice only when every part is joined. If
  one slice is lost, it reviews the whole diff in one pass.
- A failed `jq` call could turn `request_changes` into `approve`. The
  reviewer counts blocking findings with `jq` before the citation check,
  before the line check and before the verdict rule. If one of those calls
  failed, the count was empty, and the shell reads an empty count as 0. A
  blocker that was dropped or not counted was then not seen, and a review
  with a blocker could be approved. This needs a `jq` failure at one of
  those steps. Now an empty count before the citation check counts as a
  dropped blocker. An empty count before the line check skips that check.
  An empty count in the final tally skips the PR and posts no review.
- A failed digest step could give a review key that matched earlier
  markers. The key is the head SHA, a dash and a 12-digit digest of the
  title, description and base branch. If `jq`, `sha256sum` or `cut` failed
  in the digest step, the key was the head SHA and a dash with no digest.
  The handled check matches the key as a fixed string, so it matched every
  marker posted for that head. The reviewer could then skip a PR whose
  title or description had changed. This needs a tool failure in the digest
  step. Now the reviewer prints no key unless the digest is 12 hex digits,
  and it skips the PR when there is no key.
- A slice plan or a part list that was cut short could drop part of a large
  diff from the review. The reviewer packs the parts of a large diff into
  slices, and it builds each slice from the part files its plan names. It
  did not check whether the packing step had failed. A packer that printed
  the first rows of the plan and then failed gave fewer slices, and those
  slices agreed with each other, so the count check passed. A part selector
  that printed some rows and then failed dropped a part in the same way. The
  reviewer then gave a verdict on the whole diff after it had read a part of
  it. This needs a failure of the packing step or of the awk call that
  selects the parts of a slice. Now the reviewer checks the status of both.
  It also checks that the plan holds every part of the diff once, in order.
  On any failure it reviews the whole diff in one pass.
- A review key without its head SHA could mark a later head as handled. The
  key is the head SHA, a dash and a 12-digit digest. A separate `jq` call
  reads the head SHA. If that call failed, the key was a dash and the
  digest. If the PR had no head field, the key began with the text `null`.
  The handled check does not match such a key against the marker of a head
  that has its SHA. It does match a marker the reviewer posted under the
  same fault, and a later head with the same title, description and base
  branch was then not reviewed. This needs a failed or empty read of the head
  in two rounds. Now the reviewer prints no key unless the head is 40
  lowercase hex digits, and it skips the PR when there is no key.

## [0.2.1] - 2026-10-21

### Changed

- gh 2.63.0 or later is now required. The reviewer reads `baseRefOid` with
  `gh pr view --json`, and gh 2.63.0 is the first release that lists it. The
  reviewer and `prreview setup` check `gh --version` and refuse an older gh
  with a message that names both versions.
- Alert issues in `PRREVIEW_ALERT_REPO`, and their "Still failing" comments,
  now record the time in UTC.
- The README and SECURITY.md state the limits of their claims more precisely,
  and the README warns that the first run reviews every open non-draft PR.
- The reviewer requires Claude Code 2.1.305 or later. It checks
  `claude --version` at startup and does not run on an older version, and
  `prreview setup` checks it too. Before 2.1.295, `--tools` did not apply to
  tools that register after launch, and 2.1.304 fails every request on
  Vertex, Bedrock and gateways with this tool set. To upgrade, see Upgrading
  in the README.
- A round now skips a PR, and tries it again next round, when its merge base
  cannot be found, when its diff cannot be fetched, or when the diff is
  incomplete. v0.2.0 reviewed the PR without applying the diff to the tree
  when the merge base was missing.
- After the upgrade, each open PR based on another branch gets one more
  review, because its review key now holds the base commit. A PR into the
  default branch keeps its key and is not reviewed again.

### Fixed

- Findings now cite the line in the changed file, not a line of the diff. The
  review, red-team and output-repair prompts never said which line number the
  `line` field means. In an end-to-end check, a model that had Read the diff
  file cited that file's line numbers, for example `db.py:35` where the code
  was at line 43. The prompts now say it: the line number on the new side of
  the cited file, counted from the hunk header. A number that Read shows is
  used only when the file on disk is the version after the change. That is
  not so when the diff did not apply, or for a convention file the reviewer
  restored. For a deleted line the model uses the nearest line that still
  exists, and for a deleted file it uses 0.
- The red-team and refutation prompts now describe the review tree with the
  same text as the main review. Each used to choose its own text from one
  fact, whether the diff applied. For a PR based on another branch, the tree
  is that branch, and those texts were then wrong whether or not the diff
  applied. Both now also get the note about convention files the reviewer
  restored.
- A PR that changes no files is skipped with a log line that says so. v0.2.0
  skipped it too. The new diff fetch for the exact head commit read the empty
  diff of such a PR as a diff it could not read.
- The review prompt now says how a PR based on another branch gets its
  convention files. The reviewer replaces each convention file that the tree
  already tracks with the version on the newest commit of the default branch.
  It removes a file that the default branch does not have. It does not add a
  file that only the default branch has. The prompt said that every
  convention file came from the default branch. The reviewer now skips the PR,
  and tries it again next round, when a replacement step fails: the file
  list, the read of the file list of the default branch, the checkout of a
  file, the removal of a file from the index, or the removal of a file from
  the review tree. A failed read of the default branch no longer counts as a
  file that the default branch does not have, so it removes no file. Before,
  such a failure went unnoticed and the review went on.
- The round task for round 2 and later now names the exception to its delta
  limit. A file with a prior line "N more finding(s) on this file" is
  searched in full, also when the delta does not touch it. The task said both
  that such a file is not searched and that it is searched in full.
- The reviewer no longer skips every stacked PR on a host without GNU grep,
  such as macOS with its default tools. The step that replaces convention
  files looked a path up with `grep -z`, which only GNU grep has. It now
  compares the paths in Bash 3.2 itself. A file name with a newline is now
  compared as a whole, and a file list that ends in the middle of a name
  skips the PR.

### Security

- The reviewer now sets the model's tools explicitly. Every review,
  refutation and red-team call gets `--tools "Read,Grep,Glob"`, and the
  output-repair call gets no tool. v0.2.0 set only path rules on top of
  Claude Code's defaults, so `Bash` was in the tool set. In a check on
  Claude Code 2.1.305, the shell commands `ls`, `cat`, `git log` and
  `git show` ran inside the review clone without a rule, and shell commands
  that named a path outside the clone were refused.
- Every call also turns off MCP servers (`--strict-mcp-config`,
  `--disallowedTools "mcp__*"`, `ENABLE_CLAUDEAI_MCP_SERVERS=false`), skills
  and slash commands (`--disable-slash-commands`) and auto memory
  (`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`).
- Every call also gets `--restricted`, so Claude Code itself confines the
  file tools to the review clone and to private directories for that call.
  Each directory holds only the call's diff or slice, or the PR's title and
  description, so no call can read another pull request's scratch files or
  another slice's scratch diff. A slice review can still read every source
  file in the review clone.
- Every prompt now goes to Claude Code on stdin. Before, the refutation,
  red-team and repair prompts were on the command line, where other users of
  the same machine could read them in the process list. Those prompts quote
  finding text and code from the pull request.
- As defense in depth, the `claude` process starts with `GH_TOKEN`,
  `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN` and `GITHUB_ENTERPRISE_TOKEN` empty.
- The reviewed diff is now fetched for the exact head commit the verdict
  names. Before, the diff, the list of changed files and the head SHA in the
  verdict marker were read in separate calls. If the author force-pushed
  during a round, the verdict and its marker could name a head the model never
  reviewed. The file list now comes from the same diff, and a diff with a
  different number of files than GitHub reports for the PR is not reviewed.
- The merge base now comes from the two commit IDs in one read of the PR: its
  base commit and its head commit. Before, it came from the base branch name
  in a later call, so a push to the base branch between the two calls could
  change the comparison. A PR based on another branch is now reviewed again
  when its parent branch moves, because its review key now holds the base
  commit. SECURITY.md lists the limit that stays for a PR into the default
  branch.

## [0.2.0] - 2026-10-12

### Added

- First public version. `pr-autoreview.sh` reviews every new head of every
  open pull request in the repos listed in `PRREVIEW_GATE_REPOS` with headless
  Claude Code, and posts one comment per head. It never approves or merges,
  and it leaves auto-merge alone unless `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`.
- `review-loop.sh` runs a round once a minute while any listed repo has an
  open pull request.
- `sensitive-patterns.example`, a starting list of secret patterns for the
  required sensitive-data scan.
- `prreview`, the setup and control command. `prreview setup` walks through
  the tools, the GitHub login, the repositories, how many PRs to review at
  once, the model, the sensitive-data patterns and the checklist, then
  installs the loop as a launchd agent (macOS) or a systemd user service
  (Linux, WSL2). `prreview repos`, `prreview set`, `prreview checks`,
  `prreview status` and `prreview logs` cover day-to-day changes.
- Posting as a GitHub App. `prreview setup` links to a pre-filled App
  registration page, stores the App's key privately, and checks the App can
  see every listed repository; comments then come from `<app-name>[bot]`. Set
  with `PRREVIEW_REVIEW_APP_ID` and `PRREVIEW_REVIEW_APP_KEY`; the App's name
  is read from GitHub every round.
- `checks/`, the review checklist as one Markdown file per item. Add a file
  to add an item, delete one to drop it; `applies_to` front matter limits an
  item to PRs that change matching files.
- The README documents these settings: `PRREVIEW_GATE_HOLDOFF_DIR`,
  `PRREVIEW_GATE_REDTEAM_SPEC_MAX`, `PRREVIEW_GATE_LOCK`,
  `PRREVIEW_STATE_DIR` and `PRREVIEW_GATE_CURSOR`.
- The default models are `claude-opus-5-5` for the review, the refutation
  pass and the red team, and `claude-sonnet-5-5` for repairing unparseable
  output. `PRREVIEW_REVIEW_MODEL` and `PRREVIEW_GATE_CHEAP_MODEL` set other
  models.
- The review rules in `checks/02b`, `03` and `10`, and the first rule in
  `checks/02`, cite the OWASP, CWE, RFC and MCP texts.
- `checks/09` covers a change to a heuristic, a limit, a model choice or a
  prompt.
- `checks/03` accepts as placeholders the ranges and names reserved for
  documentation: RFC 5737 and RFC 3849 addresses, RFC 9542 MAC addresses,
  and the RFC 2606 and RFC 6761 domains. A host address from the RFC 1918
  private ranges is a finding, except in code that handles private addresses
  and its tests.
- The severity calibration in the review prompt sets the HIGH case to a
  realistic input that gets a wrong result, or valid input that is rejected.
  When HIGH or MEDIUM is unclear, wrong output goes to HIGH.
- A finding that a round carries into the next round is copied verbatim.
- A doc finding on a `README` or `CONTRIBUTING` file, an `.env.example` file
  or a file under `docs/` always counts as one that everyone reads, not only
  maintainers. A doc finding on any other file keeps the reader the model
  gave it.

[Unreleased]: https://github.com/nagameTW/pr-reviewer/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/nagameTW/pr-reviewer/releases/tag/v0.2.2
[0.2.1]: https://github.com/nagameTW/pr-reviewer/releases/tag/v0.2.1
[0.2.0]: https://github.com/nagameTW/pr-reviewer/releases/tag/v0.2.0
