<div align="center">
  <h1>PR Reviewer</h1>
  <p>
    <a href="https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml"><img src="https://github.com/nagameTW/pr-reviewer/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <a href="./LICENSE"><img src="https://img.shields.io/github/license/nagameTW/pr-reviewer?style=flat-square&logo=opensourceinitiative&logoColor=white&color=3DA639" alt="License"></a>
    <a href="#requirements"><img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25" alt="bash 3.2+"></a>
  </p>
  <p><a href="README.md">English</a> | <a href="README.zh-TW.md">繁體中文</a></p>
</div>

pr-reviewer reviews pull requests on your own machine, with your own Claude Code login. It needs no GitHub Action, no App, no webhook and no repo admin rights.

It watches the repos you list. Each pass over those repos is a round. In a round, for each new head of an open PR from a [trusted author](docs/operations.md#whose-prs-it-reviews), it asks headless [Claude Code](https://code.claude.com/docs/en/overview) for a review. The head is the latest commit of the PR. Headless means Claude Code runs without a screen. Then it posts one comment with a verdict (Approved or Changes requested) and the findings.

Comments come from your own `gh` account, or from a [GitHub App](docs/github-app.md) if you set one up. It is a set of bash scripts that call `gh`, `git`, `jq` and `claude`. To see a real run and a real comment, read the [demo page](docs/demo.md).

## Safety and cost

[SECURITY.md](SECURITY.md) and [docs/trust-cost-limits.md](docs/trust-cost-limits.md) have the details.

- It only comments. It never approves a PR and never merges one.
- The model can only read. It gets `Read`, `Grep` and `Glob` in a separate working directory (a git worktree) of each PR. The PR code never runs.
- Run it on a machine only you use. The service runs with your `gh` login and your Claude Code login.
- It skips PRs from forks unless the author is on your trusted list.
- It uses your Claude Code login, so reviews count against your usage limits. One review of the demo PR cost $0.54.

## Status and limits

- Pre-1.0. Anything can change between versions. Read [CHANGELOG.md](CHANGELOG.md) before you upgrade.
- No one has counted how many bugs it finds or how many false alarms it raises.
- GitHub only. It runs on macOS, Linux and WSL2.

## Requirements

- macOS or Linux. On Windows, it runs inside WSL2.
- bash 3.2 or newer. The `/bin/bash` that macOS ships works.
- [gh](https://cli.github.com/) 2.63.0 or later and [Claude Code](https://code.claude.com/docs/en/overview) 2.1.305 or later. Both must be logged in.
- `git`, `jq`, `curl`, `openssl` and `flock`. Also one timeout command (`timeout` or `gtimeout`) and one SHA-256 command (`sha256sum`, `gsha256sum` or `shasum`).
- On Linux, systemd 240 or newer for the background service.

`prreview setup` checks every item and prints the install command for your system. See [Install the tools](docs/install.md#install-the-tools).

## Quick start

```bash
git clone https://github.com/nagameTW/pr-reviewer.git ~/pr-reviewer
mkdir -p ~/.local/bin && ln -s ~/pr-reviewer/prreview ~/.local/bin/prreview
prreview setup
prreview once --pr you/repo#12
prreview start
```

1. Get the code and put `prreview` on your `PATH` ([details](docs/install.md#1-get-the-code)).
2. Run the setup. List at least one repo that you own. At **Background service**, answer `n`. You start the service in step 4.
3. Review one test PR from a listed repo. This makes real model calls and posts a comment as your `gh` account.
4. Start the service. `prreview status` shows the state and `prreview logs -f` follows the log ([details](docs/install.md#4-start-the-service)).

> [!WARNING]
> The first round reviews every open non-draft PR from a trusted author in each listed repo. It comments on each PR as your `gh` account. Each review costs model usage. Until you trust the tool, list only repos that you own.

## Everyday commands

| Command | What it does |
| --- | --- |
| `prreview repos add owner/repo`, `prreview repos remove owner/repo` | Change the repos under review |
| `prreview set <name> <value>`, `prreview get <name>`, `prreview unset <name>` | Change, read or reset a setting |
| `prreview once`, `prreview run` | Run one round, or keep running rounds, in this terminal |
| `prreview once --pr owner/repo#12` | Review that one PR now |
| `prreview stop`, `prreview start`, `prreview restart` | Control the background service |
| `prreview status`, `prreview logs -f` | Show the state and the skipped PRs. Follow the log |
| `prreview checks` | List, add or remove review items |
| `prreview uninstall` | Remove the background service. The settings stay |
| `prreview version` | Print the version |
| `prreview <command> --help` | Print the usage of one command |

To remove everything, see [Removing it](docs/operations.md#removing-it).

## Upgrading

```bash
cd ~/pr-reviewer
git pull --ff-only
prreview setup
```

Press Enter at every question to keep your answers. See [Upgrading](docs/install.md#upgrading) for what changes between versions.

## How a review works

The reviewer checks the diff against a checklist of 13 items. Each item is one file in [checks/](checks/).

| Item | Looks for |
| --- | --- |
| 1 Correctness | Bugs, unhandled inputs, broken callers, concurrency faults |
| 2 Security | Injection, authorization gaps, crypto and secrets, data exposure |
| 2b AI-agent security | Prompt injection, unchecked model output, an AI agent given more power than it needs |
| 3 Sensitive data | Real addresses, host names, tokens or credentials |
| 4 Project constraints | Rules the repo wrote down for itself |
| 5 Tests | CI weakened, a bug fix with no test, weak assertions |
| 6 Design | Over-engineering, a change in the wrong place |
| 7 Doc sync | Docs that still describe the old behavior |
| 8 Dependencies | A dependency that is not declared or not pinned like the rest |
| 9 Evidence-first | A rule of thumb, limit, model choice or prompt change with no measurement |
| 10 Tool surface | Tools a model can call that are too broad or need no approval |
| 11 Acceptance | A requirement of the linked issue that the diff does not deliver |
| 12 Half-fixes | The same defect left in a similar place, such as a sibling file or function |

Each finding has a severity: CRITICAL, HIGH, MEDIUM or LOW, from highest to lowest. CRITICAL and HIGH findings make the verdict Changes requested. MEDIUM and LOW findings are listed and do not change it. The verdict is text in the comment. It is not a GitHub review state. [docs/how-it-reviews.md](docs/how-it-reviews.md) describes the checklist, each step of a round and what the reviewer leaves out. It also has [diagrams](docs/how-it-reviews.md#diagrams). You can [add, remove or change items](docs/configuration.md#adding-your-own-checks).

## Settings

`prreview setup` writes your settings to `~/.config/pr-reviewer/config`. The environment can override them. The only required setting is `PRREVIEW_GATE_REPOS`, the list of repos. [docs/configuration.md](docs/configuration.md) lists every setting and its default.

## Repository structure

```
├── prreview                  # The command line
├── review-loop.sh            # Runs a round once a minute
├── pr-autoreview.sh          # One round
├── checks/                   # The 13 checklist items
├── lib/                      # Shared bash code
├── tests/                    # Tests
├── docs/
│   ├── install.md            #   Install, set up, start, upgrade
│   ├── configuration.md      #   Every setting, your own checks
│   ├── operations.md         #   A round in detail, failures, removal
│   ├── how-it-reviews.md     #   The checklist, severity, diagrams
│   ├── trust-cost-limits.md  #   Trust, cost, limits
│   ├── github-app.md         #   Post as a GitHub App
│   ├── windows.md            #   WSL2
│   ├── demo.md               #   Demo run and example comment
│   ├── comparison.md         #   Other review tools
│   └── zh-TW/diagrams.md     #   Diagrams for README.zh-TW.md
├── SECURITY.md               # Security model
├── CONTRIBUTING.md           # How to contribute
└── CHANGELOG.md              # Changes per version
```

## Development

```bash
bash tests/run-all.sh
```

That command runs `bash -n`, `shellcheck -S warning` and every `tests/*.test.sh`. It needs no network, no `gh` and no model. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
