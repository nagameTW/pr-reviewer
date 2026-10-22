<!-- Keep the summary short. The diff shows what changed; this box is for why. -->

## What this changes

<!-- One or two sentences. If it closes an issue, add "Closes #123". -->

## Why

<!-- The problem it solves, or the behavior it fixes. -->

## Type

- [ ] Bug fix
- [ ] Review behavior (what gets checked, how findings are filtered or shown)
- [ ] New setting
- [ ] Docs only
- [ ] Tests, CI or refactor

## If this changes review behavior

<!-- Skip this section otherwise. -->

- [ ] I ran at least one real round on a test pull request and describe the before and after here
- [ ] Anything that cannot be parsed, verified or scanned still posts nothing

## Checklist

- [ ] `bash tests/run-all.sh` ends with `ALL PASS`
- [ ] New checks have a test that fails without them
- [ ] If behavior or configuration changed, I updated the README
- [ ] I added a line under `[Unreleased]` in CHANGELOG.md
