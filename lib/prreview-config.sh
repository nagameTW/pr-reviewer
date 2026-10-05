# shellcheck shell=bash
# The settings file `prreview` reads and writes. One `KEY=value` per line; the
# value is everything after the first `=`, taken literally (spaces included,
# no quoting, nothing expanded). Blank lines and lines starting with # are
# comments. The file is parsed, never sourced: a setting cannot run code.

# Keys the reviewer reads: its own PRREVIEW_ knobs, plus the three that locate the
# tools a background service would otherwise not find.
PRREVIEW_CONFIG_KEY_RE='^(PRREVIEW_[A-Z0-9_]+|PATH|GH_BIN|CLAUDE_BIN)$'

# Fixed under $HOME on purpose, XDG_CONFIG_HOME or not: the background
# service starts without the terminal's environment, and pr-autoreview.sh
# looks for the sensitive-data patterns here too. A location that followed a
# variable only the terminal has would split the two.
prreview_config_dir() { printf '%s' "$HOME/.config/pr-reviewer"; }
prreview_config_file() { printf '%s' "$(prreview_config_dir)/config"; }
prreview_state_dir() { printf '%s' "$HOME/.cache/pr-reviewer"; }

# Friendly names for the settings people change most. Anything else is
# given by its PRREVIEW_ name.
prreview_key_of() {
  case "${1-}" in
    repos) echo PRREVIEW_GATE_REPOS ;;
    parallel) echo PRREVIEW_GATE_PARALLEL ;;
    model) echo PRREVIEW_REVIEW_MODEL ;;
    checks) echo PRREVIEW_GATE_CHECKS_DIR ;;
    patterns) echo PRREVIEW_SENSITIVE_PATTERNS_FILE ;;
    *) if [[ "${1-}" =~ $PRREVIEW_CONFIG_KEY_RE ]]; then echo "$1"; else return 1; fi ;;
  esac
}

# Prints the file's settings as KEY<TAB>value lines. Fails, naming the line,
# on anything that is not a comment, a blank or a KEY=value with a known key
# shape: a typo must not silently drop a setting. A key given twice fails
# too: which of the two applies would otherwise depend on who reads it.
prreview_config_read() {
  local file="${1-}" line n=0 key seen=" "
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    if [ "$key" = "$line" ] || ! [[ "$key" =~ $PRREVIEW_CONFIG_KEY_RE ]]; then
      echo "$file:$n: expected KEY=value with a PRREVIEW_ key, got: $line" >&2
      return 1
    fi
    case "$seen" in *" $key "*) echo "$file:$n: $key is set a second time; keep one line" >&2; return 1 ;; esac
    seen="$seen$key "
    printf '%s\t%s\n' "$key" "${line#*=}"
  done < "$file"
}

# Exports every setting into the current shell. A setting already in the
# environment wins, so `PRREVIEW_GATE_PARALLEL=1 prreview once` works as expected;
# PATH is the exception, because every shell has one and a background
# service's is too short to find gh and claude. "In the environment" means
# exported to this process (printenv), not any shell variable of that name.
# A setting the file holds also becomes the environment of every command it
# runs, so a shell variable of the same name must not block it.
prreview_config_export() {
  local file="${1-}" settings key value
  settings="$(prreview_config_read "$file")" || return 1
  [ -n "$settings" ] || return 0
  while IFS=$'\t' read -r key value; do
    [ "$key" != PATH ] && printenv "$key" >/dev/null && continue
    export "$key=$value"
  done <<<"$settings"
}

prreview_config_get() {
  local settings
  settings="$(prreview_config_read "${1-}")" || return 1
  awk -F'\t' -v k="${2-}" '$1 == k { v = substr($0, length(k) + 2) } END { if (v != "") print v }' <<<"$settings"
}

# Writes KEY=value, replacing the key's line or adding one. $3 empty removes
# the key. Written to a temporary file and renamed, so a failure halfway
# never leaves a truncated settings file.
prreview_config_set() {
  local file="${1-}" key="${2-}" value="${3-}" tmp
  [[ "$key" =~ $PRREVIEW_CONFIG_KEY_RE ]] || { echo "not a setting name: $key" >&2; return 1; }
  case "$value" in *$'\n'*) echo "$key: a value must be one line" >&2; return 1 ;; esac
  prreview_config_read "$file" >/dev/null || return 1
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  # Each step checked on its own: a failed copy of the other lines must not
  # leave a file holding only the new one.
  if [ -f "$file" ]; then
    awk -v k="$key" 'index($0, k "=") != 1' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    printf '# pr-reviewer settings. `prreview set` and `prreview setup` edit this file.\n' > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  if [ -n "$value" ]; then printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }; fi
  chmod 600 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# The default the reviewer at $1 gives the key: the text after :- in the
# first ${KEY:-...} it has, up to the first }. Nothing when it has none.
prreview_key_default() {
  local root="${1-}" key="${2-}" f d
  [[ "$key" =~ $PRREVIEW_CONFIG_KEY_RE ]] || return 0
  for f in "$root"/pr-autoreview.sh "$root"/review-loop.sh "$root"/owner-alert.sh "$root"/lib/*.sh; do
    case "${f##*/}" in prreview-*) continue ;; esac
    d="$(grep -ohE -- "\\\$\\{$key:-[^}]*" "$f" 2>/dev/null | head -1)"
    if [ -n "$d" ]; then printf '%s' "${d#*:-}"; return 0; fi
  done
}

# 0 when some script of the reviewer at $1 reads the key as a variable
# ($KEY or ${KEY...}, the whole name): catches a setting name with a typo
# before it quietly does nothing. prreview's own files are left out, since the
# names they use for themselves are not settings.
prreview_key_known() {
  local root="${1-}" key="${2-}" f
  case "$key" in PATH|GH_BIN|CLAUDE_BIN) return 0 ;; esac
  [[ "$key" =~ $PRREVIEW_CONFIG_KEY_RE ]] || return 1
  for f in "$root"/pr-autoreview.sh "$root"/review-loop.sh "$root"/owner-alert.sh "$root"/lib/*.sh; do
    case "${f##*/}" in prreview-*) continue ;; esac
    grep -qE -- "\\\$\\{?$key([^A-Za-z0-9_]|\$)" "$f" 2>/dev/null && return 0
  done
  return 1
}
