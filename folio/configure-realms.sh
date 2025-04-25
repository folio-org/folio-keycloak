#!/bin/bash

script="configure-realms.sh"
keycloakUrl="${KC_URL:-http://localhost:8080}"
clientId="${KC_FOLIO_BE_ADMIN_CLIENT_ID:-folio-backend-admin-client}"
clientSecret="$KC_FOLIO_BE_ADMIN_CLIENT_SECRET"

maxAttempts=50
attemptCounter=0
/opt/keycloak/bin/kcadm.sh config truststore --trustpass "${KCADM_HTTPS_TRUST_STORE_PASSWORD:-SecretPassword}" "${KCADM_HTTPS_TRUST_STORE:-/opt/keycloak/conf/test.server.truststore}"

function loginAsAdmin() {
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server "$keycloakUrl" \
    --realm master \
    --user admin \
    --password "${KC_BOOTSTRAP_ADMIN_PASSWORD-$KEYCLOAK_ADMIN_PASSWORD}" \
    &> /dev/null
}

while [ $attemptCounter -le $maxAttempts ]; do
  echo "$(date +%F' '%T,%3N) INFO  [$script] Trying to add client: '$clientId' to master realm [attempt: $attemptCounter]"
  if loginAsAdmin; then
    /opt/keycloak/bin/folio/setup-admin-client.sh "$clientId" "$clientSecret"
    break
  fi
  echo "$(date +%F' '%T,%3N) INFO  [$script] Keycloak is not ready yet, waiting for 10 seconds [attempt: $attemptCounter]"
  attemptCounter=$((attemptCounter + 1))
  sleep 10
done

if [ $attemptCounter -ge $maxAttempts ]; then
  echo "$(date +%F' '%T,%3N) WARN  [$script] Failed to add client: $clientId to master realm, the amount of attempt is greater than $maxAttempts"
  exit 1
fi
