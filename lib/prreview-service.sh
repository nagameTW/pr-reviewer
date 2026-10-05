# shellcheck shell=bash
# Running the review loop in the background, started at login: launchd on
# macOS, a systemd user service on Linux and on Windows under WSL2.

PRREVIEW_SERVICE_NAME=pr-reviewer
PRREVIEW_LAUNCHD_LABEL="local.$PRREVIEW_SERVICE_NAME"

# macos, wsl, linux, or unsupported. $1 and $2 stand in for `uname -s` and
# /proc/version in tests.
prreview_platform() {
  local kernel="${1-$(uname -s)}" version="${2-}"
  case "$kernel" in
    Darwin) echo macos ;;
    Linux)
      [ -n "$version" ] || version="$(cat /proc/version 2>/dev/null)"
      case "$version" in *[Mm]icrosoft*|*WSL*) echo wsl ;; *) echo linux ;; esac ;;
    *) echo unsupported ;;
  esac
}

# 0 when macOS will not let a background job read $1. Privacy protection
# covers Documents, Desktop, Downloads and iCloud Drive; a background service
# started from there fails every round with "Operation not permitted",
# while the same command works fine in a terminal.
# Both sides are compared as physical paths, so a symlink cannot hide one.
prreview_macos_protected_dir() {
  local dir home
  dir="$(cd "${1-}" 2>/dev/null && pwd -P)" || dir="${1-}"
  home="$(cd "$HOME" 2>/dev/null && pwd -P)" || home="$HOME"
  case "$dir/" in
    "$home"/Documents/*|"$home"/Desktop/*|"$home"/Downloads/*|"$home"/Library/Mobile\ Documents/*) return 0 ;;
  esac
  return 1
}

# XML-escapes $1 for the plist.
prreview_xml() {
  local s="${1-}"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '%s' "$s"
}

# $1 = install directory, $2 = log file.
prreview_launchd_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PRREVIEW_LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(prreview_xml "$1/prreview")</string>
    <string>run</string>
    <string>--service</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$(prreview_xml "$2")</string>
  <key>StandardErrorPath</key><string>$(prreview_xml "$2")</string>
</dict>
</plist>
EOF
}

# systemd quotes: a path with a space, a quote, a % or a $ survives ExecStart
# ($$ and %% are systemd's literal $ and %). The
# log paths after append: take no quotes, only the %% for a literal %.
prreview_systemd_quote() {
  local s="${1-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//%/%%}"; s="${s//\$/\$\$}"
  printf '"%s"' "$s"
}

# $1 = install directory, $2 = log file. No After=network-online.target:
# a user manager has no such unit, and a round that finds no network just
# fails and runs again a minute later.
prreview_systemd_unit() {
  cat <<EOF
[Unit]
Description=pr-reviewer: review new pull requests

[Service]
ExecStart=/bin/bash $(prreview_systemd_quote "$1/prreview") run --service
Restart=always
RestartSec=30
StandardOutput=append:${2//%/%%}
StandardError=append:${2//%/%%}

[Install]
WantedBy=default.target
EOF
}

prreview_launchd_plist_path() { printf '%s' "$HOME/Library/LaunchAgents/$PRREVIEW_LAUNCHD_LABEL.plist"; }
prreview_systemd_unit_path() { printf '%s' "$HOME/.config/systemd/user/$PRREVIEW_SERVICE_NAME.service"; }

# Where systemd marks that it runs the machine; tests point it elsewhere.
PRREVIEW_SYSTEMD_RUN_DIR="${PRREVIEW_SYSTEMD_RUN_DIR:-/run/systemd/system}"

# 0 when this machine can run a systemd user service. Under WSL that needs
# systemd=true in /etc/wsl.conf.
prreview_systemd_user_ok() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# 0 when systemd runs here but this shell cannot reach the user's service
# manager (su, sudo): whether the service runs is then unknown.
prreview_systemd_unreachable() { [ -d "$PRREVIEW_SYSTEMD_RUN_DIR" ] && ! prreview_systemd_user_ok; }

# 0 when kernel string $1 (/proc/version) is WSL 1's, which ends in
# -Microsoft; WSL 2's says microsoft-standard.
prreview_is_wsl1() { case "${1-}" in *-Microsoft*) return 0 ;; esac; return 1; }

# Why prreview_systemd_user_ok failed and what to do, on stderr. $1 = platform.
prreview_systemd_user_hint() {
  local me; me="$(id -un)"
  if [ ! -d "$PRREVIEW_SYSTEMD_RUN_DIR" ]; then
    if [ "$1" != wsl ]; then
      echo "systemctl --user is not available here. Run 'prreview run' under whatever keeps jobs running on this machine." >&2
    elif prreview_is_wsl1 "$(cat /proc/version 2>/dev/null)"; then
      echo "This is WSL 1, which cannot run systemd. In Windows, run 'wsl --set-version <distribution> 2', then rerun prreview setup." >&2
    else
      echo "systemd is not running in this WSL distribution. Add these lines to /etc/wsl.conf:" >&2
      printf '  [boot]\n  systemd=true\n' >&2
      echo "then run 'wsl --shutdown' in Windows, open the distribution again, and rerun prreview setup." >&2
    fi
  elif [ -z "${XDG_RUNTIME_DIR-}" ]; then
    echo "systemctl --user cannot reach $me's session from this shell: XDG_RUNTIME_DIR is not set, as after su or sudo. Run 'sudo loginctl enable-linger $me', then log in as $me directly (ssh, or 'machinectl shell $me@'), or run 'export XDG_RUNTIME_DIR=/run/user/$(id -u)', and try again." >&2
  else
    echo "systemctl --user cannot reach $me's service manager. Run 'sudo loginctl enable-linger $me', log in again, and try again." >&2
  fi
}

# $1 = platform, $2 = install directory, $3 = log file.
prreview_service_install() {
  local platform="$1" dir="$2" log="$3" path
  mkdir -p "$(dirname "$log")" || return 1
  case "$platform" in
    macos)
      if prreview_macos_protected_dir "$dir"; then
        echo "macOS does not let a background service read $dir (Documents, Desktop, Downloads and iCloud are protected)." >&2
        echo "Move the clone somewhere else, for example ~/pr-reviewer, and run prreview setup again." >&2
        return 1
      fi
      path="$(prreview_launchd_plist_path)"
      mkdir -p "$(dirname "$path")" || return 1
      prreview_launchd_plist "$dir" "$log" > "$path" || return 1
      launchctl bootout "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" >/dev/null 2>&1 || true
      # A service 'prreview stop' disabled stays disabled through an uninstall.
      launchctl enable "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL"
      launchctl bootstrap "gui/$(id -u)" "$path"
      ;;
    linux|wsl)
      prreview_systemd_user_ok || { prreview_systemd_user_hint "$platform"; return 1; }
      path="$(prreview_systemd_unit_path)"
      mkdir -p "$(dirname "$path")" || return 1
      prreview_systemd_unit "$dir" "$log" > "$path" || return 1
      systemctl --user daemon-reload && systemctl --user enable --now "$PRREVIEW_SERVICE_NAME"
      ;;
    *) echo "no background service for this system; run 'prreview run' yourself" >&2; return 1 ;;
  esac
}

prreview_service_remove() {
  case "$1" in
    macos)
      launchctl bootout "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" >/dev/null 2>&1 || true
      rm -f "$(prreview_launchd_plist_path)" ;;
    linux|wsl)
      # Unreachable, a disable would fail unseen and the unit, once deleted,
      # would keep running under a lingering session.
      prreview_systemd_user_ok || { prreview_systemd_user_hint "$1"; return 1; }
      systemctl --user disable --now "$PRREVIEW_SERVICE_NAME" >/dev/null 2>&1 || true
      rm -f "$(prreview_systemd_unit_path)"
      systemctl --user daemon-reload >/dev/null 2>&1 || true ;;
    *) echo "no background service on this system" >&2; return 1 ;;
  esac
}

# 0 when the service manager still runs the service, whether or not its file
# is still there: someone may have deleted the file by hand.
prreview_service_loaded() {
  case "$1" in
    macos) launchctl print "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" >/dev/null 2>&1 ;;
    # activating covers the wait between two automatic restarts.
    linux|wsl) case "$(systemctl --user is-active "$PRREVIEW_SERVICE_NAME" 2>/dev/null)" in
                 active|activating|reloading|deactivating) return 0 ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# Stops a running service without reading its file, for when the file is gone.
prreview_service_halt() {
  case "$1" in
    macos) launchctl bootout "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" ;;
    linux|wsl) systemctl --user stop "$PRREVIEW_SERVICE_NAME" ;;
    *) return 1 ;;
  esac
}

# Prints running, stopped, not installed, or unknown when systemd cannot be asked.
prreview_service_state() {
  case "$1" in
    macos)
      [ -f "$(prreview_launchd_plist_path)" ] || { echo "not installed"; return; }
      local info
      info="$(launchctl print "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" 2>/dev/null)"
      if grep -q 'state = running' <<<"$info"; then
        echo running
      else
        echo stopped
      fi ;;
    linux|wsl)
      [ -f "$(prreview_systemd_unit_path)" ] || { echo "not installed"; return; }
      prreview_systemd_user_ok || { echo "unknown (systemctl --user is not reachable from this shell)"; return; }
      if systemctl --user is-active --quiet "$PRREVIEW_SERVICE_NAME" 2>/dev/null; then echo running; else echo stopped; fi ;;
    *) echo "not installed" ;;
  esac
}

# Start and stop also turn the service on and off for later logins: a
# plain stop lasted only until the next login, when launchd or systemd
# started it again.
prreview_service_start() {
  case "$1" in
    macos) launchctl enable "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" || return 1
           launchctl bootstrap "gui/$(id -u)" "$(prreview_launchd_plist_path)" 2>/dev/null \
             || launchctl kickstart "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" ;;
    linux|wsl) systemctl --user enable --now "$PRREVIEW_SERVICE_NAME" ;;
    *) return 1 ;;
  esac
}

prreview_service_stop() {
  case "$1" in
    macos)
      local err
      launchctl disable "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" || return 1
      err="$(launchctl bootout "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" 2>&1)" && return 0
      # Not loaded at all is already stopped; still loaded is a real failure.
      launchctl print "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" >/dev/null 2>&1 || return 0
      printf '%s\n' "$err" >&2
      return 1 ;;
    linux|wsl) systemctl --user disable --now "$PRREVIEW_SERVICE_NAME" ;;
    *) return 1 ;;
  esac
}

prreview_service_restart() {
  case "$1" in
    # enable first, as on linux. A stopped service is out of the domain
    # (bootout); kickstart cannot find it, so start it the way prreview start does.
    macos) launchctl enable "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" || return 1
           launchctl kickstart -k "gui/$(id -u)/$PRREVIEW_LAUNCHD_LABEL" 2>/dev/null || prreview_service_start macos ;;
    # enable first, so a service 'prreview stop' turned off comes back at login too.
    linux|wsl) systemctl --user enable "$PRREVIEW_SERVICE_NAME" && systemctl --user restart "$PRREVIEW_SERVICE_NAME" ;;
    *) return 1 ;;
  esac
}
