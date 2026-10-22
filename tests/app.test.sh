#!/usr/bin/env bash
# lib/app.sh: the JWT the App signs, and which installation token it asks
# for. curl is a stub that answers from canned JSON; the key is a throwaway
# made here. Run: bash tests/app.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. lib/app.sh || { echo "lib/app.sh missing"; exit 1; }
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
openssl genrsa -out "$T/key.pem" 2048 2>/dev/null
openssl rsa -in "$T/key.pem" -pubout -out "$T/pub.pem" 2>/dev/null
b64d() { local s="$1"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done; printf '%s' "$s" | tr '_-' '/+' | openssl base64 -d -A; }

# ── the JWT ───────────────────────────────────────────────────────────────
JWT="$(app_jwt 12345 "$T/key.pem")"
IFS=. read -r H P S <<<"$JWT"
is 'the JWT has three parts' "$(tr -cd . <<<"$JWT" | wc -c | tr -d ' ')" 2
is 'the header says RS256' "$(b64d "$H" | jq -r .alg)" RS256
is 'the issuer is the App id' "$(b64d "$P" | jq -r .iss)" 12345
is 'it is valid for ten minutes, starting a minute back' "$(b64d "$P" | jq -r '.exp - .iat')" 600
printf '%s.%s' "$H" "$P" > "$T/signed"
b64d "$S" > "$T/sig"
is 'the signature verifies with the public key' \
   "$(openssl dgst -sha256 -verify "$T/pub.pem" -signature "$T/sig" "$T/signed" 2>&1)" 'Verified OK'
is 'no key, no JWT' "$(app_jwt 12345 "$T/missing.pem" || echo refused)" refused

# ── the installation token ────────────────────────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
cat >> "$HDR_LOG"
case "$*" in
  *--max-time*) ;;
  *) echo "no --max-time" >&2; exit 99 ;;
esac
case "$*" in
  *"/repos/acme/web/installation"*) echo '{"id":77}' ;;
  *"/repos/me/api/installation"*) echo '{"id":55}' ;;
  *"/app/installations/77/access_tokens"*) echo '{"token":"tok-for-acme"}' ;;
  *"/app/installations/55/access_tokens"*) echo '{"token":"tok-for-me"}' ;;
  *"/app") echo '{"slug":"my-reviewer"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$T/bin/curl"
export CURL_LOG="$T/curl.log" HDR_LOG="$T/hdr.log"
with_stub() { PATH="$T/bin:$PATH" "$@"; }
is 'an organization repo gets its installation token' "$(with_stub app_token_for 12345 "$T/key.pem" acme/web)" tok-for-acme
is 'a personal repo gets its own' "$(with_stub app_token_for 12345 "$T/key.pem" me/api)" tok-for-me
# 404 from /repos/<repo>/installation: not installed, or installed with
# "Only select repositories" and not given this one.
is 'a repo the App cannot reach gets nothing, and says so by status' \
   "$(with_stub app_token_for 12345 "$T/key.pem" me/secret || echo refused)" refused
# The token is for the one repository that gets the comment, not for every
# repository the installation reaches.
is 'the token request names only the repository it is for' \
   "$(grep 'access_tokens' "$CURL_LOG" | grep -c -- '-d {"repositories":\["web"\]}')" 1
is '...for a personal repository too' \
   "$(grep 'installations/55/access_tokens' "$CURL_LOG" | grep -c -- '-d {"repositories":\["api"\]}')" 1
is '...as a POST' "$(grep 'access_tokens' "$CURL_LOG" | grep -vc -- '-X POST')" 0
is 'every call carries a time limit' "$(grep -vc -- '--max-time' "$CURL_LOG")" 0
is 'no credential is on a command line' "$(grep -c 'Bearer' "$CURL_LOG")" 0
is '...it goes in on stdin, once per call' "$(grep -c '^Authorization: Bearer ' "$HDR_LOG")" "$(wc -l < "$CURL_LOG" | tr -d ' ')"
is 'the slug comes from the App itself' "$(with_stub app_slug 12345 "$T/key.pem")" my-reviewer
is 'the API address cannot be moved by the environment' "$(APP_API=https://evil.example bash -c '. lib/app.sh; echo "$APP_API"')" https://api.github.com

if [ "$FAILED" -eq 0 ]; then echo "PASS: app"; else echo "FAIL: app"; exit 1; fi
