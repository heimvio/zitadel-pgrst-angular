#!/usr/bin/env bash
# e2e-only helper: relax Zitadel's default login policy so the headless tests
# don't get stuck on a 2FA setup/verify prompt.
#
# Two things have to happen:
#   1. Reset the policy fields (no forceMfa, no passwordless).
#   2. DELETE every second-factor + multi-factor entry — those are tracked
#      in their own arrays via dedicated endpoints, not the policy body.
#
# TEST-ONLY tooling. Production bootstrap remains MFA-friendly.
set -euo pipefail

API="http://localhost:8090"
ZH="Host: localhost"

PAT="$(docker run --rm -v zitadel-pgrst-auth_zbootstrap:/b:ro alpine:3.20 cat /b/admin-client.pat)"
AUTH="Authorization: Bearer $PAT"
JSON="Content-Type: application/json"

call() { # method path [body] -> echoes http-code
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -s -o /tmp/e2e-mfa-resp -w "%{http_code}" -X "$m" -H "$ZH" -H "$AUTH" -H "$JSON" "$API$p" -d "$b"
  else
    curl -s -o /tmp/e2e-mfa-resp -w "%{http_code}" -X "$m" -H "$ZH" -H "$AUTH" "$API$p"
  fi
}

echo "e2e/disable-mfa: updating instance default login policy ..."
c=$(call PUT /admin/v1/policies/login '{
  "allowUsernamePassword": true,
  "allowRegister": false,
  "allowExternalIdp": false,
  "forceMfa": false,
  "forceMfaLocalOnly": false,
  "passwordlessType": "PASSWORDLESS_TYPE_NOT_ALLOWED",
  "hidePasswordReset": false,
  "ignoreUnknownUsernames": false,
  "allowDomainDiscovery": false,
  "disableLoginWithEmail": false,
  "disableLoginWithPhone": true,
  "defaultRedirectUri": "",
  "passwordCheckLifetime": "864000s",
  "externalLoginCheckLifetime": "864000s",
  "mfaInitSkipLifetime": "2592000s",
  "secondFactorCheckLifetime": "64800s",
  "multiFactorCheckLifetime": "43200s"
}')
case "$c" in
  200) echo "  ✓ policy updated." ;;
  400) echo "  · policy already in target state (no change)." ;;
  *) echo "  ✗ policy update HTTP $c"; cat /tmp/e2e-mfa-resp; exit 1 ;;
esac

echo "e2e/disable-mfa: removing second factors from policy ..."
for t in SECOND_FACTOR_TYPE_OTP SECOND_FACTOR_TYPE_U2F SECOND_FACTOR_TYPE_OTP_EMAIL SECOND_FACTOR_TYPE_OTP_SMS; do
  c=$(call DELETE "/admin/v1/policies/login/second_factors/$t")
  echo "  · $t  → HTTP $c"
done

echo "e2e/disable-mfa: removing multi factors from policy ..."
for t in MULTI_FACTOR_TYPE_U2F_WITH_VERIFICATION; do
  c=$(call DELETE "/admin/v1/policies/login/multi_factors/$t")
  echo "  · $t  → HTTP $c"
done

echo "e2e/disable-mfa: done."
