#!/bin/bash

set -euo pipefail

KEYCLOAK_URL=${KEYCLOAK_URL:-"http://keycloak:8080"}
ADMIN_USER="$1"
ADMIN_PASS="$2"
CLIENT_NAMES=(${KC_LOGIN_CLIENT_SUFFIX:-"-login-application"} ${KC_SERVICE_CLIENT_ID:-"sidecar-module-access-client"} ${KC_PASSWORD_RESET_CLIENT_ID:-"password-reset-client"} ${KC_IMPERSONATION_CLIENT:-"impersonation-client"})

get_token() {
  response=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d 'grant_type=password' \
    -d 'client_id=admin-cli')

  token=$(echo "$response" | jq -r .access_token)
  if [[ "$token" == "null" || -z "$token" ]]; then
    error_msg=$(echo "$response" | jq -r .error_description)
    echo "ERROR: Failed to retrieve admin token. Please check username/password." >&2
    [ -n "$error_msg" ] && echo "Details: $error_msg" >&2
    exit 1
  fi
  echo "$token"
}
add_protocol_mapper_to_client() {
  local realm=$1 client_id=$2 token=$3

  # Get client UUID
  local client_list=$(curl -s -H "Authorization: Bearer $token" \
    "${KEYCLOAK_URL}/admin/realms/${realm}/clients?clientId=${client_id}")
  local client_uuid=$(echo "$client_list" | jq -r '.[0].id')
  if [[ $client_uuid == "null" || -z $client_uuid ]]; then
    echo "Warning: Client '$client_id' not found in realm '$realm'. Skipping mapper add." >&2
    return 1
  fi

  # Check if 'sub' and 'user_id' mappers exist
  local mappers_url="${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/protocol-mappers/models"
  existing_mappers=$(curl -s -H "Authorization: Bearer $token" "$mappers_url" | jq -r '.[].name')

  # Add 'sub' mapper if not present
  if ! grep -xq "sub" <<< "$existing_mappers"; then
    cat > sub_mapper.json <<EOF
{
  "name": "sub",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-sub-mapper",
  "consentRequired": false,
  "config": {
       "lightweight.claim": "true",
       "introspection.token.claim": "true",
       "access.token.claim": "true"
  }
}
EOF
    resp=$(curl -s -w "%{http_code}" -X POST -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      --data @sub_mapper.json "$mappers_url")
    code="${resp: -3}"
    if [[ $code != "201" ]]; then
      echo "ERROR: Failed to create 'sub' protocol mapper for client $client_id in realm $realm (HTTP $code)" >&2
      rm -f sub_mapper.json
      return 1
    fi
    rm -f sub_mapper.json
    echo "Added 'sub' protocol mapper to $client_id (realm $realm)"
  fi

}

patch_client_lightweight() {
  local realm=$1 client_id=$2 token=$3
  local client_list=$(curl -s -H "Authorization: Bearer $token" \
    "${KEYCLOAK_URL}/admin/realms/${realm}/clients?clientId=${client_id}")
  local client_uuid=$(echo "$client_list" | jq -r '.[0].id')
  if [[ $client_uuid == "null" || -z $client_uuid ]]; then
    echo "Warning: Client '$client_id' not found in realm '$realm'. Skipping." >&2
    return 1
  fi
  local client_json=$(curl -s -w "%{http_code}" -o client.json -H "Authorization: Bearer $token" \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}")
        http_code=$(tail -c 4 <<< "$client_json")

        body=$(cat client.json)

        if [[ "$http_code" != "200" ]]; then
          echo "ERROR: Failed to fetch client $client_uuid in realm $realm (HTTP $http_code)" >&2
          rm -f client.json
          return 1
        fi

        if ! patched=$(echo "$body" | jq '
          .attributes."client.use.lightweight.access.token.enabled" = "true"
          | (.protocolMappers[] | select(.name=="user_id mapper").config."lightweight.claim") = "true"
        '); then
          echo "ERROR: Failed to patch client or user_id mapper for $client_uuid in $realm." >&2
          rm -f client.json
          return 1
        fi

        update_response=$(curl -s -w "%{http_code}" -o update.json -X PUT -H "Authorization: Bearer $token" \
          -H "Content-Type: application/json" --data "$patched" \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}")
        update_code=$(tail -c 4 <<< "$update_response")

        if [[ "$update_code" != "204" ]]; then
          echo "ERROR: Failed to update client $client_uuid in realm $realm (HTTP $update_code)" >&2
          cat update.json >&2
          rm -f client.json update.json
          return 1
        fi

        rm -f client.json update.json
        echo "$client_uuid"

}


patch_role_policies_fetchroles() {
  local realm=$1 client_uuid=$2 token=$3

  # Get all role policies' IDs with error handling
  local policy_resp
  policy_resp=$(curl -s -w "%{http_code}" -o policies.json -H "Authorization: Bearer $token" \
    "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy?type=role")
  local http_code="${policy_resp: -3}"
  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: Failed to fetch ids of role policies for client $client_uuid in realm $realm (HTTP $http_code)" >&2
    rm -f policies.json
    return 1
  fi

  local policies
  policies=$(jq -r '.[].id' policies.json)
  rm -f policies.json

  # If policies is empty, notify and return
  if [[ -z "$policies" ]]; then
    echo "Warning: No role policies found for client $client_uuid in realm $realm." >&2
    return 0
  fi

  echo "$policies" | while read -r pid; do
    # Retrieve policy JSON with error handling
    policy_resp=$(curl -s -w "%{http_code}" -o policy.json -H "Authorization: Bearer $token" \
      "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${pid}")
    http_code="${policy_resp: -3}"
    if [[ "$http_code" != "200" ]]; then
      echo "ERROR: Failed to fetch policy $pid for client $client_uuid in realm $realm (HTTP $http_code)" >&2
      rm -f policy.json
      continue
    fi

    # Patch the fetchRoles field, validate JSON
    if ! patched=$(jq '.config.fetchRoles="true"' policy.json); then
      echo "ERROR: Failed to patch fetchRoles in policy $pid for client $client_uuid (realm $realm)." >&2
      rm -f policy.json
      continue
    fi
    rm -f policy.json

    # PUT update and check response code
    update_resp=$(curl -s -w "%{http_code}" -X PUT -o update.json -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" --data "$patched" \
      "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${pid}")
    update_code="${update_resp: -3}"
    if [[ "$update_code" != "201" ]]; then
      echo "ERROR: Failed to update fetchRoles in policy $pid for client $client_uuid (realm $realm), HTTP $update_code" >&2
      cat update.json >&2
      rm -f update.json
      continue
    fi
    rm -f update.json
  done
}


TOKEN=$(get_token)

REALMS=$(curl -s -H "Authorization: Bearer $TOKEN" "${KEYCLOAK_URL}/admin/realms" | jq -r '.[].realm')

echo "$REALMS" | while read -r realm; do
  [[ "$realm" == "master" ]] && continue
  echo "Processing realm: $realm"
  for client in "${CLIENT_NAMES[@]}"; do
    if [[ "$client" == -* ]]; then
          client="${realm}${client}"
    fi
    echo "  Processing client: $client"
    # Add protocol mappers to the client before patching lightweight token
    add_protocol_mapper_to_client "$realm" "$client" "$TOKEN" || true

    # Patch client to enable lightweight tokens
    CLIENT_ID=$(patch_client_lightweight "$realm" "$client" "$TOKEN" || true)
    [[ -z $CLIENT_ID || $CLIENT_ID == "null" ]] && continue

    # Patch role policies to fetch roles
    client_json=$(curl -s -H "Authorization: Bearer $TOKEN" \
      "${KEYCLOAK_URL}/admin/realms/${realm}/clients?clientId=${client}")

    client_uuid=$(echo "$client_json" | jq -r '.[0].id')
    enabled=$(echo "$client_json" | jq -r '.[0].authorizationServicesEnabled')

    if [[ "$enabled" == "true" ]]; then
      patch_role_policies_fetchroles "$realm" "$client_uuid" "$TOKEN" || true
    else
      echo "Skipping role policy patch for $client (realm $realm): fine-grained authorization not enabled." >&2
    fi

  done
done

echo "All done."
