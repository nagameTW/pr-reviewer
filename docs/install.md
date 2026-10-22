# Installing the reviewer

This page holds the details behind the [Quick start](../README.md#quick-start) and the [Upgrading](../README.md#upgrading) section of the README. It covers the tools to install, each step of the Quick start, and what changes when you upgrade.

Contents:

- [Install the tools](#install-the-tools)
- [Quick start in detail](#quick-start-in-detail)
- [Upgrading](#upgrading)

## Install the tools

The [Requirements](../README.md#requirements) list the tools. These notes add the details.

- `claude update` installs the latest Claude Code.
- On Linux, the background service needs systemd 240 or newer. The service writes its log with `StandardOutput=append:`.
- The scripts use the first timeout command and the first SHA-256 command that they find.

`prreview setup` checks every tool. It prints the install command for your system. You can also run the commands yourself.

On macOS with Homebrew, run:

```bash
brew install git jq gh coreutils flock
```

On Debian or Ubuntu, run:

```bash
sudo apt install git jq curl openssl util-linux coreutils
```

Then install `gh` from [GitHub's package repository](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).

## Quick start in detail

### 1. Get the code

```bash
git clone https://github.com/nagameTW/pr-reviewer.git ~/pr-reviewer
mkdir -p ~/.local/bin && ln -s ~/pr-reviewer/prreview ~/.local/bin/prreview
```

If `~/.local/bin` is not on your `PATH`, add it. A fresh macOS does not have it there. For zsh, run this command and open a new terminal:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

Without the link, run `~/pr-reviewer/prreview` in place of `prreview` in the steps below.

Keep the clone out of `~/Documents`, `~/Desktop`, `~/Downloads` and iCloud Drive (`~/Library/Mobile Documents`). A macOS background service cannot read these folders.

### 2. Run the setup

```bash
prreview setup
```

It asks one question at a time. Press Enter to keep the value in brackets.

1. It checks your tools and your `claude` and `gh` logins.
2. It asks for the repos to review. It lists up to 30 of your own repos. For any other repo, type `owner/repo`. List at least one repo that you own.
3. It asks who posts, which model to use and more.

At **Background service**, answer `n`. Step 4 starts the service. The answers go to `~/.config/pr-reviewer/config`. [Settings](configuration.md) lists every setting.

### 3. Review one test PR

Open a small PR from a branch of a repo that you listed. Then run:

```bash
prreview once --pr you/repo#12
```

This command makes real model calls. It posts a comment as your `gh` account.

Exit code `0` means the reviewer has a verdict on the current head. Exit code `75` means no verdict and no failure, for example for a draft PR. Exit code `1` means the PR is not open or the reviewer could not read it. [Whose PRs it reviews](operations.md#whose-prs-it-reviews) explains the exit codes.

### 4. Start the service

> [!WARNING]
> The first round reviews every open non-draft PR from a trusted author in each listed repo. It comments on each PR as your `gh` account. Each review costs model usage. Until you trust the tool, list only repos that you own.

```bash
prreview start
prreview status
prreview logs -f
```

`prreview status` shows the state of the service and the PRs that it skipped. `prreview logs -f` follows the log.

- If `gh` clones over `ssh`, `prreview start` offers to switch `gh` to `https`. A systemd user service has no ssh-agent. See [Where to run it](operations.md#where-to-run-it).
- With no PR to review, the loop starts a round on only every 15th check.
- On Linux, systemd stops a user service when you log out. Run `sudo loginctl enable-linger "$USER"` once to keep it running.
- On WSL2, the service needs `systemd=true`. It stops when WSL shuts down. See [windows.md](windows.md).

## Upgrading

```bash
cd ~/pr-reviewer
git pull --ff-only
prreview setup
```

Press Enter at every question to keep your answers.

- At the Checklist step, answer `y` to take the new built-in items. Enter declines them.
- Setup restarts the service, because the loop keeps the old code until it restarts.
- If `claude --version` or `gh --version` is older than the minimum, setup stops. Update the tool. Then run setup again.

From the release after 0.2.2, the reviewer skips fork PRs unless the author is in `PRREVIEW_GATE_TRUSTED_AUTHORS`. Release 0.2.2 and earlier releases review every fork PR. `prreview status` shows how many PRs the reviewer skipped. Set `PRREVIEW_GATE_FORK_PRS=1` to bring back the old behavior.

Items in your copy of the checklist keep their old wording. To see what a new version changed in them, run:

```bash
diff -r ~/pr-reviewer/checks ~/.config/pr-reviewer/checks
```

[CHANGELOG.md](../CHANGELOG.md) lists the changes of each version.
