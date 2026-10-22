# pr-reviewer

English | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml/badge.svg)](https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/nagameTW/pr-reviewer?style=flat-square&logo=opensourceinitiative&logoColor=white&color=3DA639)](./LICENSE)
[![bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-4EAA25)](#requirements)

**A pull-request reviewer that runs on your own machine with your own Claude
Code login. No GitHub Action, no App, no webhook, no repo admin.**

It watches the repos you list. For every new head of every open PR from a
[trusted author](docs/operations.md#whose-prs-it-reviews), it asks headless
[Claude Code](https://code.claude.com/docs/en/overview) for a review, checks
what comes back, and posts one comment with a verdict and the findings.
Comments are posted as your own `gh` account unless you set up a
[GitHub App](docs/github-app.md). It is plain bash on top of `gh`, `git`, `jq`
and `claude`. A loop polls once a minute.

- **It only comments.** It never submits a GitHub approval, never requests
  changes as a formal review, and never merges.
- **The model can only read.** `--tools` limits Claude Code to `Read`, `Grep`
  and `Glob` in a per-PR worktree. It has no shell and no web tools, and your
  code is never run.
- **The default branch sets the rules.** `CLAUDE.md`, `AGENTS.md` and the
  repo's other convention files come from the newest commit of the default
  branch, so a PR cannot loosen its own review.
- **It argues against its own blockers.** Each blocking finding, up to six a
  round, gets a second call that tries to refute it. This lowers false alarms.
- **It holds back when a step fails.** An answer it cannot parse or scan is
  not posted. A repaired answer never approves.

<p align="center">
  <img src="docs/images/demo.gif" alt="A terminal runs prreview once on a test PR. The log shows three blocking findings, a CRITICAL SQL injection and two HIGH findings, each upheld by a refutation call with its reason, and a comment posted with verdict request_changes for $0.54. The PR comment shows Changes requested, 3 blocking, with the CRITICAL finding opened to its trace and its citation A05:2025 Injection, CWE-89. After a commit that binds the search term as a parameter, round 2 posts Changes requested, 1 blocking: two of the three findings are fixed and the paging finding is marked Carried over. After a commit that makes pages 1-based, round 3 posts Approved." width="100%">
</p>

The demo is one real run on a test PR (Run A), with the waits cut out: three
pushes, three rounds, and an approval in round 3.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.svg">
  <img src="docs/images/overview.svg" alt="Architecture of pr-reviewer. It runs on your machine. The review loop starts a round once a minute while a pull request is open. A round reads open PRs from GitHub through gh, builds a per-PR worktree, and sends a prompt to Claude Code. Claude Code has only the tools Read, Grep and Glob. A round matches PR text and each comment against your sensitive-patterns file. It posts one comment for each new head. Fork PRs from authors you do not trust are skipped by default. The reviewer never approves or merges." width="100%">
</picture>
</p>

## Trust and cost

**Trust.** [SECURITY.md](SECURITY.md) has the full security model.

- **Run it on a machine only you use.** The service runs as your user with your
  `gh` and Claude Code logins and, if you set one up, a GitHub App's key.
  Anyone who can act as that user can post as you.
- **It reviews three kinds of PR:** a PR from a branch of the repo itself, a PR
  by a login in `PRREVIEW_GATE_TRUSTED_AUTHORS`, and a PR you name with
  `prreview once --pr`. It skips every other fork PR and posts nothing on it.
- **PR text is data.** The prompt says so. That is an instruction to the
  model, not a sandbox. The tool limits above hold if the model is fooled, and
  they need Claude Code 2.1.305 or later.
- **Every comment that carries PR text or model output is scanned** against
  your sensitive-patterns file before it is posted. A hit, or a scan that
  cannot run, replaces the comment with a short notice that does not quote the
  value.
- **It posts what the model wrote.** If a bot in your repo acts on comment
  commands such as `/lgtm` or `bors r+`, post as a GitHub App that the bot does
  not take commands from.
- **It uses your Claude Code login.** Whether an always-on reviewer counts as
  ordinary individual use of a subscription is Anthropic's call, and its terms
  have changed before. Read the current terms. An API key avoids the question,
  but a key set in your shell does not reach the background service. Run
  `prreview run` from a terminal that has the key
  ([details](docs/operations.md#where-to-run-it)).

**Cost.**

- Every push to the PR starts a new round at once. So does an edit of the PR's
  title, description or base branch, and a push to the parent branch of a
  stacked PR. When the head is unchanged, those last two cases wait until the
  reviewer's last comment is 10 minutes old (`PRREVIEW_GATE_PR_COOLDOWN_MIN`).
- One round can make one review call per slice (up to 8 slices, two passes
  each in a first round on a diff of 1000 lines or more or on a split-exempt
  PR), one refutation call per blocking finding (up to 6), and one repair
  call. The largest first round makes 16 review, 6 refutation and 1 repair
  calls. No test run has covered that case, so its cost is unknown.
- Round 1 of the demo cost $0.54, and the three rounds cost $1.14 (Run A). A
  second test PR cost $0.75, then $0.73 for a push that changed nothing (Run
  B). On a small clean PR, the red team added $0.23 to a $0.34 review (Run C).
  These runs were in September and October 2026, before v0.2.0 changed the
  default models, so they do not describe the current defaults. The dollar
  figure is what `claude -p` reports. On a subscription it counts against your
  usage limits instead of a bill.

## Status and limits

- **Pre-1.0.** Anything can change between versions. Read
  [CHANGELOG.md](CHANGELOG.md) before you upgrade.
- **Detection rate is unknown.** No one has counted how many bugs it finds or
  how many false alarms it raises.
- **It reads code and nothing else.** It does not run your tests or read your
  CI results. A verdict is a comment, not a GitHub review state. The Approved
  banner says "Automated review, not a GitHub approval."
- **GitHub only, and only while the machine is awake.** It pauses while the PC
  sleeps. CI runs the tests on Ubuntu with its system bash and on macOS with
  `/bin/bash` (bash 3.2). WSL2 is not in CI and is checked only on the
  maintainer's own machine
  ([docs/windows.md](docs/windows.md)). Bedrock, Vertex and gateways are not
  tested.
- **One known gap.** The review key of a PR into the default branch does not
  include the base commit ([Known limits](SECURITY.md#known-limits)).
- **A poor fit** for a Claude login shared by several people, for a required
  check that must block a merge, and for code that may not go to Anthropic.

How it differs from other tools: [docs/comparison.md](docs/comparison.md).

## Requirements

- **macOS or Linux.** On Windows it runs inside WSL2.
- **bash 3.2 or newer.** The `/bin/bash` that macOS ships works.
- **[gh](https://cli.github.com/) 2.63.0 or later** and
  **[Claude Code](https://code.claude.com/docs/en/overview) 2.1.305 or later**
  (`claude update` installs the latest), both logged in.
- `git`, `jq`, `curl`, `openssl` and `flock`, one timeout command (`timeout` or
  `gtimeout`), and one SHA-256 command (`sha256sum`, `gsha256sum` or
  `shasum`). The scripts use the first they find.
- **On Linux, systemd 240 or newer** for the background service, which writes
  its log with `StandardOutput=append:`.

`prreview setup` checks every item and prints the install command for your
system. On macOS with Homebrew: `brew install git jq gh coreutils flock`. On
Debian or Ubuntu: `sudo apt install git jq curl openssl util-linux coreutils`,
then install `gh` from
[GitHub's package repository](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).

## Quick start

### 1. Get the code

```bash
git clone https://github.com/nagameTW/pr-reviewer.git ~/pr-reviewer
mkdir -p ~/.local/bin && ln -s ~/pr-reviewer/prreview ~/.local/bin/prreview
```

Keep the clone out of `~/Documents`, `~/Desktop`, `~/Downloads` and iCloud
Drive (`~/Library/Mobile Documents`), which a macOS background service cannot
read. Put `~/.local/bin` on your
`PATH` if it is not there.

### 2. Run the setup

```bash
prreview setup
```

It asks one question at a time, and Enter keeps the value in brackets. It
checks your tools and your `claude` and `gh` logins, then asks for the repos to
review (it lists up to 30 of your own; type `owner/repo` for any other, and
list one that you own), who posts, the model and more. At **Background
service**, answer `n` for now. The answers go to
`~/.config/pr-reviewer/config`.

### 3. Review one test PR

Open a small PR from a branch of a repo you listed, then run:

```bash
prreview once --pr you/repo#12
```

This makes real model calls and posts a comment as your `gh` account. Exit code
`0` means the reviewer has a verdict on the current head. `75` means no verdict
and nothing failed, for example a draft PR. `1` means the PR is not open or
could not be read.

### 4. Start the service

> [!WARNING]
> The first round reviews every open non-draft PR from a trusted author in each
> listed repo, and comments on each as your `gh` account. Each review costs
> model usage. Until you trust it, list only repos that you own.

```bash
prreview start
prreview status
prreview logs -f
```

If `gh` clones over `ssh`, `prreview start` offers to switch `gh` to `https`,
because a systemd user service has no ssh-agent
([details](docs/operations.md#where-to-run-it)). With no PR to review, the loop
starts a round only on every 15th check. On
Linux, systemd stops a user service when you log out; run
`sudo loginctl enable-linger "$USER"` once to keep it running. On WSL2 the
service needs `systemd=true` and stops when WSL shuts down; see
[docs/windows.md](docs/windows.md).

## Everyday commands

| Command | What it does |
| --- | --- |
| `prreview repos add owner/repo`, `prreview repos remove owner/repo` | Change the repos under review |
| `prreview set <name> <value>`, `prreview get <name>`, `prreview unset <name>` | Change, read or reset a setting |
| `prreview once`, `prreview run` | One round, or the loop, in this terminal |
| `prreview once --pr owner/repo#12` | Review that one PR now, a fork PR included |
| `prreview stop`, `prreview start`, `prreview restart` | Control the background service |
| `prreview status`, `prreview logs -f` | Show the state and skipped PRs; follow the log |
| `prreview checks` | List, add or remove review items |
| `prreview uninstall` | Remove the background service; settings stay |

A command that changes a setting restarts the service. To remove everything,
see [docs/operations.md](docs/operations.md#removing-it).

## Upgrading

```bash
cd ~/pr-reviewer
git pull --ff-only
prreview setup
```

Press Enter through the questions to keep your answers. At the Checklist step,
answer `y` to take new built-in items; Enter declines. Setup restarts the
service, because the loop keeps running the old code until it restarts. If
`claude --version` or `gh --version` is older than the minimum, setup stops.
Update the tool and run setup again.

In versions after 0.2.0, the reviewer skips fork PRs unless the author is in
`PRREVIEW_GATE_TRUSTED_AUTHORS`. `prreview status` shows how many it
skipped. `PRREVIEW_GATE_FORK_PRS=1` brings back the old behavior.

Items in your copy of the checklist keep their old wording. To see what a new
version changed in them, run
`diff -r ~/pr-reviewer/checks ~/.config/pr-reviewer/checks`.

## How a review works

<p align="center">
  <img src="docs/images/example-comment.png" alt="A review comment: a Changes requested banner counting 2 blocking and 1 not blocking findings, a one-line summary, a CRITICAL SQL injection finding opened to show its trace from input to sink and its citation A05:2025 Injection, CWE-89, and a HIGH paging finding. The rest of the summary, the MEDIUM finding and what the review could not verify are folded." width="820">
</p>

This comment is from Run B. The comment leads with the verdict and one line
per finding. Every finding names a file, a line and a fix. Every slice is
reviewed against the same checklist of 13 items, one file each in `checks/`.
The Applies column says when an item is used. Each finding names its item and
a severity.

| Item | Looks for | Applies |
| --- | --- | --- |
| 1 Correctness | Bugs, unhandled inputs, broken callers, concurrency faults | Always |
| 2 Security | Injection, authorization gaps, crypto and secrets, data exposure | Always |
| 2b AI-agent security | Prompt injection, unchecked model output, excess agency | The diff sends content to an LLM, gives it tools, or acts on its output |
| 3 Sensitive data | Real addresses, host names, tokens or credentials | Always |
| 4 Project constraints | Rules the repo wrote down for itself | Always |
| 5 Tests | CI weakened, a bug fix with no test, weak assertions | Always |
| 6 Design | Over-engineering, a change in the wrong place | Always |
| 7 Doc sync | Docs that still describe the old behavior | Always |
| 8 Dependencies | A dependency that is not declared or not pinned like the rest | Always |
| 9 Evidence-first | A heuristic, limit, model choice or prompt change with no measurement | The diff changes one of these |
| 10 Tool surface | Tools a model can call that are too broad or need no approval | The diff defines or changes such tools |
| 11 Acceptance | A requirement of the linked issue that the diff does not deliver | The PR links an issue |
| 12 Half-fixes | The same defect still present in a sibling | Always |

Not reported: denial of service (except a call with no timeout), memory safety
in a memory-safe language, vulnerabilities with no exploit path, style that a
linter enforces, praise. CRITICAL and HIGH findings block, and MEDIUM and LOW
are listed without blocking. "Block" only decides the verdict text. You can
[add, remove or change items](docs/configuration.md#adding-your-own-checks).
The full list of checks and severity rules is in
[docs/how-it-reviews.md](docs/how-it-reviews.md).

One round has seven steps. The first four make no model call.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/round-dark.svg">
  <img src="docs/images/round.svg" alt="Flowchart of one review round in seven steps. Steps 1 to 4 make no model call. 1 Pick: open PRs with no comment for the current head. Fork PRs from untrusted authors are skipped. If the head is unchanged and the reviewer's last comment is under 10 minutes old, the round waits. A title, description or base edit, or a push to the parent branch of a stacked PR, can cause this wait. A push to the PR branch never waits. 2 Scan: the title, description and linked issue are matched against your sensitive-patterns file. On a match, or if the scan cannot run, a Review withheld notice is posted without the value and the PR is not reviewed. 3 Build: merge base plus PR diff, then convention files from the default branch. More than 2000 changed lines or 40 files gets a split request and no review, unless the PR is exempt. 4 Slice: slices of about 250 lines, up to 8. 5 Review: Claude Code reads the worktree. 6 Verify: findings that cite a missing file are dropped. One call for each blocking finding tries to refute it. 7 Post: model text is escaped, the comment is matched against your sensitive-patterns file, and one comment is posted. Output that cannot be parsed is not posted." width="100%">
</picture>
</p>

Every push is a new round. The prompt asks the model to mark each earlier
blocker as fixed or to repeat it with the prefix `Carried over:`. The harness
does not check that the model does this.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/rounds-dark.svg">
  <img src="docs/images/rounds.svg" alt="State diagram of one finding across rounds. Each push starts a new round. A new CRITICAL or HIGH finding is blocking. On the next push the model marks it fixed, or repeats it with the prefix Carried over. A carried-over finding still blocks. It stays carried over until the model marks it fixed. A new HIGH finding on a file that the push did not change, and that no earlier round cited, is shown as MEDIUM. It does not block and is not carried over. CRITICAL is never lowered. The harness does not check that the model marks findings correctly. A round with no blocking findings posts Approved. A PR that is merged while its verdict is changes requested gets one alert comment." width="100%">
</picture>
</p>

An optional red team argues against an approval. It is off by default, because
it adds cost and time to every approval. `prreview set PRREVIEW_GATE_REDTEAM 1`
turns it on.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/redteam-dark.svg">
  <img src="docs/images/redteam.svg" alt="Flowchart of the optional red team. A round has no blockers and is about to approve. One more call argues that the approval is wrong. It looks for parts of the diff that disagree, a limit at the wrong level, an error returned as success, a branch that decides from other input, and a rule the repo's own docs pin. If the call fails or times out, the approval stands. If there is no CRITICAL or HIGH candidate, the approval stands. Up to 3 candidates each go through one refutation call. A refuted candidate is dropped and the approval stands. A survivor is posted and marked raised by the red team. The red team is off by default. The command prreview set PRREVIEW_GATE_REDTEAM 1 turns it on." width="100%">
</picture>
</p>

What happens when a step fails, and what each step does in detail:
[docs/operations.md](docs/operations.md).

## Settings

Settings are a config file plus overrides. The file is
`~/.config/pr-reviewer/config`, one `KEY=value` per line, and `prreview set`
writes it. A variable set in the environment overrides the file. Two settings
are required: `PRREVIEW_GATE_REPOS` and `PRREVIEW_SENSITIVE_PATTERNS_FILE`,
the sensitive-patterns file that `prreview setup` writes. The ones people
change most are
`PRREVIEW_GATE_TRUSTED_AUTHORS`, `PRREVIEW_GATE_FORK_PRS`,
`PRREVIEW_REVIEW_MODEL`, `PRREVIEW_GATE_PARALLEL`,
`PRREVIEW_GATE_PR_COOLDOWN_MIN`, `PRREVIEW_GATE_REDTEAM`,
`PRREVIEW_GATE_TICKETS` and `PRREVIEW_ALERT_REPO`. See
[docs/configuration.md](docs/configuration.md) for every setting and its
default, [docs/operations.md](docs/operations.md) for one round in detail and
for failures, [docs/github-app.md](docs/github-app.md) for posting as an App,
and [docs/windows.md](docs/windows.md) for WSL2.

## Development

```bash
bash tests/run-all.sh
```

That runs `bash -n`, `shellcheck -S warning` and every `tests/*.test.sh`, with
no network, no `gh` and no model. It fails when `shellcheck` is not installed.
Run it in a `git clone`, because the checks list the scripts with
`git ls-files` and a ZIP download stops there. CI runs the same command on Ubuntu and on
macOS. See [CONTRIBUTING.md](CONTRIBUTING.md). The project puts predictable
review behavior ahead of review breadth.

## License

[MIT](LICENSE)
