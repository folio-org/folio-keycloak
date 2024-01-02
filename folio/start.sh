#!/bin/bash
# Wrapper script as docker entrypoint to run configure-realms.sh in parallel to actual kc.sh (the official entrypoint).

if [[ -z "$KC_FOLIO_BE_ADMIN_CLIENT_SECRET" ]]; then
  echo "$(date +%F' '%T,%3N) ERROR [start.sh] Environment variable KC_FOLIO_BE_ADMIN_CLIENT_SECRET is not set, check 
  the configuration"
  exit 1
fi

# Generate BCFKS keystore
/opt/keycloak/bin/folio/keystore.sh &

/opt/keycloak/bin/folio/configure-realms.sh &

/opt/keycloak/bin/kc.sh "$@"
