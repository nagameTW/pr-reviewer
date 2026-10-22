#!/usr/bin/env bash
# prreview, the setup and control command: the settings file, the service files
# it writes, and the setup walk-through driven by typed answers.
# Nothing here installs a service or talks to GitHub: gh is a stub and the
# platform is forced. It needs prreview and lib/review-spec.sh side by side, as
# they are at the repository's root:
# bash tests/prreview.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
# A PRREVIEW_ setting exported in the caller's shell would win over every file
# this test writes (the environment comes first), so none is inherited.
for v in $(compgen -e | grep '^PRREVIEW_'); do unset "$v"; done
. lib/prreview-config.sh || { echo "lib/prreview-config.sh missing"; exit 1; }
. lib/prreview-service.sh || { echo "lib/prreview-service.sh missing"; exit 1; }
. lib/tools.sh || { echo "FAIL: cannot source lib/tools.sh"; exit 1; }
# macOS without the coreutils gnubin directory has gtimeout and no timeout.
# Find the commands the way the scripts do.
tools_resolve || { echo "FAIL: no timeout command or no SHA-256 command on PATH"; exit 1; }
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "text containing '$3'" "$2" ;; esac; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ── the settings file ─────────────────────────────────────────────────────
C="$T/config"
prreview_config_set "$C" PRREVIEW_GATE_REPOS 'acme/api acme/web'
prreview_config_set "$C" PRREVIEW_GATE_PARALLEL 2
prreview_config_set "$C" PRREVIEW_GATE_PARALLEL 4
is 'a value with spaces reads back whole' "$(prreview_config_get "$C" PRREVIEW_GATE_REPOS)" 'acme/api acme/web'
is 'setting a key again replaces its line' "$(grep -c '^PRREVIEW_GATE_PARALLEL=' "$C")" 1
is '...with the new value' "$(prreview_config_get "$C" PRREVIEW_GATE_PARALLEL)" 4
prreview_config_set "$C" PRREVIEW_GATE_PARALLEL ''
is 'an empty value removes the key' "$(grep -c '^PRREVIEW_GATE_PARALLEL=' "$C")" 0
is '...and leaves the others alone' "$(prreview_config_get "$C" PRREVIEW_GATE_REPOS)" 'acme/api acme/web'
is 'the file is private to its owner' "$(ls -l "$C" | cut -c1-10)" '-rw-------'
prreview_config_set "$C" PRREVIEW_GATE_REPO_CONTEXT 'Read $(touch '"$T"'/pwned) first'
( unset PRREVIEW_GATE_REPO_CONTEXT; prreview_config_export "$C"; printf '%s' "$PRREVIEW_GATE_REPO_CONTEXT" ) > "$T/ctx"
is 'a value is taken literally, never run' "$(cat "$T/ctx")" 'Read $(touch '"$T"'/pwned) first'
is '...so nothing ran' "$([ -e "$T/pwned" ] && echo ran || echo not-run)" not-run
is 'the environment wins over the file' "$(PRREVIEW_GATE_REPOS=x/y bash -c ". lib/prreview-config.sh; prreview_config_export '$C'; printf '%s' \"\$PRREVIEW_GATE_REPOS\"")" 'x/y'
prreview_config_set "$C" PATH /opt/tools/bin
is 'except PATH: a service needs the one setup recorded' "$(bash -c ". lib/prreview-config.sh; prreview_config_export '$C'; printf '%s' \"\$PATH\"")" '/opt/tools/bin'
is 'a key that is not a setting is refused' "$(prreview_config_set "$C" HOME /tmp 2>&1)" 'not a setting name: HOME'
printf 'PRREVIEW_GATE_REPOS=a/b\nrepos = a/b\n' > "$T/typo"
is 'a malformed line is refused with its line number' "$(prreview_config_read "$T/typo" 2>&1 >/dev/null | cut -d: -f2)" 2
is 'a two-line value is refused' "$(prreview_config_set "$C" PRREVIEW_GATE_REPOS "$(printf 'a/b\nc/d')" 2>&1)" 'PRREVIEW_GATE_REPOS: a value must be one line'

is 'repos is PRREVIEW_GATE_REPOS' "$(prreview_key_of repos)" PRREVIEW_GATE_REPOS
is 'parallel is PRREVIEW_GATE_PARALLEL' "$(prreview_key_of parallel)" PRREVIEW_GATE_PARALLEL
is 'a PRREVIEW_ name is itself' "$(prreview_key_of PRREVIEW_GATE_REDTEAM)" PRREVIEW_GATE_REDTEAM
is 'anything else is not a name' "$(prreview_key_of bogus || echo refused)" refused
# PRREVIEW_GATE_REDTEAM is read by pr-autoreview.sh alone: no alias, no lib.
is 'a setting only the gate script reads is known' "$(prreview_key_known "$ROOT" PRREVIEW_GATE_REDTEAM && echo known)" known
is 'a misspelled one is not' "$(prreview_key_known "$ROOT" PRREVIEW_GATE_PARALEL || echo unknown)" unknown
is 'nor a name that is only the start of a setting' "$(prreview_key_known "$ROOT" PRREVIEW_GATE_PARALLE || echo unknown)" unknown
is "nor a name prreview uses for itself" "$(prreview_key_known "$ROOT" PRREVIEW_SERVICE_NAME || echo unknown)" unknown
UNKNOWN=""; TABLE_KEYS="$(grep -oE '^\| `PRREVIEW_[A-Z0-9_]+`' docs/configuration.md | tr -d '|` ')"
for k in $TABLE_KEYS; do prreview_key_known "$ROOT" "$k" || UNKNOWN="$UNKNOWN $k"; done
is 'the settings table in docs/configuration.md was found' "$([ -n "$TABLE_KEYS" ] && echo found)" found
is 'every setting in the docs/configuration.md table is one the reviewer reads' "$UNKNOWN" ''
# Where docs/configuration.md gives one plain value as a default, it must be the one
# the reviewer uses: a default changed on one side only misleads.
DRIFT=""
while IFS='|' read -r _ k d _; do
  k="$(tr -d '` ' <<<"$k")"; d="$(sed 's/^ *//; s/ *$//' <<<"$d")"
  [[ "$d" =~ ^\`[A-Za-z0-9._-]+\`$ ]] || continue
  d="${d//\`/}"; c="$(prreview_key_default "$ROOT" "$k")"
  case "$c" in ''|*'$'*) continue ;; esac
  [ "$c" = "$d" ] || DRIFT="$DRIFT $k(docs $d, reviewer $c)"
done < <(grep -E '^\| `PRREVIEW_[A-Z0-9_]+` \|' docs/configuration.md)
is 'every plain default in the docs/configuration.md table is the one the reviewer uses' "$DRIFT" ''
printf 'PRREVIEW_GATE_PARALLEL=2\nPRREVIEW_GATE_PARALLEL=6\n' > "$T/twice"
is 'a key set twice is refused, naming the second line' "$(prreview_config_read "$T/twice" 2>&1 >/dev/null | cut -d: -f2)" 2
cp "$C" "$T/c.before"
is 'a failed copy of the other lines leaves the file as it was' \
   "$( (awk() { return 2; }; prreview_config_set "$C" PRREVIEW_GATE_PARALLEL 4 && echo written || echo refused); cmp -s "$C" "$T/c.before" && echo intact)" \
   "$(printf 'refused\nintact')"
C2="$T/config2"; printf 'PRREVIEW_GATE_REPOS=from/file\n' > "$C2"
is 'a shell variable that is not exported does not block the file' \
   "$(bash -c ". lib/prreview-config.sh; PRREVIEW_GATE_REPOS=shell-only; prreview_config_export '$C2'; printenv PRREVIEW_GATE_REPOS")" from/file

# ── platform and service files ────────────────────────────────────────────
is 'Darwin is macOS' "$(prreview_platform Darwin)" macos
is 'Linux with a Microsoft kernel is WSL' "$(prreview_platform Linux 'Linux version 9.9.9-microsoft-standard-WSL2')" wsl
is 'other Linux is Linux' "$(prreview_platform Linux 'Linux version 9.9.9-generic')" linux
is 'anything else has no service' "$(prreview_platform FreeBSD)" unsupported
is 'a clone under Documents is one macOS blocks' "$(prreview_macos_protected_dir "$HOME/Documents/pr-reviewer" && echo blocked)" blocked
is 'a clone in the home directory is not' "$(prreview_macos_protected_dir "$HOME/pr-reviewer" || echo allowed)" allowed
PL="$(prreview_launchd_plist '/opt/a&b/pr-reviewer' "$T/gate.log")"
has 'the plist runs prreview run' "$PL" '<string>/opt/a&amp;b/pr-reviewer/prreview</string>'
has 'prreview run tells the loop which log is its own, so the loop can rotate it' \
    "$(sed -n '/^cmd_run()/,/^}/p' "$ROOT/prreview")" 'PRREVIEW_LOOP_LOG_FILE="$own_log" exec bash'
has '...only when the service runs it (its output goes to that log)' \
    "$(sed -n '/^cmd_run()/,/^}/p' "$ROOT/prreview")" '[ "${1-}" = --service ] && own_log="$LOG"'
has 'the plist runs it as the service' "$PL" '<string>run</string>
    <string>--service</string>'
if command -v plutil >/dev/null 2>&1; then
  printf '%s\n' "$PL" > "$T/x.plist"
  is 'the plist is valid' "$(plutil -lint "$T/x.plist" | sed 's/.*: //')" OK
fi
UNIT="$(prreview_systemd_unit '/home/me/my tools/pr-reviewer' "$T/gate.log")"
has 'the unit quotes a path with a space' "$UNIT" 'ExecStart=/bin/bash "/home/me/my tools/pr-reviewer/prreview" run --service'
has '...and a $, which systemd would otherwise expand' "$(prreview_systemd_unit '/home/me/my$work/prreview' "$T/gate.log")" '"/home/me/my$$work/prreview/prreview"'
mkdir -p "$T/ph/Documents/prreview"; ln -s "$T/ph/Documents/prreview" "$T/alias"
is 'a clone under Documents reached through a symlink is still blocked' \
   "$( (HOME="$T/ph"; prreview_macos_protected_dir "$T/alias" && echo blocked) )" blocked
mkdir -p "$T/lbin"
printf '#!/bin/sh\necho "$1" >> "%s"\ncase "$1" in kickstart) exit 113 ;; esac\n' "$T/launchctl.log" > "$T/lbin/launchctl"; chmod +x "$T/lbin/launchctl"
( PATH="$T/lbin:$PATH"; prreview_service_restart macos >/dev/null 2>&1 )
has 'restart on macOS starts a stopped service instead of failing' "$(cat "$T/launchctl.log")" bootstrap
printf '#!/bin/sh\necho "$1" >> "%s"\n' "$T/launchctl.log" > "$T/lbin/launchctl"
: > "$T/launchctl.log"
( PATH="$T/lbin:$PATH"; prreview_service_restart macos >/dev/null 2>&1 )
is 'restart on macOS re-enables before a kickstart that works, so a stopped service comes back at login' \
   "$(tr '\n' ' ' < "$T/launchctl.log")" 'enable kickstart '
printf '#!/bin/sh\necho "$1" >> "%s"\ncase "$1" in kickstart) exit 113 ;; esac\n' "$T/launchctl.log" > "$T/lbin/launchctl"
: > "$T/launchctl.log"
( PATH="$T/lbin:$PATH"; prreview_service_stop macos >/dev/null 2>&1 )
is 'stop on macOS disables the service before unloading it, so the next login leaves it off' \
   "$(tr '\n' ' ' < "$T/launchctl.log")" 'disable bootout '
: > "$T/launchctl.log"
( PATH="$T/lbin:$PATH"; prreview_service_start macos >/dev/null 2>&1 )
is 'start on macOS enables the service before loading it' "$(tr '\n' ' ' < "$T/launchctl.log")" 'enable bootstrap '
# A bootout that fails on a service that is not loaded is already stopped; one
# that fails on a loaded service must fail loudly, with launchctl's reason.
printf '#!/bin/sh\ncase "$1" in bootout) echo "Boot-out failed: 5" >&2; exit 5 ;; print) exit %s ;; esac\n' 113 > "$T/lbin/launchctl"
is 'stop on macOS succeeds when the service was not loaded anyway' \
   "$( (PATH="$T/lbin:$PATH"; prreview_service_stop macos 2>&1; echo "rc=$?") )" 'rc=0'
printf '#!/bin/sh\ncase "$1" in bootout) echo "Boot-out failed: 5" >&2; exit 5 ;; print) exit 0 ;; esac\n' > "$T/lbin/launchctl"
is 'stop on macOS fails with the reason when the service stays loaded' \
   "$( (PATH="$T/lbin:$PATH"; prreview_service_stop macos 2>&1; echo "rc=$?") )" "$(printf 'Boot-out failed: 5\nrc=1')"
has 'the unit restarts the loop when it stops' "$UNIT" 'Restart=always'
is 'the unit does not wait for a target a user manager lacks' "$(grep -c network-online <<<"$UNIT")" 0
is 'a % in the log path is escaped for systemd, in both log lines' \
   "$(prreview_systemd_unit /opt/prreview '/var/log/100%/gate.log' | grep -c 'append:/var/log/100%%/gate.log$')" 2
is 'uninstall on a system without a service says so' "$(prreview_service_remove unsupported 2>&1; echo "rc=$?")" "$(printf 'no background service on this system\nrc=1')"

# ── setup, answered from stdin ────────────────────────────────────────────
FAKE="$T/bin"; mkdir -p "$FAKE"
cat > "$FAKE/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "--version"*) printf 'gh version %s (2024-11-27)\n' "${FAKE_GH_VERSION:-2.63.0}" ;;
  "auth status") exit 0 ;;
  "api user") echo me ;;
  "repo list") printf 'me/api\nme/web\n' ;;
  "repo view") r="${3#https://github.com/}"; [ "$r" != me/old ] || r=me/new
               case "$r" in me/*|acme/*) echo "$r" ;; *) exit 1 ;; esac ;;
  "config get") echo "${FAKE_GH_PROTOCOL:-https}" ;;
  "config set") echo "$*" >> "${FAKE_GH_SET_LOG:-/dev/null}"; echo "gh config set" >> "${FAKE_ORDER_LOG:-/dev/null}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE/gh"
# claude answers only `--version` (FAKE_CLAUDE_VERSION, default 2.1.305) and
# `auth status`, logged in unless FAKE_CLAUDE_LOGGED says not.
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] && { printf '%s (Claude Code)\n' "${FAKE_CLAUDE_VERSION:-2.1.305}"; exit 0; }
[ "$1 $2" = "auth status" ] || exit 0
printf '{"loggedIn":%s}\n' "${FAKE_CLAUDE_LOGGED:-true}"
[ "${FAKE_CLAUDE_LOGGED:-true}" = true ]
EOF
chmod +x "$FAKE/claude"
# Tools this machine lacks get a stub: setup only checks they exist.
# timeout and sha256sum are not in the list. Setup also accepts gtimeout,
# gsha256sum and shasum, and a stub named timeout would win over them.
for t in git jq flock curl openssl; do
  command -v "$t" >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 0\n' > "$FAKE/$t"; chmod +x "$FAKE/$t"; }
done
H="$T/home"; mkdir -p "$H"
# XDG_CONFIG_HOME points elsewhere on purpose: the service never sees it,
# so prreview must not follow it either.
# EDITOR is not in PRREVIEW_ENV: env's own assignment would override one given
# per call. TEST_EDITOR picks it (default: an editor that changes nothing).
# PRREVIEW_SYSTEMD_RUN_DIR points at nothing, so the machine running the tests
# does not decide what they see: a CI runner boots with systemd, a container
# does not, and prreview asks systemd a question only on the first. The cases
# about systemd set it themselves.
PRREVIEW_ENV=(env HOME="$H" XDG_CONFIG_HOME="$T/xdg" PATH="$FAKE:$PATH" GH_BIN="$FAKE/gh" PRREVIEW_PLATFORM=unsupported PRREVIEW_SYSTEMD_RUN_DIR="$T/no-systemd")
prreview() { "${PRREVIEW_ENV[@]}" EDITOR="${TEST_EDITOR:-true}" bash "$ROOT/prreview" "$@"; }
CFG="$H/.config/pr-reviewer/config"

has 'start refuses before any repository is set' "$(prreview start 2>&1)" 'run prreview setup first'
has '...and so does once' "$(prreview once 2>&1)" 'run prreview setup first'
# Under a deadline: the bug this guards against is a setup that never ends.
OUT="$("$TIMEOUT_BIN" 30 "${PRREVIEW_ENV[@]}" EDITOR=true bash "$ROOT/prreview" setup </dev/null 2>&1)"; RC=$?
has 'setup with no input stops, instead of answering the default forever' "$OUT" 'no more input; stopped'
is '...with a failure status' "$RC" 1

# repos: number 1 plus a name; identity: the gh account; parallel: "zero"
# is refused, retry, 3; model: Enter keeps the default; patterns: do not
# edit; checks: copy.
OUT="$(printf '1 acme/web\n1\nzero\ny\n3\n\nn\ny\n' | prreview setup 2>&1)"; RC=$?
is 'setup finishes' "$RC" 0
is 'setup keeps the picked repositories, list number and name' "$(prreview_config_get "$CFG" PRREVIEW_GATE_REPOS)" 'me/api acme/web'
has 'a bad number is explained' "$OUT" 'Give a whole number'
is '...and the retry is kept' "$(prreview_config_get "$CFG" PRREVIEW_GATE_PARALLEL)" 3
is 'the default model is not written down' "$(grep -c '^PRREVIEW_REVIEW_MODEL=' "$CFG")" 0
is 'the sensitive-data patterns start from the example' "$(cmp -s sensitive-patterns.example "$H/.config/pr-reviewer/sensitive-patterns" && echo same)" same
is '...and are private to their owner' "$(ls -l "$H/.config/pr-reviewer/sensitive-patterns" | cut -c1-10)" '-rw-------'
is 'the checklist is copied for editing' "$(ls "$H/.config/pr-reviewer/checks" | wc -l | tr -d ' ')" "$(ls checks | wc -l | tr -d ' ')"
is '...and used' "$(prreview_config_get "$CFG" PRREVIEW_GATE_CHECKS_DIR)" "$H/.config/pr-reviewer/checks"
is 'the terminal PATH is recorded for the service' "$(prreview_config_get "$CFG" PATH)" "$FAKE:$PATH"
is 'the patterns file is recorded, so the gate reads the one setup wrote' \
   "$(prreview_config_get "$CFG" PRREVIEW_SENSITIVE_PATTERNS_FILE)" "$H/.config/pr-reviewer/sensitive-patterns"
is 'nothing is written under XDG_CONFIG_HOME' "$([ -e "$T/xdg" ] && echo written || echo none)" none
has 'with no service here, it says how to run it' "$OUT" "Run 'prreview run' yourself"
has 'setup names its steps as the README does' "$OUT" '── Who posts'
# No service manager here (PRREVIEW_PLATFORM=unsupported), so no service runs.
has 'setup with no service running ends by pointing at prreview run' "$OUT" "'prreview run' reviews from this terminal"
cp "$ROOT/prreview" "$T/ph/Documents/prreview/" && cp -R "$ROOT/lib" "$T/ph/Documents/prreview/"
OUT="$("${PRREVIEW_ENV[@]}" HOME="$T/ph" PRREVIEW_PLATFORM=macos bash "$T/ph/Documents/prreview/prreview" setup </dev/null 2>&1)"
has 'on macOS, setup from a protected folder stops before the first question' "$OUT" 'Move the clone'
has '...and prints the command that moves it' "$OUT" "&& cd ~/pr-reviewer && ./prreview setup"
case "$OUT" in *'── Tools'*) bad '...before the first question' 'no steps' "$OUT" ;; *) ok '...before the first question' ;; esac
OUT="$(printf 'y\n' | "${PRREVIEW_ENV[@]}" HOME="$T/ph" PRREVIEW_PLATFORM=macos bash "$T/ph/Documents/prreview/prreview" setup 2>&1)"
has '...unless the user chooses to run it only in a terminal' "$OUT" '── Tools'

OUT="$(printf 'n\n' | FAKE_CLAUDE_LOGGED=false prreview setup 2>&1)"
has 'setup stops at Claude Code when it is not logged in' "$OUT" "setup stopped at 'Claude Code'"
has '...and says how to log in' "$OUT" 'claude auth login'
OUT="$(printf 'n\n' | FAKE_CLAUDE_VERSION=2.1.304 prreview setup 2>&1)"
has 'setup stops at Claude Code when it is older than 2.1.305' "$OUT" "setup stopped at 'Claude Code'"
has '...and names the version it needs' "$OUT" '2.1.305 or later'
OUT="$(printf 'n\n' | FAKE_GH_VERSION=2.62.0 prreview setup 2>&1)"
has 'setup stops at GitHub when gh is older than 2.63.0' "$OUT" "setup stopped at 'GitHub'"
has '...and names the version it needs' "$OUT" '2.63.0 or later'
has '...and the version it found' "$OUT" 'gh version 2.62.0'
is 'WSL 1 is told apart by its kernel string' "$(prreview_is_wsl1 'Linux version 9.9.9-Microsoft' && echo 1)" 1
is '...from WSL 2' "$(prreview_is_wsl1 'Linux version 9.9.9-microsoft-standard-WSL2' || echo 2)" 2
OUT="$(printf 'nobody/else\nn\n' | prreview setup 2>&1)"
has 'a repository gh cannot see stops setup at that step' "$OUT" 'Cannot see nobody/else'
is '...and the earlier answer stays' "$(prreview_config_get "$CFG" PRREVIEW_GATE_REPOS)" 'me/api acme/web'

# ── everyday commands ─────────────────────────────────────────────────────
has 'repos add says what it added' "$(prreview repos add me/web)" 'Added me/web.'
is 'repos add appends' "$(prreview repos | tr '\n' ' ')" 'me/api acme/web me/web '
has 'repos add refuses a repository gh cannot see' "$(prreview repos add nobody/else 2>&1)" 'cannot see nobody/else'
prreview repos add https://github.com/acme/tools >/dev/null
is 'repos add stores a URL as owner/repo' "$(prreview repos | grep -cxF acme/tools)/$(prreview repos | grep -c https)" 1/0
prreview repos remove https://github.com/acme/tools >/dev/null
is 'repos remove takes the same URL repos add did' "$(prreview repos | grep -c acme/tools)" 0
has 'set repos refuses an empty list' "$(prreview set repos '' 2>&1)" 'at least one repository'
has 'unset repos is refused' "$(prreview unset repos 2>&1)" 'at least one repository'
mkdir -p "$T/one"; cp "$ROOT/checks/01-"*.md "$T/one/"
has 'checks remove refuses the last item' "$(PRREVIEW_GATE_CHECKS_DIR="$T/one" prreview checks remove 1 </dev/null 2>&1)" 'last item'
mkdir -p "$H/Downloads"; printf 'secret\n' > "$H/Downloads/pat"
has 'on macOS, a patterns file the service cannot read is refused' \
   "$(env HOME="$H" PATH="$FAKE:$PATH" GH_BIN="$FAKE/gh" PRREVIEW_PLATFORM=macos bash "$ROOT/prreview" set patterns "$H/Downloads/pat" 2>&1)" 'macOS does not let the background service read'
P_BEFORE="$(prreview get parallel)"
has 'set repos refuses anything but owner/repo' "$(prreview set repos 'https://github.com/a/b' 2>&1)" 'is not owner/repo'
has 'set checks refuses a folder that is not a usable checklist' "$(prreview set checks "$T/no-such" 2>&1)" 'not a usable checklist'
has 'set patterns refuses a missing file' "$(prreview set patterns "$T/no-such" 2>&1)" 'missing or empty'
has 'set parallel refuses a word' "$(prreview set parallel many 2>&1)" 'whole number'
is '...and none of those was written' "$(prreview get parallel)" "$P_BEFORE"
prreview repos remove acme/web >/dev/null
is 'repos remove drops one' "$(prreview repos | tr '\n' ' ')" 'me/api me/web '
prreview set parallel 5 >/dev/null
is 'set takes a friendly name' "$(prreview get parallel)" 5
has 'set refuses a misspelled setting' "$(prreview set PRREVIEW_GATE_PARALEL 5 2>&1)" 'not a setting the reviewer reads'
has 'set refuses a name that is not a setting' "$(prreview set bogus 1 2>&1)" 'not a setting name'
# PRREVIEW_ONCE_PR names the PR of one `prreview once --pr` run. As a setting
# it would name the same PR in every round of the loop.
is 'PRREVIEW_ONCE_PR is not a setting name' "$(prreview_key_of PRREVIEW_ONCE_PR || echo refused)" refused
has 'the settings file refuses to store it' "$(prreview_config_set "$T/once-set" PRREVIEW_ONCE_PR 'a/b#5' 2>&1)" 'not a setting name: PRREVIEW_ONCE_PR'
is '...and holds nothing after the refusal' "$([ -e "$T/once-set" ] && echo written || echo none)" none
printf 'PRREVIEW_GATE_REPOS=a/b\nPRREVIEW_ONCE_PR=a/b#5\n' > "$T/once"
is 'a settings file that holds it is refused, naming the line' "$(prreview_config_read "$T/once" 2>&1 >/dev/null | cut -d: -f2)" 2
has '...and the message says how the key is set' "$(prreview_config_read "$T/once" 2>&1 >/dev/null)" 'prreview once --pr'
has 'set refuses it' "$(prreview set PRREVIEW_ONCE_PR a/b#5 2>&1)" 'not a setting name: PRREVIEW_ONCE_PR'
OUT="$(prreview bogus 2>&1)"; RC=$?
has 'an unknown command is named' "$OUT" 'unknown command: bogus'
is '...and is a usage error' "$RC" 2
OUT="$(prreview uninstall 2>&1)"; RC=$?
has 'uninstall with nothing installed says so' "$OUT" 'not installed; nothing to remove'
is '...and succeeds' "$RC" 0
has 'help lists checks path' "$(prreview help)" 'prreview checks path'
has 'unset says so' "$(prreview unset parallel)" 'PRREVIEW_GATE_PARALLEL is back to its default'
is 'get then prints the default the reviewer uses' "$(prreview get parallel 2>/dev/null)" 2
has '...and says so on stderr' "$(prreview get parallel 2>&1 >/dev/null)" 'that is the default'
has '...the model too' "$(prreview get model)" 'claude-'
has 'checks lists the items with their numbers' "$(prreview checks)" '2b   02b-ai-agent-security'
printf 'y\n' | prreview checks remove 5 >/dev/null 2>&1
is 'checks remove deletes the item from your copy' "$(find "$H/.config/pr-reviewer/checks" -name '05-*' | wc -l | tr -d ' ')" 0
has 'checks remove will not touch the built-in list' "$(PRREVIEW_GATE_CHECKS_DIR="$ROOT/checks" prreview checks remove 6 </dev/null 2>&1)" 'built-in checklist'
has '...spelled with a trailing slash either' "$(PRREVIEW_GATE_CHECKS_DIR="$ROOT/checks/" prreview checks remove 6 </dev/null 2>&1)" 'built-in checklist'
has 'checks add will not write into the built-in list' "$(PRREVIEW_GATE_CHECKS_DIR="$ROOT/checks/" prreview checks add 50-x </dev/null 2>&1)" 'built-in checklist'
has 'checks lists a built-in item the copy lacks' "$(prreview checks)" 'Built-in items not in this copy: 05-'
MYCHECKS="$H/.config/pr-reviewer/checks"
cp "$MYCHECKS/06-"*.md "$MYCHECKS/06-dup.md"
has 'checks remove with two files for one number deletes neither, and says so' "$(prreview checks remove 6 </dev/null 2>&1)" 'more than one file is item 6'
is '...both are still there' "$(find "$MYCHECKS" -name '06-*' | wc -l | tr -d ' ')" 2
rm -f "$MYCHECKS/06-dup.md"
# The template says everything from --- to --- can go; an editor that does
# exactly that must leave a usable item of one line. EDITOR carries an
# argument, as EDITOR="code --wait" does; the file is its last one.
printf '#!/bin/sh\nfor f; do :; done\nsed -i.bak "1,/^---\$/d" "$f" && rm -f "$f.bak"\n' > "$T/dropfm"; chmod +x "$T/dropfm"
OUT="$(TEST_EDITOR="$T/dropfm --wait" prreview checks add 50-migrations </dev/null 2>&1)"
has 'checks add says what it added and where' "$OUT" "Added $MYCHECKS/50-migrations.md."
is 'the editor ran and removed the front matter' "$(wc -l < "$MYCHECKS/50-migrations.md" | tr -d ' ')" 1
OUT="$(TEST_EDITOR="$T/no-such-editor" prreview checks add 51-broken </dev/null 2>&1)"
has 'an editor that does not run leaves no item behind, and says so' "$OUT" 'did not run or failed'
is '...no file' "$([ -e "$MYCHECKS/51-broken.md" ] && echo left || echo none)" none
is 'deleting the front matter the template names leaves a usable item' \
   "$(env HOME="$H" bash -c ". lib/review-spec.sh; review_checks_render '$MYCHECKS' 'x.txt' | grep -c '^50\. migrations'")" 1
has 'checks add refuses a number another item has, before writing anything' "$(prreview checks add 050-hotfix </dev/null 2>&1)" 'item 050 is taken'
is '...so no file is left behind' "$([ -e "$MYCHECKS/050-hotfix.md" ] && echo left || echo none)" none
rm -f "$MYCHECKS/50-migrations.md"
# The editor closed with the template as it was: that text would go to the
# model on every PR, so nothing is added.
has 'checks add with the template left as it is adds nothing' "$(prreview checks add 51-untouched </dev/null 2>&1)" 'not changed, so it was not added'
is '...and leaves no file behind' "$(find "$MYCHECKS" -name '51-*' | wc -l | tr -d ' ')" 0
ln -s "$ROOT/prreview" "$T/prreview-link"
has 'prreview runs through a symlink, finding lib/ next to the real file' \
   "$(env HOME="$H" PATH="$FAKE:$PATH" PRREVIEW_PLATFORM=unsupported bash "$T/prreview-link" status 2>&1)" 'Repositories:'
cp "$CFG" "$T/cfg.bak"; printf 'repos = oops\n' >> "$CFG"
has 'a malformed settings file stops every command, not just some' "$(prreview status 2>&1)" 'fix '
cp "$T/cfg.bak" "$CFG"
has 'status shows the repositories' "$(prreview status)" 'me/api me/web'
has 'status says comments come from the gh account' "$(prreview status)" 'your gh account'
# Enter keeps the repositories, the gh account, parallel and model;
# patterns: no edit; checks: item 5 is missing from the copy, and y copies
# it back.
# One of the user's own items holding number 5: the built-in 05 must not be
# copied beside it, or every round stops on two files for one number.
printf 'mine\n' > "$MYCHECKS/05-mine.md"
OUT="$(printf '\n\n\n\nn\ny\n' | prreview setup 2>&1)"
has 'setup skips a built-in item whose number one of yours has, and says why' "$OUT" 'Skipped 05-tests.md: item 05 is already 05-mine.md'
is '...leaving one file for that number' "$(find "$MYCHECKS" -name '05-*' | wc -l | tr -d ' ')" 1
rm -f "$MYCHECKS/05-mine.md"
OUT="$(printf '\n\n\n\nn\ny\n' | prreview setup 2>&1)"
has 'setup offers the built-in items the copy lacks' "$OUT" '05-'
is '...and copies them back on yes' "$(find "$MYCHECKS" -name '05-*' | wc -l | tr -d ' ')" 1
is 'Enter at the parallel step does not write the default down' "$(grep -c '^PRREVIEW_GATE_PARALLEL=' "$CFG")" 0
cp -R "$MYCHECKS" "$T/team"
prreview set checks "$T/team" >/dev/null
printf '\n\n\n\nn\n' | prreview setup >/dev/null 2>&1
is 'setup keeps a checklist chosen with prreview set checks' "$(prreview get checks)" "$T/team"
prreview set checks "$MYCHECKS" >/dev/null
# ── the service question and the gh https question ───────────────────────
# The service question defaults to n while no service is installed and to y
# while one is. The https question belongs to the service: it is asked only
# where the service is installed or started. The unit file in $H decides
# "installed"; this systemctl logs its calls and succeeds, so a started
# service reads as running.
D2="$T/d2"; mkdir -p "$D2"
# With FAKE_SYSTEMCTL_STOPPED set, is-active fails, so an installed service
# reads as stopped.
printf '#!/bin/sh\necho "$*" >> "%s"\necho "systemctl $*" >> "${FAKE_ORDER_LOG:-/dev/null}"\ncase "$*" in *is-active*) [ -z "$FAKE_SYSTEMCTL_STOPPED" ] || exit 3 ;; esac\n' "$D2/systemctl.log" > "$D2/systemctl"; chmod +x "$D2/systemctl"
UNIT_FILE="$H/.config/systemd/user/$PRREVIEW_SERVICE_NAME.service"
# d2_via <runner> <gh git_protocol> <prreview arguments>: on Linux; gh records
# config set. The runner (a command name, or empty) starts the command.
d2_via() {
  local run="$1" proto="$2"; shift 2
  $run "${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$D2:$FAKE:$PATH" FAKE_GH_PROTOCOL="$proto" FAKE_GH_SET_LOG="$D2/ghset.log" FAKE_ORDER_LOG="$D2/order.log" bash "$ROOT/prreview" "$@"
}
d2() { d2_via "" "$@"; }
# pty_run <command...>: runs the command with a terminal on stdin and stdout.
# This script's stdin gives the typed answers. script(1) from util-linux takes
# the command as a string. The BSD one on macOS takes it as arguments. A
# deadline stops a terminal that waits for input for good.
pty_run() {
  if script --version >/dev/null 2>&1; then
    "$TIMEOUT_BIN" 30 script -qec "$(printf '%q ' "$@")" /dev/null
  else
    "$TIMEOUT_BIN" 30 script -q /dev/null "$@"
  fi
}
d2_tty() { d2_via pty_run "$@"; }
d2_reset() { rm -f "$UNIT_FILE" "$D2/ghset.log" "$D2/order.log"; : > "$D2/systemctl.log"; }
# Five answers for the steps before the service question: Enter for the
# repositories, who posts, parallel and model; n for the patterns file.
D2_STEPS='\n\n\n\nn\n'

d2_reset
OUT="$(printf "${D2_STEPS}\n" | d2 ssh setup 2>&1)"
has 'the service question defaults to n while no service is installed' "$OUT" 'starts at login)? (y/n) [n]: '
is '...so Enter installs nothing' "$([ -e "$UNIT_FILE" ] && echo installed || echo none)" none
is '...asks nothing about gh, though it clones over ssh' "$(grep -c 'no ssh-agent' <<<"$OUT")" 0
is '...and does not call gh config set' "$(cat "$D2/ghset.log" 2>/dev/null)" ''

d2_reset
OUT="$(printf "${D2_STEPS}n\n" | d2 ssh setup 2>&1)"
is 'n to the service question does not call gh config set' "$(cat "$D2/ghset.log" 2>/dev/null)" ''

d2_reset; mkdir -p "$(dirname "$UNIT_FILE")"; : > "$UNIT_FILE"
OUT="$(printf "${D2_STEPS}\n" | d2 https setup 2>&1)"
has 'the service question defaults to y while a service is installed' "$OUT" 'starts at login)? (y/n) [y]: '
has '...so Enter reinstalls it and restarts it' "$(cat "$D2/systemctl.log")" "--user restart $PRREVIEW_SERVICE_NAME"

d2_reset
OUT="$(printf "${D2_STEPS}y\ny\n" | d2 ssh setup 2>&1)"
has 'y to the service question: setup warns when gh clones over ssh' "$OUT" 'no ssh-agent'
is '...and switches gh to https on yes' "$(cat "$D2/ghset.log" 2>/dev/null)" 'config set git_protocol https -h github.com'
is '...and installs the service' "$([ -e "$UNIT_FILE" ] && echo installed || echo none)" installed
is '...and gh config set comes before the first systemctl call' "$(head -n1 "$D2/order.log")" 'gh config set'

d2_reset
printf "${D2_STEPS}y\nn\n" | d2 ssh setup >/dev/null 2>&1
is 'n to the https question leaves gh alone' "$(cat "$D2/ghset.log" 2>/dev/null)" ''
is '...and the service is installed anyway' "$([ -e "$UNIT_FILE" ] && echo installed || echo none)" installed

# prreview start. A service that is not installed is installed here, and the
# https question belongs to that step. With no terminal on stdin, start prints
# the advice and the command and asks nothing: it must not stop at the end of
# the input. A service that is installed starts or runs with no question.
d2_reset
OUT="$(d2 ssh start </dev/null 2>&1)"; RC=$?
is 'start with no terminal installs the service while gh clones over ssh' "$RC" 0
is '...and does install it' "$([ -e "$UNIT_FILE" ] && echo installed || echo none)" installed
has '...says why ssh can fail' "$OUT" 'no ssh-agent'
has '...prints the command that switches gh' "$OUT" "gh config set git_protocol https -h github.com"
is '...asks nothing, so it does not stop at the end of the input' "$(grep -c 'no more input' <<<"$OUT")" 0
is '...and leaves gh alone' "$(cat "$D2/ghset.log" 2>/dev/null)" ''
d2_reset
OUT="$(d2 https start </dev/null 2>&1)"
is 'start with no terminal prints no https advice when gh already uses https' "$(grep -c 'no ssh-agent' <<<"$OUT")" 0
OUT="$(d2 ssh start </dev/null 2>&1)"
has 'start asks nothing when the service already runs' "$OUT" 'Already running'
is '...and gives no advice' "$(grep -c 'no ssh-agent' <<<"$OUT")" 0

# A stopped service that is installed: start starts it and asks nothing, with
# or without a terminal.
d2_reset; mkdir -p "$(dirname "$UNIT_FILE")"; : > "$UNIT_FILE"
OUT="$(FAKE_SYSTEMCTL_STOPPED=1 d2 ssh start </dev/null 2>&1)"; RC=$?
is 'start of a stopped service starts it' "$RC" 0
has '...with enable --now' "$(cat "$D2/systemctl.log")" "--user enable --now $PRREVIEW_SERVICE_NAME"
has '...and says Started' "$OUT" 'Started.'
is '...asks nothing, so it does not stop at the end of the input' "$(grep -c 'no more input' <<<"$OUT")" 0
is '...gives no https advice' "$(grep -c 'no ssh-agent' <<<"$OUT")" 0
is '...and leaves gh alone' "$(cat "$D2/ghset.log" 2>/dev/null)" ''

# With a terminal, answers typed to the https question reach gh. A pty needs
# script(1). Trade-off: a system whose script cannot give a terminal skips
# these cases, and the Linux runs of the suite check them.
if [ "$(printf '' | pty_run bash -c 'test -t 0 && echo tty' 2>/dev/null | tr -d '\r')" = tty ]; then
  d2_reset
  printf 'y\n' | d2_tty ssh start >/dev/null 2>&1
  is 'start at a terminal asks about https where it installs the service, and switches on yes' "$(cat "$D2/ghset.log" 2>/dev/null)" 'config set git_protocol https -h github.com'
  is '...and installs it' "$([ -e "$UNIT_FILE" ] && echo installed || echo none)" installed
  d2_reset
  printf 'n\n' | d2_tty ssh start >/dev/null 2>&1
  is 'start at a terminal with n to the https question leaves gh alone' "$(cat "$D2/ghset.log" 2>/dev/null)" ''
  is '...and still installs the service' "$([ -e "$UNIT_FILE" ] && echo installed || echo none)" installed
  d2_reset; mkdir -p "$(dirname "$UNIT_FILE")"; : > "$UNIT_FILE"
  printf 'y\n' | FAKE_SYSTEMCTL_STOPPED=1 d2_tty ssh start >/dev/null 2>&1
  is 'start at a terminal does not ask when it starts a stopped service' "$(cat "$D2/ghset.log" 2>/dev/null)" ''
else
  echo '  skip start at a terminal: script(1) gives no terminal here'
fi
rm -f "$UNIT_FILE"

# ── setup with a GitHub App ───────────────────────────────────────────────
# curl answers for an App that can see me/api but not acme/web; the key is
# a throwaway, the App id a made-up number.
openssl genrsa -out "$T/app.pem" 2048 2>/dev/null
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/repos/me/api/installation"*) echo '{"id":55}' ;;
  *"/app/installations/55/access_tokens"*) echo '{"token":"tok"}' ;;
  *"/app") echo '{"slug":"my-reviewer"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$FAKE/curl"
prreview set repos 'me/api acme/web' >/dev/null
# Enter keeps the repositories; App id 12345 and the key; acme/web is out
# of the App's reach, so the step stops there.
OUT="$(printf '\n2\n12345\n%s\nn\n' "$T/app.pem" | prreview setup 2>&1)"
has 'the App step links to a pre-filled App page' "$OUT" 'settings/apps/new?name=pr-reviewer-me&'
has 'a repository the App cannot see is named, with where to install it' "$OUT" 'cannot see: acme/web'
is '...and nothing is saved' "$(prreview get PRREVIEW_REVIEW_APP_ID)" ''
prreview repos remove acme/web >/dev/null
OUT="$(printf '\n2\n12345\n%s\n5\n\nn\n' "$T/app.pem" | prreview setup 2>&1)"
has 'with the App on every repository, comments come from its bot' "$OUT" 'Comments will come from my-reviewer[bot].'
is 'the App id is saved' "$(prreview get PRREVIEW_REVIEW_APP_ID)" 12345
is 'the slug is not pinned: the gate reads the current one from GitHub' "$(prreview get PRREVIEW_REVIEW_APP_SLUG)" ''
KEY="$H/.config/pr-reviewer/app.pem"
is 'the key is copied next to the settings, private' "$(ls -l "$KEY" | cut -c1-10)" '-rw-------'
has 'status says comments come from the App' "$(prreview status)" 'GitHub App 12345'
# Giving the copy itself as the key, by another spelling, must keep it.
ln -s "$KEY" "$T/key-link"
OUT="$(printf '\n2\n12345\n%s\n5\n\nn\n' "$T/key-link" | prreview setup 2>&1)"
is 'the copied key given back through a symlink is not copied over itself' "$(grep -c 'Copied the key to' <<<"$OUT")" 0
is '...and survives' "$(cmp -s "$KEY" "$T/app.pem" && echo same)" same
# A key GitHub rejects (curl fails for everything) must not replace the one
# that works.
openssl genrsa -out "$T/other.pem" 2048 2>/dev/null
mv "$FAKE/curl" "$FAKE/curl.ok"; printf '#!/bin/sh\nexit 22\n' > "$FAKE/curl"; chmod +x "$FAKE/curl"
printf '\n2\n12345\n%s\nn\n' "$T/other.pem" | prreview setup >/dev/null 2>&1
mv "$FAKE/curl.ok" "$FAKE/curl"
is 'a rejected key leaves the working one in place' "$(cmp -s "$KEY" "$T/app.pem" && echo same)" same
# curl that cannot reach GitHub at all (exit 6: host not resolved) is not a
# rejected key, and must not be reported as one.
mv "$FAKE/curl" "$FAKE/curl.ok"; printf '#!/bin/sh\nexit 6\n' > "$FAKE/curl"; chmod +x "$FAKE/curl"
OUT="$(printf '\n2\n12345\n%s\nn\n' "$T/other.pem" | prreview setup 2>&1)"
mv "$FAKE/curl.ok" "$FAKE/curl"
has 'no network is reported as no network, not as a rejected key' "$OUT" 'Could not reach api.github.com'
is '...and the working key stays' "$(cmp -s "$KEY" "$T/app.pem" && echo same)" same
prreview unset PRREVIEW_REVIEW_APP_SLUG
prreview set PRREVIEW_REVIEW_APP_ID 777 >/dev/null
has 'status goes by the App id, as the gate does' "$(prreview status)" 'GitHub App 777'
OUT="$(printf '\n1\n5\n\nn\n' | prreview setup 2>&1)"
is 'going back to the gh account clears the App' "$(prreview get PRREVIEW_REVIEW_APP_ID)" ''

# ── follow-ups ────────────────────────────────────────────────────────────
has 'set repos refuses a value that is only a tab' "$(prreview set repos "$(printf '\t')" 2>&1)" 'at least one repository'
has 'set refuses a timeout that is not a number' "$(prreview set PRREVIEW_GATE_REVIEW_TIMEOUT 15m 2>&1)" 'whole number'
has 'set refuses a switch that is not 0 or 1' "$(prreview set PRREVIEW_GATE_REDTEAM 2 2>&1)" '0 (off) or 1 (on)'
has '...every one of them' "$(prreview set PRREVIEW_GATE_SYMBOLS 2 2>&1)" '0 (off) or 1 (on)'
has 'set refuses a severity the reviewer does not know' "$(prreview set PRREVIEW_GATE_ISSUE_MIN_SEVERITY hihg 2>&1)" 'critical, high, medium or low'
prreview set PRREVIEW_GATE_ISSUE_MIN_SEVERITY MEDIUM >/dev/null
is '...and stores a known one in lower case' "$(prreview get PRREVIEW_GATE_ISSUE_MIN_SEVERITY)" medium
prreview unset PRREVIEW_GATE_ISSUE_MIN_SEVERITY >/dev/null
has 'set refuses an alert repo that is not owner/repo' "$(prreview set PRREVIEW_ALERT_REPO nonsense 2>&1)" 'owner/repo'
is 'a numeric default is read from the reviewer itself' "$(prreview_key_default "$ROOT" PRREVIEW_LOOP_INTERVAL)" 60
has '...so a loop setting is checked too, with no list to keep up' "$(prreview set PRREVIEW_LOOP_INTERVAL 5m 2>&1)" 'whole number'
has '...and so is one only a lib reads' "$(prreview set PRREVIEW_GATE_HOLDOFF_MAX 1h 2>&1)" 'whole number'
has 'set refuses 0 where the reviewer would refuse to start' "$(prreview set PRREVIEW_GATE_HOLDOFF_MAX 0 2>&1)" '1 or more'
has '...and 00, which the reviewer reads as 0' "$(prreview set PRREVIEW_LOOP_IDLE_EVERY 00 2>&1)" '1 or more'
has 'the stall alert limit takes 2 or more' "$(prreview set PRREVIEW_LOOP_READY_FAIL_LIMIT 1 2>&1)" '2 or more'
has 'an App id is a number although its default is empty' "$(prreview set PRREVIEW_REVIEW_APP_ID Iv1.abc123 2>&1)" 'whole number'
prreview set PRREVIEW_LOOP_BASH bin/bash >/dev/null
is 'a setting whose default is worked out at run time is still stored absolute' "$(prreview get PRREVIEW_LOOP_BASH)" "$ROOT/bin/bash"
prreview unset PRREVIEW_LOOP_BASH
prreview set PRREVIEW_LOOP_BASH bash >/dev/null
is 'a bare program name is looked up on PATH, not tied to this directory' "$(prreview get PRREVIEW_LOOP_BASH)" "$(command -v bash)"
prreview set GH_BIN bin/gh >/dev/null
is 'the gh and claude programs take the same rule' "$(prreview get GH_BIN)" "$ROOT/bin/gh"
prreview unset GH_BIN
prreview set PRREVIEW_GATE_HOLDOFF_DIR holdoff >/dev/null
prreview set PRREVIEW_GATE_HOLDOFF_DIR "" >/dev/null
is 'an empty path clears the setting, as unset does' "$(grep -c '^PRREVIEW_GATE_HOLDOFF_DIR=' "$CFG")" 0
prreview set PRREVIEW_GATE_ZERO_RECHECK_LINES 0 >/dev/null
is 'a 0 is kept where it means something' "$(prreview get PRREVIEW_GATE_ZERO_RECHECK_LINES)" 0
prreview unset PRREVIEW_GATE_ZERO_RECHECK_LINES
prreview set PRREVIEW_GATE_HOLDOFF_DIR holdoff >/dev/null
is 'any setting whose default is a path is stored absolute' "$(prreview get PRREVIEW_GATE_HOLDOFF_DIR)" "$ROOT/holdoff"
prreview unset PRREVIEW_GATE_HOLDOFF_DIR
prreview set PRREVIEW_GATE_WORKROOT work >/dev/null
is 'a relative workroot is stored absolute' "$(prreview get PRREVIEW_GATE_WORKROOT)" "$ROOT/work"
prreview unset PRREVIEW_GATE_WORKROOT
REPOS_BEFORE="$(prreview get repos)"
prreview set repos "$REPOS_BEFORE me/old" >/dev/null
prreview repos remove me/old >/dev/null
is 'a repository renamed on GitHub is removed by its old name' "$(prreview get repos)" "$REPOS_BEFORE"
mkdir -p "$T/sysd"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/systemctl.log" > "$T/sysd/systemctl"; chmod +x "$T/sysd/systemctl"
OUT="$(printf '\n\n\n\nn\ny\n' | "${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" EDITOR=true bash "$ROOT/prreview" setup 2>&1)"
has 'on Linux, setup restarts a service it (re)installed, so new settings apply' "$(cat "$T/systemctl.log" 2>/dev/null)" "--user restart $PRREVIEW_SERVICE_NAME"
has '...and ends by saying the service runs, from what it did rather than a second look' "$OUT" "Done. The service is running"
# A restart that fails usually means the service stopped: setup must say
# so, not claim it still runs on the old settings.
printf '#!/bin/sh\ncase "$*" in *restart*|*is-active*) exit 3 ;; esac\n' > "$T/sysd/systemctl"
OUT="$(printf '\n\n\n\nn\ny\n' | "${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" EDITOR=true bash "$ROOT/prreview" setup 2>&1)"
has 'a failed restart of a stopped service says it is not running' "$OUT" 'the service is not running'
has '...and setup ends by saying so' "$OUT" 'not running in the background'
printf '#!/bin/sh\ncase "$*" in *restart*) exit 1 ;; esac\n' > "$T/sysd/systemctl"
OUT="$(printf '\n\n\n\nn\ny\n' | "${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" EDITOR=true bash "$ROOT/prreview" setup 2>&1)"
has 'a failed restart of a running service says it keeps the old settings' "$OUT" 'keeps its old settings'
is '...and setup does not then call it stopped' "$(grep -c 'not running in the background' <<<"$OUT")" 0
# prreview set restarts a running service the same way, and a restart that
# leaves it stopped must be said there too.
printf '#!/bin/sh\ncase "$*" in *restart*) exit 1 ;; *is-active*) [ -f "%s" ] && exit 3; touch "%s" ;; esac\n' "$T/was-up" "$T/was-up" > "$T/sysd/systemctl"
OUT="$("${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" bash "$ROOT/prreview" set PRREVIEW_GATE_SAMPLES 2 2>&1)"; RC=$?
has 'a set whose restart leaves the service stopped says it is not running' "$OUT" 'the service is not running'
is '...and fails' "$RC" 1
OUT="$(prreview restart 2>&1)"; RC=$?
has 'prreview restart before any install says to start it, not to read logs' "$OUT" "'prreview start' installs"
is '...and fails with 1, not the usage error 2' "$RC" 1
OUT="$(prreview stop 2>&1)"; RC=$?
has 'prreview stop before any install says there is nothing to stop' "$OUT" 'not installed; nothing to stop'
is '...and succeeds' "$RC" 0
# The file deleted by hand while the service still runs: stopped without it.
# A home with no unit file, since an earlier case installed one in $H.
mkdir -p "$T/lstop"; printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/lstop.log" > "$T/lstop/launchctl"
# systemctl reports "activating" between two automatic restarts: still running.
printf '#!/bin/sh\necho "$*" >> "%s"\ncase "$*" in *is-active*) echo activating ;; esac\n' "$T/lstop.log" > "$T/lstop/systemctl"; chmod +x "$T/lstop/launchctl" "$T/lstop/systemctl"
OUT="$("${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=macos PATH="$T/lstop:$FAKE:$PATH" bash "$ROOT/prreview" stop 2>&1)"; RC=$?
has 'prreview stop with the plist gone still unloads a service left running' "$(cat "$T/lstop.log")" bootout
has '...and says so' "$OUT" 'still running; stopped it'
is '...and succeeds' "$RC" 0
: > "$T/lstop.log"
OUT="$("${PRREVIEW_ENV[@]}" HOME="$T/nounit" XDG_CONFIG_HOME="$T/nounit/.config" PRREVIEW_PLATFORM=linux PATH="$T/lstop:$FAKE:$PATH" bash "$ROOT/prreview" stop 2>&1)"
has 'on Linux it stops the unit by name, which needs no unit file' "$(cat "$T/lstop.log")" "--user stop $PRREVIEW_SERVICE_NAME"
printf '#!/bin/sh\ncase "$*" in *is-active*) exit 3 ;; esac\necho "$*" >> "%s"\n' "$T/lstop.log" > "$T/lstop/systemctl"
: > "$T/lstop.log"
OUT="$("${PRREVIEW_ENV[@]}" HOME="$T/nounit" XDG_CONFIG_HOME="$T/nounit/.config" PRREVIEW_PLATFORM=linux PATH="$T/lstop:$FAKE:$PATH" bash "$ROOT/prreview" stop 2>&1)"
has 'nothing running and no file: nothing to stop' "$OUT" 'nothing to stop'
is '...and nothing is sent to the service manager' "$(cat "$T/lstop.log")" ''
# A bootout that reports an error after the service did go away is a stop.
printf '#!/bin/sh\ncase "$1" in print) [ -f "%s" ] && exit 113; exit 0 ;; bootout) touch "%s"; exit 5 ;; esac\n' "$T/gone" "$T/gone" > "$T/lstop/launchctl"
OUT="$("${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=macos PATH="$T/lstop:$FAKE:$PATH" bash "$ROOT/prreview" stop 2>&1)"; RC=$?
has 'a bootout that errors but leaves nothing running still counts as stopped' "$OUT" 'stopped it'
is '...and succeeds' "$RC" 0
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/lstop.log" > "$T/lstop/launchctl"; : > "$T/lstop.log"
OUT="$("${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=macos PATH="$T/lstop:$FAKE:$PATH" bash "$ROOT/prreview" uninstall 2>&1)"
has 'uninstall with the plist gone still stops a service left running' "$(cat "$T/lstop.log")" bootout
has '...and says so' "$OUT" 'still running; stopped it'
# the marker from the set above: is-active now reports it stopped
OUT="$("${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" bash "$ROOT/prreview" restart 2>&1)"; RC=$?
has 'prreview restart that leaves the service stopped says it is not running' "$OUT" 'the service is not running'
is '...and fails' "$RC" 1
printf '#!/bin/sh\ncase "$*" in *restart*) exit 1 ;; esac\n' > "$T/sysd/systemctl"
OUT="$("${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" bash "$ROOT/prreview" restart 2>&1)"; RC=$?
has 'prreview restart that fails on a running service says it keeps the old settings' "$OUT" 'keeps its old settings'
is '...and fails with 1, not the usage error 2' "$RC" 1
printf '#!/bin/sh\necho "$*" >> "%s"\ncase "$*" in *is-active*) exit 3 ;; esac\n' "$T/systemctl.log" > "$T/sysd/systemctl"
: > "$T/systemctl.log"
"${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" bash "$ROOT/prreview" stop >/dev/null 2>&1
has 'stop on Linux disables the unit, so the next login leaves it off' "$(cat "$T/systemctl.log")" "--user disable --now $PRREVIEW_SERVICE_NAME"
# systemd runs, but a su/sudo shell cannot reach it: that is unknown, not stopped.
mkdir -p "$T/unreach/run" "$T/unreach/bin"
printf '#!/bin/sh\ncase "$*" in *show-environment*) exit 1 ;; esac\n' > "$T/unreach/bin/systemctl"; chmod +x "$T/unreach/bin/systemctl"
UNREACH=(env -u XDG_RUNTIME_DIR PRREVIEW_SYSTEMD_RUN_DIR="$T/unreach/run" PRREVIEW_PLATFORM=linux PATH="$T/unreach/bin:$FAKE:$PATH")
OUT="$("${PRREVIEW_ENV[@]}" "${UNREACH[@]}" bash "$ROOT/prreview" stop 2>&1)"; RC=$?
is 'stop from a shell that cannot reach systemd fails' "$RC" 1
has '...says it cannot ask, instead of "nothing to stop"' "$OUT" 'cannot ask systemd'
has '...and how to reach it' "$OUT" 'XDG_RUNTIME_DIR is not set'
OUT="$("${PRREVIEW_ENV[@]}" "${UNREACH[@]}" bash "$ROOT/prreview" set PRREVIEW_GATE_SAMPLES 2 2>&1)"
has 'a setting saved from there says the service could not be asked' "$OUT" 'cannot ask systemd whether'
: > "$T/systemctl.log"
"${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" bash "$ROOT/prreview" start >/dev/null 2>&1
has 'start on Linux enables the unit again' "$(cat "$T/systemctl.log")" "--user enable --now $PRREVIEW_SERVICE_NAME"
printf '#!/bin/sh\necho "$*" >> "%s"\ncase "$*" in *enable*) exit 1 ;; esac\n' "$T/systemctl.log" > "$T/sysd/systemctl"; : > "$T/systemctl.log"
"${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" bash "$ROOT/prreview" restart >/dev/null 2>&1; RC=$?
is 'restart on Linux fails when the unit cannot be enabled again' "$RC" 1
is '...and does not restart it half-way' "$(grep -c -- '--user restart' "$T/systemctl.log")" 0
printf '#!/bin/sh\ncase "$*" in *start*|*enable*|*is-active*) exit 3 ;; esac\n' > "$T/sysd/systemctl"
has 'prreview start that fails says so' "$("${PRREVIEW_ENV[@]}" PRREVIEW_PLATFORM=linux PATH="$T/sysd:$FAKE:$PATH" bash "$ROOT/prreview" start 2>&1)" 'did not start'

if [ "$FAILED" -eq 0 ]; then echo "PASS: prreview"; else echo "FAIL: prreview"; exit 1; fi
