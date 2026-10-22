# Contributing

Thanks for looking into this. The whole reviewer is bash, and the test suite
runs offline in about a minute, so you can go from a fresh clone to a passing
run without an API key.

## Getting set up

You need the tools from the README's [Requirements](README.md#requirements)
except `gh` and `claude`: the tests stub both and never touch the network,
so neither has to be installed or logged in. On macOS that means
`brew install jq coreutils flock shellcheck` at least, since several tests
need a timeout command (`gtimeout` is enough) and `flock`. Also install:

- `shellcheck`, for the lint step. A run without it fails, so the lint step
  cannot be skipped by mistake. CI uses the version GitHub's Ubuntu runners
  come with (the CI log's "Tool versions" step prints it); a much newer one
  can warn about lines CI accepts, or the other way round.
- `python3`: a few assertions use it, and are skipped without it.

```bash
git clone https://github.com/nagameTW/pr-reviewer.git
cd pr-reviewer
bash tests/run-all.sh
```

## Before you open a pull request

Run the same command CI runs:

```bash
bash tests/run-all.sh
```

It must end with `ALL PASS`. It prints the versions of bash, gh, git, jq and
flock, then runs `bash -n` on every script, `shellcheck -S warning`, and every
`tests/*.test.sh`. Each test runs with the bash that runs `run-all.sh`. It
finds the scripts with `git ls-files`, so `git add` a new script before you
run it.

CI runs the command on Ubuntu, and on macOS with `/bin/bash`, which is bash
3.2. A script that works on a newer bash can fail there. Bash 3.2 has no
`mapfile` and no associative arrays. It also ends a `$( )` at the first `)` it
counts, so a `case` pattern inside `$( )` needs a leading `(`, and a comment
inside `$( )` must not hold a single quote. To try bash 3.2 without a Mac, run
the suite in the `bash:3.2` Docker image.

## How the code is laid out

- `pr-autoreview.sh` is one round, top to bottom. Start there.
- `lib/` holds the pieces a round calls: `prompt.sh` builds prompts and reads
  earlier rounds, `findings.sh` filters and renders what the model returns,
  `review-spec.sh` reads the checklist in `checks/` and holds the rules every
  prompt shares, `chunk.sh` slices diffs, `scan.sh` is the sensitive-data
  scan, `holdoff.sh` remembers failures between rounds, `trust.sh` decides
  which PRs the reviewer reads by their authors, and so on. Every file
  there can be sourced on its own and has no side effects when sourced.
- `review-loop.sh` runs rounds on a timer; `owner-alert.sh` opens an issue when
  a round fails and `PRREVIEW_ALERT_REPO` is set.
- `prreview` is the setup and control command. `lib/prreview-config.sh` reads and writes
  its settings file, and `lib/prreview-service.sh` writes and drives the launchd or
  systemd service.
- `tests/` has a `*.test.sh` named after most lib files (`chunk.test.sh` for
  `lib/chunk.sh`). The exceptions: `prreview.test.sh` tests `prreview` together with
  `lib/prreview-config.sh` and `lib/prreview-service.sh`,
  `review-checks.test.sh` tests how `lib/review-spec.sh` reads `checks/`, and
  `alert.test.sh` tests `owner-alert.sh`. `trust.test.sh` also runs the gate
  against a stub `gh`, and tests `prreview once --pr`. `gate-wiring.test.sh`,
  `posting.test.sh` and `startup.test.sh` pin how `pr-autoreview.sh` calls
  the libs.
- The "discipline" tests scan the source for patterns that caused bugs
  before: `tmp-discipline.test.sh` (a bare `mktemp` into `/tmp`),
  `scan-discipline.test.sh` (piping into `grep -q`, an unescaped backtick in a
  prompt string, a comment the linter reads as a directive, a posted notice
  that lost its instruction),
  `multibyte-interpolation.test.sh` (a multibyte character right after an
  unbraced `$VAR`) and `parallel-discipline.test.sh` (a bare `continue` or
  `exit` inside a review job).

## Rules that shape the code

- **Fail closed.** When the reviewer cannot tell whether something is safe
  (output that does not parse, a scan that cannot run, an API that errors), it
  posts nothing and tries again on a later round. A change that turns one of
  those into "carry on as if it passed" will not land.
- **Untrusted text stays data.** PR titles, descriptions, diffs and model
  output reach prompts inside labeled, fenced blocks, and never reach a shell,
  `eval` or a file path unchecked.
- **Every rule has a test that fails without it.** If you add a check, add the
  test, and make sure it goes red when you revert the check.
- **Comments say why.** Comments say why a line is written the way it is.
  Keep the reason when you change the line.

## Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org):
`feat:`, `fix:`, `docs:`, `test:`, `chore:`, and so on.

## Reporting bugs and asking for features

Use the issue templates. For anything security-related, do not open a public
issue; see [SECURITY.md](SECURITY.md).
