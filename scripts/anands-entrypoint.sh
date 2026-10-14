#!/bin/sh
# Anands Storage entrypoint.
# Behaves exactly like upstream's /entrypoint.sh, except when the first argument is `admin` AND
# ANANDS_SSO_ISSUER_URL / _CLIENT_ID / _CLIENT_SECRET / _REDIRECT_URL / _COOKIE_SECRET are all set:
#   - oauth2-proxy listens on the admin's public port and does the OIDC (Authentik) login
#   - the real admin moves to 127.0.0.1:<port+20000> (unreachable from other containers)
#   - the admin's own username/password login is switched off (SSO replaces it)
# With the SSO variables unset nothing changes, so the existing admin login keeps working.

if [ "$1" = "admin" ] \
   && [ -n "$ANANDS_SSO_ISSUER_URL" ] && [ -n "$ANANDS_SSO_CLIENT_ID" ] \
   && [ -n "$ANANDS_SSO_CLIENT_SECRET" ] && [ -n "$ANANDS_SSO_REDIRECT_URL" ] \
   && [ -n "$ANANDS_SSO_COOKIE_SECRET" ]; then

  PORT=23646
  prev=""
  for a in "$@"; do
    case "$a" in
      -port=*|--port=*) PORT="${a#*=}" ;;
    esac
    case "$prev" in
      -port|--port) PORT="$a" ;;
    esac
    prev="$a"
  done
  INTERNAL=$((PORT + 20000))

  # Rebuild args: drop the admin's own credentials, move it to the internal port
  n=$#; skip=0; sawport=0
  while [ "$n" -gt 0 ]; do
    a="$1"; shift; n=$((n - 1))
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$a" in
      -adminPassword=*|--adminPassword=*|-readOnlyPassword=*|--readOnlyPassword=*|-readOnlyUser=*|--readOnlyUser=*|-adminUser=*|--adminUser=*) ;;
      -adminPassword|--adminPassword|-readOnlyPassword|--readOnlyPassword|-readOnlyUser|--readOnlyUser|-adminUser|--adminUser) skip=1 ;;
      -port=*|--port=*) set -- "$@" "-port=$INTERNAL"; sawport=1 ;;
      -port|--port) set -- "$@" "-port=$INTERNAL"; sawport=1; skip=1 ;;
      *) set -- "$@" "$a" ;;
    esac
  done
  [ "$sawport" = "1" ] || set -- "$@" "-port=$INTERNAL"

  export ANANDS_ADMIN_BIND=127.0.0.1
  export OAUTH2_PROXY_CLIENT_ID="$ANANDS_SSO_CLIENT_ID"
  export OAUTH2_PROXY_CLIENT_SECRET="$ANANDS_SSO_CLIENT_SECRET"
  export OAUTH2_PROXY_COOKIE_SECRET="$ANANDS_SSO_COOKIE_SECRET"

  ACCESS="--email-domain=*"
  if [ -n "$ANANDS_SSO_ALLOWED_EMAILS" ]; then
    echo "$ANANDS_SSO_ALLOWED_EMAILS" | tr ',; ' '\n\n\n' | sed '/^$/d' > /tmp/sso-emails.txt
    ACCESS="--authenticated-emails-file=/tmp/sso-emails.txt"
  fi

  # Logout: clear the proxy session, then end the Authentik session too (override with ANANDS_SSO_END_SESSION_URL;
  # set it to "none" to only clear the local session).
  ISSUER_HOST=$(echo "$ANANDS_SSO_ISSUER_URL" | sed -E 's#^https?://([^/]+).*#\1#')
  END_SESSION="${ANANDS_SSO_END_SESSION_URL:-${ANANDS_SSO_ISSUER_URL%/}/end-session/}"
  if [ "$END_SESSION" = "none" ]; then
    export ANANDS_SSO_LOGOUT_URL="/oauth2/sign_out?rd=%2Foauth2%2Fstart"
  else
    ENC=$(echo "$END_SESSION" | sed 's#%#%25#g; s#:#%3A#g; s#/#%2F#g; s#?#%3F#g; s#=#%3D#g; s#&#%26#g')
    export ANANDS_SSO_LOGOUT_URL="/oauth2/sign_out?rd=$ENC"
  fi

  echo "[anands] SSO enabled: gate on :$PORT -> admin on 127.0.0.1:$INTERNAL"
  (
    while true; do
      su-exec seaweed /usr/bin/oauth2-proxy \
        --provider=oidc \
        --oidc-issuer-url="$ANANDS_SSO_ISSUER_URL" \
        --redirect-url="$ANANDS_SSO_REDIRECT_URL" \
        --http-address="0.0.0.0:$PORT" \
        --upstream="http://127.0.0.1:$INTERNAL" \
        --scope="openid profile email" \
        --code-challenge-method=S256 \
        --skip-provider-button=true \
        --reverse-proxy=true \
        --whitelist-domain="$ISSUER_HOST" \
        --cookie-secure=true \
        --cookie-name=_anands_storage \
        --insecure-oidc-allow-unverified-email=true \
        $ACCESS
      echo "[anands] oauth2-proxy exited, restarting in 2s" >&2
      sleep 2
    done
  ) &
fi

exec /entrypoint.sh "$@"
