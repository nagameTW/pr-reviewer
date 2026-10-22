# pr-reviewer

English | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml/badge.svg)](https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/nagameTW/pr-reviewer?style=flat-square&logo=opensourceinitiative&logoColor=white&color=3DA639)](./LICENSE)
[![bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-4EAA25)](#requirements)

**pr-reviewer reviews pull requests on your own machine, with your own Claude
Code login. It needs no GitHub Action, no App, no webhook and no repo admin
rights.**

It watches the repos you list. It reviews each new head of each open PR from a
[trusted author](docs/operations.md#whose-prs-it-reviews). The head is the
latest commit of the PR. For each new head, it asks headless
[Claude Code](https://code.claude.com/docs/en/overview) for a review. Headless
means Claude Code runs without a screen. The reviewer checks what comes back.
Then it posts one comment with a verdict and the findings.

Comments come from your own `gh` account. If you set up a
[GitHub App](docs/github-app.md), they come from the App. The tool is plain
bash on top of `gh`, `git`, `jq` and `claude`. A loop checks GitHub once a
minute.

- **It only comments.** It never submits a GitHub approval. It never requests
  changes as a formal review. It never merges.
- **The model can only read.** `--tools` limits Claude Code to `Read`, `Grep`
  and `Glob` in a worktree for each PR. A worktree is a separate working
  directory of git. The model has no shell and no web tools. Your code never
  runs.
- **The default branch sets the rules.** `CLAUDE.md`, `AGENTS.md` and the other
  convention files come from the newest commit of the default branch. A PR cannot loosen its own review.
- **It argues against its own blockers.** A second call tries to refute each
  blocking finding, up to six in a round. This lowers false alarms.
- **It holds back when a step fails.** It does not post an answer that it
  cannot parse or scan. A repaired answer never approves.

<p align="center">
  <img src="docs/images/demo.gif" alt="A terminal runs prreview once on a test PR. The log shows three blocking findings. One is a CRITICAL SQL injection and two are HIGH. A refutation call upholds each one and gives its reason. The reviewer posts a comment with verdict request_changes. The run costs $0.54. The PR comment shows Changes requested, 3 blocking. The CRITICAL finding is open and shows its trace and its citation A05:2025 Injection, CWE-89. A commit then binds the search term as a parameter. Round 2 posts Changes requested, 1 blocking. Two of the three findings are fixed. The paging finding is marked Carried over. A commit then makes pages 1-based. Round 3 posts Approved." width="100%">
</p>

The demo shows one real run on a test PR (Run A). The waits are cut out. The
run has three pushes and three rounds. Round 3 approves.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.svg">
  <img src="docs/images/overview.svg" alt="Architecture of pr-reviewer. It runs on your machine. The review loop starts a round once a minute while a pull request is open. A round reads open PRs from GitHub through gh. It builds a worktree for each PR. It sends a prompt to Claude Code. Claude Code has only the tools Read, Grep and Glob. A round matches PR text and each comment against your sensitive-patterns file. It posts one comment for each new head. By default, it skips fork PRs from authors you do not trust. The reviewer never approves or merges." width="100%">
</picture>
</p>

## Trust and cost

**Trust.** [SECURITY.md](SECURITY.md) has the full security model.

- **Run it on a machine only you use.** The service runs as your user. It uses
  your `gh` login and your Claude Code login. It also uses the key of a GitHub
  App, if you set one up. Anyone who can act as that user can post as you.
- **It reviews three kinds of PR:**
  - A PR from a branch of the repo itself.
  - A PR by a login in `PRREVIEW_GATE_TRUSTED_AUTHORS`.
  - A PR that you name with `prreview once --pr`.

  It skips every other fork PR. It posts nothing on a skipped PR.
- **PR text is data.** The prompt says so. That is an instruction to the
  model. It is not a sandbox. The tool limits above hold if the model is
  tricked. They need Claude Code 2.1.305 or later.
- **Every comment that carries PR text or model output is scanned** against
  your sensitive-patterns file before the reviewer posts it. If the scan finds
  a match, or cannot run, a short notice replaces the comment. The notice does
  not quote the value.
- **It posts what the model wrote.** Your repo can have a bot that acts on
  comment commands such as `/lgtm` or `bors r+`. In that case, post as a GitHub
  App that the bot does not take commands from.
- **It uses your Claude Code login.** Anthropic's
  [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance)
  says the advertised Pro and Max limits "assume ordinary, individual usage".
  The page gives no number (read 2026-10-21). Anthropic decides whether an
  always-on poller counts. An API key avoids the question. But a key set in
  your shell does not reach the background service. Run `prreview run` from a
  terminal that has the key ([details](docs/operations.md#where-to-run-it)).

**Cost.**

- Every push to the PR starts a new round at once. An edit of the PR title,
  description or base branch also starts a round. So does a push to the parent
  branch of a stacked PR. When the head is unchanged, these last two cases wait
  until the last comment of the reviewer is 10 minutes old
  (`PRREVIEW_GATE_PR_COOLDOWN_MIN`).
- One round can make these model calls:
  - One review call for each slice. A slice is a part of the diff of about 250
    lines. A round has up to 8 slices.
  - A second review call for each slice. This happens in a first round on a
    diff of 1000 lines or more, and on a split-exempt PR.
  - One refutation call for each blocking finding, up to 6.
  - One repair call.

  The largest first round makes 16 review calls, 6 refutation calls and 1
  repair call. No test run has covered that case. Its cost is unknown.
- Round 1 of the demo cost $0.54. The three rounds cost $1.14 (Run A). A second
  test PR cost $0.75. A push that changed nothing then cost $0.73 (Run B). On a
  small clean PR, the red team added $0.23 to a $0.34 review (Run C). These runs
  took place in September and October 2026. Version 0.2.0 later changed the
  default models. The figures do not describe the current defaults. The dollar
  figure is what `claude -p` reports. On a subscription, it counts against your
  usage limits and not against a bill.

## Status and limits

- **Pre-1.0.** Anything can change between versions. Read
  [CHANGELOG.md](CHANGELOG.md) before you upgrade.
- **Detection rate is unknown.** No one has counted how many bugs it finds. No
  one has counted how many false alarms it raises.
- **It reads code and nothing else.** It does not run your tests. It does not
  read your CI results. A verdict is a comment and not a GitHub review state.
  The Approved banner says "Automated review, not a GitHub approval."
- **GitHub only, and only while the machine is awake.** It pauses while the PC
  sleeps. CI runs the tests on Ubuntu with its system bash. CI runs them on
  macOS with `/bin/bash` (bash 3.2). WSL2 is not in CI. Only the maintainer's
  own machine checks it ([docs/windows.md](docs/windows.md)). Bedrock, Vertex
  and gateways are not tested.
- **One known gap.** The review key of a PR into the default branch does not
  include the base commit ([Known limits](SECURITY.md#known-limits)).
- **A poor fit in three cases:**
  - Several people share one Claude login.
  - You need a required check that blocks a merge.
  - The code may not go to Anthropic.

[docs/comparison.md](docs/comparison.md) compares it with other tools.

## Requirements

- **macOS or Linux.** On Windows, it runs inside WSL2.
- **bash 3.2 or newer.** The `/bin/bash` that macOS ships works.
- **[gh](https://cli.github.com/) 2.63.0 or later** and
  **[Claude Code](https://code.claude.com/docs/en/overview) 2.1.305 or later**.
  Both must be logged in. `claude update` installs the latest Claude Code.
- `git`, `jq`, `curl`, `openssl` and `flock`. Also one timeout command
  (`timeout` or `gtimeout`) and one SHA-256 command (`sha256sum`, `gsha256sum`
  or `shasum`). The scripts use the first one they find.
- **On Linux, systemd 240 or newer** for the background service. The service
  writes its log with `StandardOutput=append:`.

`prreview setup` checks every item. It prints the install command for your
system. On macOS with Homebrew, run `brew install git jq gh coreutils flock`.
On Debian or Ubuntu, run
`sudo apt install git jq curl openssl util-linux coreutils`. Then install `gh`
from
[GitHub's package repository](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).

## Quick start

### 1. Get the code

```bash
git clone https://github.com/nagameTW/pr-reviewer.git ~/pr-reviewer
mkdir -p ~/.local/bin && ln -s ~/pr-reviewer/prreview ~/.local/bin/prreview
```

Keep the clone out of `~/Documents`, `~/Desktop`, `~/Downloads` and iCloud
Drive (`~/Library/Mobile Documents`). A macOS background service cannot read
these folders. If `~/.local/bin` is not on your `PATH`, add it.

### 2. Run the setup

```bash
prreview setup
```

It asks one question at a time. Press Enter to keep the value in brackets. It
checks your tools and your `claude` and `gh` logins. Then it asks for the repos
to review. It lists up to 30 of your own repos. For any other repo, type
`owner/repo`. List at least one repo that you own. It also asks who posts, which
model to use and more. At **Background service**, answer `n`. Step 4 starts the
service. The answers go to `~/.config/pr-reviewer/config`.

### 3. Review one test PR

Open a small PR from a branch of a repo that you listed. Then run:

```bash
prreview once --pr you/repo#12
```

This command makes real model calls. It posts a comment as your `gh` account.
Exit code `0` means the reviewer has a verdict on the current head. Exit code
`75` means no verdict and no failure, for example for a draft PR. Exit code `1`
means the PR is not open or the reviewer could not read it.

### 4. Start the service

> [!WARNING]
> The first round reviews every open non-draft PR from a trusted author in each
> listed repo. It comments on each PR as your `gh` account. Each review costs
> model usage. Until you trust the tool, list only repos that you own.

```bash
prreview start
prreview status
prreview logs -f
```

If `gh` clones over `ssh`, `prreview start` offers to switch `gh` to `https`.
A systemd user service has no ssh-agent
([details](docs/operations.md#where-to-run-it)). With no PR to review, the loop
starts a round on only every 15th check. On Linux, systemd stops a user service
when you log out. Run `sudo loginctl enable-linger "$USER"` once to keep it
running. On WSL2, the service needs `systemd=true`. It stops when WSL shuts
down. See [docs/windows.md](docs/windows.md).

## Everyday commands

| Command | What it does |
| --- | --- |
| `prreview repos add owner/repo`, `prreview repos remove owner/repo` | Change the repos under review |
| `prreview set <name> <value>`, `prreview get <name>`, `prreview unset <name>` | Change, read or reset a setting |
| `prreview once`, `prreview run` | Run one round, or run the loop, in this terminal |
| `prreview once --pr owner/repo#12` | Review that one PR now, a fork PR included |
| `prreview stop`, `prreview start`, `prreview restart` | Control the background service |
| `prreview status`, `prreview logs -f` | Show the state and the skipped PRs. Follow the log |
| `prreview checks` | List, add or remove review items |
| `prreview uninstall` | Remove the background service. The settings stay |

A command that changes a setting restarts the service. To remove everything,
see [docs/operations.md](docs/operations.md#removing-it).

## Upgrading

```bash
cd ~/pr-reviewer
git pull --ff-only
prreview setup
```

Press Enter at every question to keep your answers. At the Checklist step,
answer `y` to take the new built-in items. Enter declines them. Setup restarts
the service, because the loop keeps the old code until it restarts. If
`claude --version` or `gh --version` is older than the minimum, setup stops.
Update the tool. Then run setup again.

In versions after 0.2.0, the reviewer skips fork PRs unless the author is in
`PRREVIEW_GATE_TRUSTED_AUTHORS`. `prreview status` shows how many PRs it
skipped. Set `PRREVIEW_GATE_FORK_PRS=1` to bring back the old behavior.

Items in your copy of the checklist keep their old wording. To see what a new
version changed in them, run
`diff -r ~/pr-reviewer/checks ~/.config/pr-reviewer/checks`.

## How a review works

<p align="center">
  <img src="docs/images/example-comment.png" alt="A review comment. A Changes requested banner counts 2 blocking findings and 1 finding that does not block. A one-line summary follows. A CRITICAL SQL injection finding is open. It shows its trace from input to sink and its citation A05:2025 Injection, CWE-89. A HIGH paging finding follows. The rest of the summary, the MEDIUM finding and what the review could not verify are folded." width="820">
</p>

This comment is from Run B. It leads with the verdict and one line per finding.
Every finding names a file, a line and a fix. The reviewer checks every slice
against the same checklist of 13 items. Each item is one file in `checks/`. The
Applies column says when the reviewer uses an item. Each finding names its item
and a severity.

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

The reviewer does not report these:

- Denial of service, except a call with no timeout.
- Memory safety in a memory-safe language.
- Vulnerabilities with no exploit path.
- Style that a linter enforces.
- Praise.

CRITICAL and HIGH findings block. MEDIUM and LOW findings are listed and do not
block. "Block" only decides the verdict text. You can
[add, remove or change items](docs/configuration.md#adding-your-own-checks).
[docs/how-it-reviews.md](docs/how-it-reviews.md) has the full list of checks and
the severity rules.

One round has seven steps. The first four steps make no model call.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/round-dark.svg">
  <img src="docs/images/round.svg" alt="Flowchart of one review round in seven steps. Steps 1 to 4 make no model call. Step 1 Pick: open PRs with no comment for the current head. Fork PRs from untrusted authors are skipped. If the head is unchanged and the last comment of the reviewer is under 10 minutes old, the round waits. A title, description or base edit can cause this wait. A push to the parent branch of a stacked PR can cause it too. A push to the PR branch never waits. Step 2 Scan: the title, description and linked issue are matched against your sensitive-patterns file. If a match is found, or the scan cannot run, a Review withheld notice is posted without the value. The PR is not reviewed. Step 3 Build: merge base plus PR diff, then convention files from the default branch. A PR with more than 2000 changed lines or 40 files gets a split request and no review, unless the PR is exempt. Step 4 Slice: slices of about 250 lines, up to 8. Step 5 Review: Claude Code reads the worktree. Step 6 Verify: findings that cite a missing file are dropped. One call for each blocking finding tries to refute it. Step 7 Post: model text is escaped. The comment is matched against your sensitive-patterns file. Then one comment is posted. Output that cannot be parsed is not posted." width="100%">
</picture>
</p>

Every push is a new round. The prompt asks the model to mark each earlier
blocker as fixed. Or the model repeats the blocker with the prefix
`Carried over:`. The harness does not check that the model does this.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/rounds-dark.svg">
  <img src="docs/images/rounds.svg" alt="State diagram of one finding across rounds. Each push starts a new round. A new CRITICAL or HIGH finding is blocking. On the next push, the model marks it fixed. Or the model repeats it with the prefix Carried over. A carried-over finding still blocks. It stays carried over until the model marks it fixed. A new HIGH finding can be on a file that the push did not change and that no earlier round cited. Then it is shown as MEDIUM. It does not block and is not carried over. CRITICAL is never lowered. The harness does not check that the model marks findings correctly. A round with no blocking findings posts Approved. If a PR is merged while its verdict is changes requested, it gets one alert comment." width="100%">
</picture>
</p>

An optional red team argues against an approval. It is off by default, because
it adds cost and time to every approval. Run `prreview set PRREVIEW_GATE_REDTEAM 1`
to turn it on.

<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/redteam-dark.svg">
  <img src="docs/images/redteam.svg" alt="Flowchart of the optional red team. A round has no blockers and is about to approve. One more call argues that the approval is wrong. It looks for five things in the diff. The first is parts that disagree. The next is a limit at the wrong level. The next is an error returned as success. The next is a branch that decides from other input. The last is a rule that the docs of the repo pin. If the call fails or times out, the approval stands. If there is no CRITICAL or HIGH candidate, the approval stands. Up to 3 candidates each go through one refutation call. A refuted candidate is dropped and the approval stands. A survivor is posted and marked as raised by the red team. The red team is off by default. The command prreview set PRREVIEW_GATE_REDTEAM 1 turns it on." width="100%">
</picture>
</p>

[docs/operations.md](docs/operations.md) describes what happens when a step
fails. It also describes each step in detail.

## Settings

Settings come from a config file and from overrides. The file is
`~/.config/pr-reviewer/config`. It has one `KEY=value` per line, and
`prreview set` writes it. A variable set in the environment overrides the file.
Two settings are required: `PRREVIEW_GATE_REPOS` and
`PRREVIEW_SENSITIVE_PATTERNS_FILE`. The second one names the sensitive-patterns
file that `prreview setup` writes. People change these settings most:

- `PRREVIEW_GATE_TRUSTED_AUTHORS`
- `PRREVIEW_GATE_FORK_PRS`
- `PRREVIEW_REVIEW_MODEL`
- `PRREVIEW_GATE_PARALLEL`
- `PRREVIEW_GATE_PR_COOLDOWN_MIN`
- `PRREVIEW_GATE_REDTEAM`
- `PRREVIEW_GATE_TICKETS`
- `PRREVIEW_ALERT_REPO`

Where to read more:

- [docs/configuration.md](docs/configuration.md) lists every setting and its
  default.
- [docs/operations.md](docs/operations.md) describes one round in detail and the
  failures.
- [docs/github-app.md](docs/github-app.md) explains how to post as an App.
- [docs/windows.md](docs/windows.md) covers WSL2.

## Development

```bash
bash tests/run-all.sh
```

That command runs `bash -n`, `shellcheck -S warning` and every
`tests/*.test.sh`. It needs no network, no `gh` and no model. It fails when
`shellcheck` is not installed. Run it in a `git clone`. The checks list the
scripts with `git ls-files`, and a ZIP download fails at that step. CI runs the
same command on Ubuntu and on macOS. See [CONTRIBUTING.md](CONTRIBUTING.md).
The project puts predictable review behavior ahead of review breadth.

## License

[MIT](LICENSE)
