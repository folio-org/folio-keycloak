#!/bin/bash

clientId="$1"
clientSecret="$2"
script="setup-admin-client.sh"
adminApiScope="kc-admin-api"

# Logging function
log_info() {
    echo "$(date +%F' '%T,%3N) INFO  [$script] $1"
}

# Get client UUID by clientId
get_client_uuid() {
    local clientId="$1"
    /opt/keycloak/bin/kcadm.sh get clients -q clientId="$clientId" --fields id --format csv --noquotes
}

# Create or update realm roles mapper
setup_realm_roles_mapper() {
    local clientUuid="$1"

    mapperId=$(/opt/keycloak/bin/kcadm.sh create clients/"$clientUuid"/protocol-mappers/models \
        --target-realm master \
        -f - -i <<EOF
{
  "name": "realm roles",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-usermodel-realm-role-mapper",
  "config": {
    "claim.name": "realm_access.roles",
    "multivalued": "true",
    "access.token.claim": "true",
    "lightweight.claim": "true",
    "introspection.token.claim": "true"
  }
}
EOF
)
    log_info "Realm roles mapper created [id: $mapperId]"
}

# Assign the built-in admin API client scope: since Keycloak 26.8.2 the Admin REST API
# rejects tokens without its audience and scope
setup_admin_api_scope() {
    local clientUuid="$1"
    local clientId="$2"

    if /opt/keycloak/bin/kcadm.sh get clients/"$clientUuid"/default-client-scopes \
        --fields name --format csv --noquotes 2>/dev/null | grep -qx "$adminApiScope"; then
        log_info "Client scope '$adminApiScope' already assigned to '$clientId'"
        return
    fi

    local scopeId
    scopeId=$(/opt/keycloak/bin/kcadm.sh get client-scopes --fields id,name --format csv --noquotes \
        | grep ",$adminApiScope$" | cut -d, -f1)
    if [ -z "$scopeId" ]; then
        log_info "ERROR: Client scope '$adminApiScope' not found in master realm"
        exit 1
    fi

    /opt/keycloak/bin/kcadm.sh update clients/"$clientUuid"/default-client-scopes/"$scopeId" \
        --target-realm master
    log_info "Client scope '$adminApiScope' assigned to '$clientId'"
}

enable_lightweight_tokens() {
    local clientUuid="$1"
    local clientId="$2"

    local lightweightEnabled=$(/opt/keycloak/bin/kcadm.sh get clients/"$clientUuid" \
        --fields 'attributes(*)' 2>/dev/null | grep '"client.use.lightweight.access.token.enabled" : "true"')

    if [ -z "$lightweightEnabled" ]; then
        log_info "Enabling lightweight access tokens for client '$clientId'"
        /opt/keycloak/bin/kcadm.sh update clients/"$clientUuid" \
            --target-realm master \
            -f - &>/dev/null <<EOF
{
  "attributes": {
    "client.use.lightweight.access.token.enabled": "true"
  }
}
EOF
        log_info "Lightweight access tokens enabled for '$clientId'"
    else
        log_info "Lightweight access tokens already enabled for '$clientId'"
    fi

    if ! /opt/keycloak/bin/kcadm.sh get clients/"$clientUuid"/protocol-mappers/models \
        --fields name 2>/dev/null | grep -q "realm roles"; then
        setup_realm_roles_mapper "$clientUuid"
    else
        log_info "Realm roles mapper already exists for '$clientId'"
    fi
}

# Main logic
foundClient="$(/opt/keycloak/bin/kcadm.sh get clients --fields id,clientId 2>&1 | grep -oP "\"clientId\" : \"\K$clientId")"
log_info "Found client: '$foundClient'"

if [ "$foundClient" != "$clientId" ]; then
    log_info "Creating a new admin client [clientId(name): $clientId]"

    clientUuid=$(/opt/keycloak/bin/kcadm.sh create clients \
        --target-realm master \
        --set clientId="$clientId" \
        --set serviceAccountsEnabled=true \
        --set publicClient=false \
        --set clientAuthenticatorType=client-secret \
        --set secret="$clientSecret" \
        --set standardFlowEnabled=false \
        --set 'attributes."client.use.lightweight.access.token.enabled"=true' \
        -i)

    if [ -z "$clientUuid" ]; then
        log_info "ERROR: Failed to create client '$clientId'"
        exit 1
    fi

    /opt/keycloak/bin/kcadm.sh add-roles \
        --uusername service-account-"$clientId" \
        --rolename admin \
        --rolename create-realm \
        &>/dev/null

    setup_realm_roles_mapper "$clientUuid"
    setup_admin_api_scope "$clientUuid" "$clientId"

    log_info "Admin client '$clientId' has been created successfully"
else
    log_info "Admin client '$clientId' already exists"

    clientUuid=$(get_client_uuid "$clientId")
    if [ -z "$clientUuid" ]; then
        log_info "ERROR: Failed to get UUID for client '$clientId'"
        exit 1
    fi

    enable_lightweight_tokens "$clientUuid" "$clientId"
    setup_admin_api_scope "$clientUuid" "$clientId"
fi