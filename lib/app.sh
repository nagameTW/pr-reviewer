# shellcheck shell=bash
# GitHub App identity: the tokens the reviewer posts with when a repo's comments
# go out as the App instead of the gh login. Everything here talks to
# api.github.com with curl, every call with a time limit: a hung request
# must not hold a round (the loop's own round timeout is 3,900 seconds by
# default). The address is
# fixed, not read from the environment: every request carries a credential.
# The Authorization header goes in on stdin (-H @-), so the JWT and the token
# never show in the process list.

APP_API=https://api.github.com
APP_CURL_MAX_TIME=30

app_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# app_jwt <app id> <private key file> — a JWT signed with the App's key,
# valid from a minute ago (clock skew) for nine minutes, the most GitHub
# allows being ten.
app_jwt() {
  local id="${1-}" key="${2-}" now hdr pay sig
  [ -n "$id" ] && [ -r "$key" ] || return 1
  now="$(date +%s)"
  hdr="$(printf '{"alg":"RS256","typ":"JWT"}' | app_b64url)"
  pay="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$id" | app_b64url)"
  sig="$(printf '%s.%s' "$hdr" "$pay" | openssl dgst -sha256 -sign "$key" -binary | app_b64url)" || return 1
  [ -n "$sig" ] || return 1
  printf '%s.%s.%s' "$hdr" "$pay" "$sig"
}

app_curl() { # <jwt> <curl arguments...>
  local jwt="$1"; shift
  printf 'Authorization: Bearer %s\n' "$jwt" \
    | curl -sf --max-time "$APP_CURL_MAX_TIME" -H @- -H "Accept: application/vnd.github+json" "$@"
}

app_get() { app_curl "$1" "$APP_API$2"; } # <jwt> <path>

# app_installation <jwt> <owner/repo> — the id of the App's installation
# that can reach this repository. Nothing when the App is not installed on
# the owner, or was installed with "Only select repositories" and this one
# is not among them.
app_installation() {
  local inst
  inst="$(app_get "$1" "/repos/$2/installation" | jq -r '.id // empty' 2>/dev/null)"
  case "$inst" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$inst"
}

# app_token_for <app id> <key> <owner/repo> — an installation token that can
# post on that repository. Non-zero when the App cannot reach it or GitHub
# did not answer. The token is for that one repository. Without the body, it
# would reach every repository of the installation.
app_token_for() {
  local jwt inst body repo="${3-}"
  jwt="$(app_jwt "${1-}" "${2-}")" || return 1
  inst="$(app_installation "$jwt" "${3-}")" || return 1
  body="$(jq -nc --arg r "${repo#*/}" '{repositories: [$r]}')" || return 1
  app_curl "$jwt" -X POST -H "Content-Type: application/json" -d "$body" \
    "$APP_API/app/installations/$inst/access_tokens" | jq -er '.token // empty'
}

# app_slug <app id> <key> — the App's slug. Its comments are authored by
# "<slug>[bot]".
app_slug() {
  local jwt
  jwt="$(app_jwt "${1-}" "${2-}")" || return 1
  app_get "$jwt" /app | jq -er '.slug // empty'
}
