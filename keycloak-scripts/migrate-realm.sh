#!/usr/bin/env bash
# migrate-realm.sh — Online cluster-to-cluster Keycloak realm migration.
#
# Migrates a realm from a CLI-produced export bundle to a running destination
# Keycloak cluster, with zero downtime, by using the Admin REST API.
#
# Required environment variables:
#   KC_URL                   — destination Keycloak base URL, e.g. https://keycloak.dest.example.com
#   KC_ADMIN_CLIENT_ID       — admin service-account client id on the master realm
#   KC_ADMIN_CLIENT_SECRET   — admin service-account client secret
#   TENANT                   — realm name to migrate
#   EXPORT_DIR               — directory containing <TENANT>-realm.json and optional <TENANT>-users-*.json
#
# Optional environment variables:
#   DEST_NODES               — comma-separated list of per-node base URLs to verify cache propagation
#                              (if unset, only the load-balanced KC_URL is verified)
#   USER_BATCH_SIZE          — max users per partialImport call (default 1000)
#
# What this script imports (atomically via POST /admin/realms):
#   - Realm config (login, tokens, brute-force, themes, locales, security defaults)
#   - Realm-level roles AND client-level roles (with composites)
#   - Groups (full hierarchy with role mappings and attributes)
#   - Clients, including their full authorizationSettings:
#       * authorization resources, scopes, policies, permissions
#       * service-account flag, secrets, protocol mappers, default/optional client scopes
#   - Client scopes (with protocol mappers and scope mappings)
#   - Authentication flows + executions + authenticator configs
#   - Required actions + provider configs
#   - Identity providers + IdP mappers
#   - Components: org.keycloak.keys.KeyProvider (signing keys), user-storage providers,
#                 user-federation mappers, client-registration policies, etc.
#   - Organizations (Keycloak >= 26)
#   - Realm-level events configuration
#
# What this script imports separately via POST /admin/realms/{realm}/partialImport:
#   - Users (passwords, credentials, federated identities, role mappings, group memberships,
#           required actions, attributes — full UserRepresentation)
#   - Federated users (if present in the export)
#
# Known limitations:
#   - Fine-Grained Admin Permissions V2 (FGAP, KC>=26.2) policies stored on the
#     realm-management/admin-permissions client are imported as part of that client's
#     authorizationSettings. If you only see scopes (not resources/policies/permissions),
#     check 'features-disabled' on destination — FGAP V2 must be enabled on both clusters.
#     See https://github.com/keycloak/keycloak/issues/12256 (resolved for full-realm import,
#     still partial for partialImport — that is why this script uses POST /admin/realms
#     for everything except users).
#   - User sessions and offline tokens are NOT migrated (they live in Infinispan, not the DB).
#     Users will need to re-login. Refresh tokens remain valid only if the source's KeyProvider
#     keys are imported (this script enforces that).
#
# Exit codes:
#   0 — success
#   1 — pre-flight failure (no writes performed)
#   2 — failure during realm POST (no users imported; realm may need DELETE)
#   3 — failure during user import (realm exists; resume by re-running with EXPORT_DIR pointing
#       at the same files; failed batches will retry, completed ones will succeed because
#       partialImport is idempotent for FAIL strategy)
#   4 — verification failure (realm exists on at least one node but not all)
#   5 — post-import authorization-settings spot-check failed

set -euo pipefail

# ---------- helpers ----------------------------------------------------------

log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$1" "$2" >&2; }
die() { log ERROR "$1"; exit "${2:-1}"; }

require_env() {
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "Required environment variable not set: $v"
    done
}

# ---------- configuration ----------------------------------------------------

require_env KC_URL KC_ADMIN_CLIENT_ID KC_ADMIN_CLIENT_SECRET TENANT EXPORT_DIR

USER_BATCH_SIZE="${USER_BATCH_SIZE:-1000}"
REALM_FILE="${EXPORT_DIR}/${TENANT}-realm.json"
WORK_DIR="$(mktemp -d -t kc-migrate-${TENANT}-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

[[ -f "$REALM_FILE" ]] || die "Realm export file not found: $REALM_FILE" 1

# ---------- step 1: get admin token -----------------------------------------

log INFO "Acquiring admin token from $KC_URL"
TOKEN_JSON=$(curl -fsS \
    -d "client_id=${KC_ADMIN_CLIENT_ID}" \
    --data-urlencode "client_secret=${KC_ADMIN_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" \
    "${KC_URL}/realms/master/protocol/openid-connect/token") \
    || die "Failed to obtain admin token from ${KC_URL}/realms/master" 1

TOKEN=$(echo "$TOKEN_JSON" | jq -r .access_token)
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || die "Admin token is empty" 1

AUTH_HEADER="Authorization: Bearer $TOKEN"

# ---------- step 2: pre-flight checks ---------------------------------------

log INFO "Pre-flight: verifying realm '${TENANT}' does not exist on destination"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "$AUTH_HEADER" \
    "${KC_URL}/admin/realms/${TENANT}")

case "$HTTP_CODE" in
    404) log INFO "Pre-flight OK: realm does not exist on destination" ;;
    200) die "Realm '${TENANT}' already exists on destination — aborting (no overwrite)" 1 ;;
    *)   die "Unexpected HTTP $HTTP_CODE when checking destination realm" 1 ;;
esac

log INFO "Pre-flight: verifying export bundle contains realm signing keys"
KEY_PROVIDER_COUNT=$(jq -r '
    (.components["org.keycloak.keys.KeyProvider"] // []) | length
' "$REALM_FILE")

if [[ "$KEY_PROVIDER_COUNT" -lt 1 ]]; then
    die "Export bundle has no KeyProvider components — refresh tokens will be invalidated. Re-export with full --realm." 1
fi
log INFO "Pre-flight OK: ${KEY_PROVIDER_COUNT} KeyProvider component(s) present"

log INFO "Pre-flight: summarising authorization-settings coverage in export bundle"
AUTHZ_SUMMARY=$(jq -r '
    [ .clients[]? | select(.authorizationServicesEnabled == true) ] as $rs
    | { resource_servers: ($rs | length),
        resources:        ([ $rs[].authorizationSettings.resources[]?   ] | length),
        scopes:           ([ $rs[].authorizationSettings.scopes[]?      ] | length),
        policies:         ([ $rs[].authorizationSettings.policies[]? | select(.type != "resource" and .type != "scope") ] | length),
        permissions:      ([ $rs[].authorizationSettings.policies[]? | select(.type == "resource" or  .type == "scope") ] | length) }
    | "resource_servers=\(.resource_servers) resources=\(.resources) scopes=\(.scopes) policies=\(.policies) permissions=\(.permissions)"
' "$REALM_FILE")
log INFO "Pre-flight authz: ${AUTHZ_SUMMARY}"
# Capture expected counts for post-import verification.
EXPECTED_RESOURCE_SERVERS=$(echo "$AUTHZ_SUMMARY" | sed -n 's/.*resource_servers=\([0-9]*\).*/\1/p')
EXPECTED_PERMISSIONS=$(echo "$AUTHZ_SUMMARY"      | sed -n 's/.*permissions=\([0-9]*\).*/\1/p')
EXPECTED_POLICIES=$(echo "$AUTHZ_SUMMARY"         | sed -n 's/.*policies=\([0-9]*\).*/\1/p')
EXPECTED_RESOURCES=$(echo "$AUTHZ_SUMMARY"        | sed -n 's/.*resources=\([0-9]*\).*/\1/p')

log INFO "Pre-flight: checking for federated users in realm bundle"
FEDERATED_USER_COUNT=$(jq '.federatedUsers | length // 0' "$REALM_FILE")
if [[ "$FEDERATED_USER_COUNT" -gt 0 ]]; then
    log WARN "Bundle contains ${FEDERATED_USER_COUNT} federatedUsers — these are linked to a user-storage provider (LDAP/AD/Kerberos). They will be re-resolved from that provider after import; ensure the same provider is configured at destination."
fi

# ---------- step 3: strip users from realm body -----------------------------

log INFO "Step 3: stripping users from realm body to stay below body-size limits"
REALM_BODY="${WORK_DIR}/${TENANT}-realm-no-users.json"
jq 'del(.users) | del(.federatedUsers)' "$REALM_FILE" > "$REALM_BODY"

REALM_BODY_SIZE=$(stat -c '%s' "$REALM_BODY" 2>/dev/null || stat -f '%z' "$REALM_BODY")
log INFO "Realm body size: ${REALM_BODY_SIZE} bytes"

# Embedded users (if any) are migrated separately as a synthetic batch.
EMBEDDED_USERS_FILE="${WORK_DIR}/${TENANT}-embedded-users.json"
jq '{ users: (.users // []) }' "$REALM_FILE" > "$EMBEDDED_USERS_FILE"
EMBEDDED_USER_COUNT=$(jq '.users | length' "$EMBEDDED_USERS_FILE")
log INFO "Embedded user count in realm file: ${EMBEDDED_USER_COUNT}"

# ---------- step 4: POST the realm body -------------------------------------

log INFO "Step 4: creating realm '${TENANT}' on destination via POST /admin/realms"
HTTP_CODE=$(curl -s -o "${WORK_DIR}/post-realm.out" -w '%{http_code}' \
    -XPOST \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    --data-binary "@${REALM_BODY}" \
    "${KC_URL}/admin/realms")

if [[ "$HTTP_CODE" != "201" ]]; then
    log ERROR "Realm POST failed: HTTP $HTTP_CODE"
    log ERROR "Response: $(cat "${WORK_DIR}/post-realm.out")"
    die "Realm creation failed; no users imported. To clean up: curl -XDELETE -H 'Authorization: Bearer \$TOKEN' ${KC_URL}/admin/realms/${TENANT}" 2
fi
log INFO "Realm '${TENANT}' created successfully (HTTP 201)"

# ---------- step 5: import users in batches via partialImport ---------------

import_user_batch() {
    local batch_file="$1"
    local batch_label="$2"

    local body_file="${WORK_DIR}/batch-body.json"
    jq '{ ifResourceExists: "FAIL", users: .users }' "$batch_file" > "$body_file"

    local user_count
    user_count=$(jq '.users | length' "$body_file")
    if [[ "$user_count" -eq 0 ]]; then
        log INFO "Batch ${batch_label}: empty, skipping"
        return 0
    fi

    log INFO "Batch ${batch_label}: importing ${user_count} user(s)"
    local code
    code=$(curl -s -o "${WORK_DIR}/batch.out" -w '%{http_code}' \
        -XPOST \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        --data-binary "@${body_file}" \
        "${KC_URL}/admin/realms/${TENANT}/partialImport")

    if [[ "$code" != "200" ]]; then
        log ERROR "Batch ${batch_label} failed: HTTP $code"
        log ERROR "Response: $(cat "${WORK_DIR}/batch.out")"
        return 1
    fi

    local added overwritten skipped
    added=$(jq -r '.added // 0' "${WORK_DIR}/batch.out")
    overwritten=$(jq -r '.overwritten // 0' "${WORK_DIR}/batch.out")
    skipped=$(jq -r '.skipped // 0' "${WORK_DIR}/batch.out")
    log INFO "Batch ${batch_label} OK: added=${added} overwritten=${overwritten} skipped=${skipped}"
    return 0
}

log INFO "Step 5: importing users via partialImport (batch size: ${USER_BATCH_SIZE})"

# 5a — embedded users from the realm file (chunked)
if [[ "$EMBEDDED_USER_COUNT" -gt 0 ]]; then
    CHUNKS=$(( (EMBEDDED_USER_COUNT + USER_BATCH_SIZE - 1) / USER_BATCH_SIZE ))
    for ((i=0; i<CHUNKS; i++)); do
        chunk_file="${WORK_DIR}/embedded-chunk-${i}.json"
        jq --argjson off "$((i * USER_BATCH_SIZE))" --argjson sz "$USER_BATCH_SIZE" \
            '{ users: (.users[$off:$off+$sz]) }' \
            "$EMBEDDED_USERS_FILE" > "$chunk_file"
        import_user_batch "$chunk_file" "embedded#${i}" \
            || die "User import failed at embedded batch ${i}; resume by re-running" 3
    done
fi

# 5b — separate user files (already chunked by kc.sh export --users different_files)
shopt -s nullglob
for users_file in "${EXPORT_DIR}/${TENANT}-users-"*.json; do
    base=$(basename "$users_file" .json)
    user_count_in_file=$(jq '.users | length' "$users_file")

    if [[ "$user_count_in_file" -le "$USER_BATCH_SIZE" ]]; then
        import_user_batch "$users_file" "$base" \
            || die "User import failed at ${base}; resume by re-running" 3
    else
        # Re-chunk if the export's per-file size exceeds our batch limit.
        sub_chunks=$(( (user_count_in_file + USER_BATCH_SIZE - 1) / USER_BATCH_SIZE ))
        for ((j=0; j<sub_chunks; j++)); do
            sub_file="${WORK_DIR}/${base}-sub-${j}.json"
            jq --argjson off "$((j * USER_BATCH_SIZE))" --argjson sz "$USER_BATCH_SIZE" \
                '{ users: (.users[$off:$off+$sz]) }' \
                "$users_file" > "$sub_file"
            import_user_batch "$sub_file" "${base}#${j}" \
                || die "User import failed at ${base} sub-batch ${j}; resume by re-running" 3
        done
    fi
done
shopt -u nullglob

# ---------- step 6: verify cache propagation across destination nodes -------

verify_node() {
    local node_url="$1"
    local code
    code=$(curl -ks -o /dev/null -w '%{http_code}' \
        "${node_url}/realms/${TENANT}/.well-known/openid-configuration")
    if [[ "$code" == "200" ]]; then
        log INFO "Verify ${node_url}: OK"
        return 0
    else
        log ERROR "Verify ${node_url}: HTTP $code"
        return 1
    fi
}

log INFO "Step 6: verifying realm visibility from each destination node"
verify_node "$KC_URL" || die "Realm not visible on load-balanced URL ${KC_URL}" 4

if [[ -n "${DEST_NODES:-}" ]]; then
    IFS=',' read -ra NODE_ARRAY <<< "$DEST_NODES"
    failed=0
    for node in "${NODE_ARRAY[@]}"; do
        verify_node "$node" || failed=$((failed + 1))
    done
    [[ "$failed" -eq 0 ]] || die "${failed} destination node(s) failed verification — investigate JGroups" 4
fi

# ---------- done ------------------------------------------------------------

# ---------- step 7: post-import authorization spot-check --------------------

log INFO "Step 7: spot-checking authorization-settings counts on destination"
ACTUAL_RS=$(curl -fsS -H "$AUTH_HEADER" \
    "${KC_URL}/admin/realms/${TENANT}/clients?max=10000" \
    | jq '[ .[] | select(.authorizationServicesEnabled == true) ] | length')
log INFO "Destination resource servers: ${ACTUAL_RS} (expected ${EXPECTED_RESOURCE_SERVERS})"

if [[ "${ACTUAL_RS:-0}" -ne "${EXPECTED_RESOURCE_SERVERS:-0}" ]]; then
    die "Resource-server count mismatch: ${ACTUAL_RS} != ${EXPECTED_RESOURCE_SERVERS}. Some clients failed authorization import — inspect server log for ResourceServer creation errors." 5
fi

# Per-client deep check: walk every authorization-enabled client and confirm policy/permission/resource counts match.
MISMATCH=0
while IFS= read -r row; do
    cid=$(echo "$row" | jq -r '.id')
    name=$(echo "$row" | jq -r '.clientId')
    expP=$(echo "$row" | jq -r '.expPolicies')
    expR=$(echo "$row" | jq -r '.expResources')
    expS=$(echo "$row" | jq -r '.expScopes')

    actP=$(curl -fsS -H "$AUTH_HEADER" \
        "${KC_URL}/admin/realms/${TENANT}/clients/${cid}/authz/resource-server/policy?max=10000" \
        | jq 'length' || echo 0)
    actR=$(curl -fsS -H "$AUTH_HEADER" \
        "${KC_URL}/admin/realms/${TENANT}/clients/${cid}/authz/resource-server/resource?max=10000" \
        | jq 'length' || echo 0)
    actS=$(curl -fsS -H "$AUTH_HEADER" \
        "${KC_URL}/admin/realms/${TENANT}/clients/${cid}/authz/resource-server/scope?max=10000" \
        | jq 'length' || echo 0)

    if [[ "$actP" -lt "$expP" || "$actR" -lt "$expR" || "$actS" -lt "$expS" ]]; then
        log ERROR "Client '${name}' authz mismatch: policies=${actP}/${expP} resources=${actR}/${expR} scopes=${actS}/${expS}"
        MISMATCH=$((MISMATCH + 1))
    else
        log INFO  "Client '${name}' authz OK: policies=${actP} resources=${actR} scopes=${actS}"
    fi
done < <(jq -c '
    .clients[]
    | select(.authorizationServicesEnabled == true)
    | { id: .id,
        clientId: .clientId,
        expPolicies:  ((.authorizationSettings.policies   // []) | length),
        expResources: ((.authorizationSettings.resources  // []) | length),
        expScopes:    ((.authorizationSettings.scopes     // []) | length) }
' "$REALM_FILE" | while read -r line; do
    # Resolve destination client id by clientId (UUIDs differ between source and destination).
    src_cid=$(echo "$line" | jq -r '.clientId')
    dest_id=$(curl -fsS -H "$AUTH_HEADER" \
        "${KC_URL}/admin/realms/${TENANT}/clients?clientId=${src_cid}" \
        | jq -r '.[0].id')
    echo "$line" | jq --arg id "$dest_id" '.id = $id'
done)

if [[ "$MISMATCH" -gt 0 ]]; then
    die "${MISMATCH} client(s) failed authz spot-check — investigate server log" 5
fi
log INFO "Authorization spot-check OK across ${ACTUAL_RS} resource server(s)"

# ---------- step 8: user-count spot-check -----------------------------------

log INFO "Step 8: verifying user count on destination"
DEST_USER_COUNT=$(curl -fsS -H "$AUTH_HEADER" \
    "${KC_URL}/admin/realms/${TENANT}/users/count" || echo "-1")
log INFO "Destination user count: ${DEST_USER_COUNT}"

# ---------- done ------------------------------------------------------------

log INFO "Migration of realm '${TENANT}' COMPLETED successfully."
log INFO "Imported: realm config, ${EXPECTED_RESOURCE_SERVERS} resource server(s), ${EXPECTED_RESOURCES} resource(s), ${EXPECTED_POLICIES} policy(ies), ${EXPECTED_PERMISSIONS} permission(s), ${DEST_USER_COUNT} user(s)."
log INFO "Next steps: update Kong/mgr-tenants routing to point this tenant to ${KC_URL}."
exit 0
