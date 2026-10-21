# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/nagameTW/pr-reviewer/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/nagameTW/pr-reviewer/releases/tag/v0.2.0
