#!/usr/bin/env bash
# Two invariants about what this gate posts and who posts it. Both fail
# SILENTLY in production: the symptom is a comment that never appears, or two
# notices that slowly stop agreeing.
#
# Run: bash tests/posting.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SRC=pr-autoreview.sh
RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }

# 1. Every post goes through gh_post. A new site written with the raw
#    `GH_TOKEN="$APP_TOKEN"` prefix works on a repo where the App is installed
#    and fails on one where it is not: the call gets
#    "Could not resolve to a Repository" and the comment never lands.
# gh_post's own body is where that prefix BELONGS, so it is cut out before
# counting. Cutting it rather than allowing one hit anywhere: "one is fine"
# would also pass a stray call site plus a helper that no longer has it.
FN_BODY="$(awk '/^gh_post\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC")"
[ -n "$FN_BODY" ] \
  || { echo "could not locate gh_post in $SRC — refusing to report a pass"; exit 1; }
OUTSIDE="$(grep -vFx "$FN_BODY" "$SRC" 2>/dev/null || cat "$SRC")"
RAW="$(printf '%s\n' "$OUTSIDE" | grep -c 'GH_TOKEN="\$APP_TOKEN" "\$GH"')"
[ "$RAW" = "0" ] \
  || fail "$RAW post site(s) outside gh_post still use GH_TOKEN=\$APP_TOKEN directly — route them through gh_post, or they break on review-only repos"

# The helper has to still exist, or the check above passes vacuously.
grep -q '^gh_post() {' "$SRC" \
  || fail "gh_post is gone from $SRC — the check above then proves nothing"

# 4. gh_post is RUN, not just grepped for. The three checks above all passed
#    while the helper's else-branch called ITSELF: a global search-and-replace
#    of the old prefix rewrote the body of the function that had just been
#    added to hold it, and every repo posting as the App then took the gate down
#    with a stack overflow (SIGSEGV, five rounds). A test
#    that reads source text cannot see that; one that executes it cannot miss.
#
#    FUNCNEST is the seatbelt, not decoration: without it a self-recursive
#    version exhausts the stack and kills the TEST RUNNER instead of failing.
STUB="$(mktemp -d)"
cat > "$STUB/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf 'called token=%s args=%s\n' "${GH_TOKEN-unset}" "$*" >> "$STUB_LOG"
STUB_EOF
chmod +x "$STUB/gh"

run_gh_post() { # $1 = POST_AS_APP value; echoes the stub's log
  : > "$STUB/log"
  env STUB_LOG="$STUB/log" GH="$STUB/gh" APP_TOKEN=apptok POST_AS_APP="$1" FUNCNEST=25 \
    bash -c "$FN_BODY"'
gh_post pr comment 1 --repo o/r' >/dev/null 2>&1
  cat "$STUB/log"
}

NORMAL="$(run_gh_post 1)"
case "$NORMAL" in
  *"called token=apptok"*) ;;
  *) fail "gh_post posting as the App did not reach gh with the App token (got: ${NORMAL:-nothing}) — a self-recursive helper looks exactly like this" ;;
esac
[ "$(printf '%s\n' "$NORMAL" | grep -c '^called')" = "1" ] \
  || fail "gh_post posting as the App called gh $(printf '%s\n' "$NORMAL" | grep -c '^called') times, expected once"

ONLY="$(run_gh_post 0)"
case "$ONLY" in
  *"called token=unset"*) ;;
  *) fail "gh_post posting as the gh login must call gh WITHOUT the App token (got: ${ONLY:-nothing})" ;;
esac
rm -rf "$STUB"

[ "$RC" -eq 0 ] && echo "PASS"
exit "$RC"
