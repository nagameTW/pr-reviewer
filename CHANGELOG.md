# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The README documents five settings that already existed:
  `PRREVIEW_GATE_HOLDOFF_DIR`, `PRREVIEW_GATE_REDTEAM_SPEC_MAX`,
  `PRREVIEW_GATE_LOCK`, `PRREVIEW_STATE_DIR` and `PRREVIEW_GATE_CURSOR`.

### Changed

- The default models are now `claude-opus-5-5` for the review, the refutation
  pass and the red team, and `claude-sonnet-5-5` for repairing unparseable
  output. Set `PRREVIEW_REVIEW_MODEL` and `PRREVIEW_GATE_CHEAP_MODEL` to keep
  `claude-opus-5` and `claude-sonnet-5`.
- The review rules in `checks/02b`, `03` and `10`, and the first rule in
  `checks/02`, are rewritten from the public OWASP, CWE, RFC and MCP text
  they cite.
- `checks/09` is rewritten. It covers a change to a heuristic, a limit, a
  model choice or a prompt.
- `checks/03` now accepts as placeholders only the ranges and names reserved
  for documentation: RFC 5737 and RFC 3849 addresses, RFC 9542 MAC
  addresses, and the RFC 2606 and RFC 6761 domains. A host address from the
  RFC 1918 private ranges is a finding, except in code that handles private
  addresses and its tests.
- The severity calibration in the review prompt is reworded. Its HIGH case
  is a realistic input that gets a wrong result, or valid input that is
  rejected. When HIGH or MEDIUM is unclear, wrong output now goes to HIGH;
  before, that tie-break covered anything that feeds a result users act on.
- Parts of the review, red-team and repair prompts are reworded. A carried
  finding is still copied verbatim.
- A doc finding on a `README` or `CONTRIBUTING` file, an `.env.example` file
  or a file under `docs/` always counts as one that everyone reads, not only
  maintainers. A doc finding on any other file keeps the reader the model
  gave it.

## [0.1.0] - 2026-09-27

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

[Unreleased]: https://github.com/nagameTW/pr-reviewer/commits/main
