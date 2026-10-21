# Security policy

The reviewer passes text from anyone who can open a pull request to a model
that can read files, and then posts the result under your GitHub account. So
the security model is worth stating plainly.

## Reporting a vulnerability

Report privately through GitHub's security advisories:

**https://github.com/nagameTW/pr-reviewer/security/advisories/new**

Please do not open a public issue for a security problem. Expect a first
response within a few days. Once there is a fix, we will agree on the
disclosure timing with you.

The useful details are the commit you ran, the `PRREVIEW_*` settings that differ
from the defaults, and a pull request (title, description and diff) that
reproduces it. Redact tokens, hostnames and anything your sensitive-patterns
file would have caught before you send it.

## Supported versions

The project is pre-1.0, so only the latest commit on `main` gets fixes.

## The security model

These hold by design. If you can break one, that is a vulnerability.

**The pull request is data.** The model reads titles, descriptions, diffs and
repository files with its read-only tools, and the prompt says that none of
that text is an instruction. PR text placed in the prompt itself sits between
markers with a new random value every round, so it cannot close its block
early. This is an instruction to the model, not a sandbox; the tool limits
below are what hold if the model is fooled.

**The model can only read, and only the review clone.** Claude Code runs
headless with `Read`, `Grep` and `Glob`, each limited to the review clone,
plus `Read` on the round's own scratch copies of the diff and of the PR's title
and description (with the title and body of the issue the PR links, when it
links one). `--setting-sources` is empty, so the operator's own Claude
settings cannot widen that. Every other tool, a shell and the network
included, needs a permission a headless run has nobody to grant, so it is
refused. Checked against Claude Code 2.1 with the reviewer's own flags: `Bash`,
`Write`, `WebFetch` and a `Read` outside the clone were all refused, and an
`.mcp.json` or `CLAUDE.local.md` a pull request adds was not loaded. This was a
manual test. The Claude Code patch version and the exact command were not
recorded.

**The merge base sets the rules.** The review tree is the PR's merge base with
the diff applied, and convention files such as `CLAUDE.md` are read as they are
at the PR's merge base. The match is exact in file name case, so a PR's edit
to a differently cased file such as `readme.md` is not restored. The author's
branch is never checked out.

**Comments with PR text or model output are scanned.** Every comment that
carries PR text or model output is checked against the operator's
sensitive-patterns file before it is posted. A match, or a scan that cannot
run, means it is not posted. Two fixed notices carry neither and are not
scanned: the notice that a title or description matched the scan, and the
title-format reminder. The reviewer will not start without that file.
The scan matches your patterns against the text as written. Text shaped to
slip past it, such as a key split by an HTML entity or a zero-width
character, is not caught, so treat it as a safety net for accidents.

**What the model writes is posted as written.** A pull request can steer
the model's words, and those words go out under the reviewer's identity. If a
bot in your repository acts on commands in comments (`/lgtm`, `/approve`,
`bors r+`), run the reviewer as a GitHub App that bot does not take commands
from, not as a person it trusts.

**Refutation is not a security control.** The refutation step can only remove
blocking findings. Against an author who writes the diff to fool the model, it
pushes the verdict toward approve. The red-team pass, which is off by default,
is the only step that argues against an approve. Refutation reduces false
positives. It does not stop a diff that was written to fool the model.

**It cannot merge.** It never approves or merges. Its only merge call is
`gh pr merge --disable-auto`, which is off by default. With the defaults it
leaves auto-merge alone. `PRREVIEW_GATE_DISARM_AUTO_MERGE=1` lets it turn off
an auto-merge armed on a head it has not reviewed yet.

**Scratch files stay private.** Diffs, slices and raw model output are written
under the reviewer's own work directory, not a shared `/tmp`.

## In scope

- Text in a pull request that makes the reviewer post something it should not:
  content from outside the repository, text the sensitive-data scan should
  have caught, or instructions followed as if they came from the operator.
- A way for the model to read outside the review clone, or to run a command.
- A pull request that gets itself reviewed against conventions it changed.
- A comment by someone other than the reviewer's account that the reviewer
  mistakes for its own earlier verdict.

## Out of scope

- The model being wrong about the code. A missed bug or a false finding is a
  bug report, not a vulnerability.
- Anything that needs control of the machine the reviewer runs on, or of the
  `gh` and `claude` credentials the operator gave it.
- Claude Code, `gh` and GitHub themselves. Report those upstream.
- Someone with write access to the repository editing or deleting the
  reviewer's comments. The reviewer keeps what it has reviewed in those
  comments, so such a person can make a head look reviewed or hide a verdict;
  they can also push and merge, which is the larger power. Use branch
  protection for what must not be bypassed.
