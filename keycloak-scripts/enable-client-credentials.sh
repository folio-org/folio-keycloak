#!/bin/bash

keycloak=${1:-http://localhost:8080}
adminPassword=${KC_ADMIN_PASSWORD:admin}
adminUser=${KC_ADMIN_USER:admin}

# get token
token=$(curl -s -XPOST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'client_id=admin-cli' \
  --data-urlencode "username=$adminUser" \
  --data-urlencode "password=$adminPassword" \
  --data-urlencode 'grant_type=password' \
  "$keycloak/realms/master/protocol/openid-connect/token" | jq -r '.access_token'
)

echo "---- receiving token ------- [$token]"

# get client id
clientId=$(curl -s -XGET \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  "$keycloak/admin/realms/master/clients/?clientId=admin-cli" | jq -r '.[].id'
)
echo "---- obtained client_id ------- [$clientId]"

# get available scopes
availableRolesScope=$(curl -s -XGET \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  "$keycloak/admin/realms/master/clients/$clientId/scope-mappings/realm/available"
)

# post available
echo "---- assign available roles ------- [$availableRolesScope]"
curl -s -XPOST \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  -d "$availableRolesScope" \
  "$keycloak/admin/realms/master/clients/$clientId/scope-mappings/realm"

clientBody='{"publicClient":"false","serviceAccountsEnabled":"true"}'
curl -s -XPUT \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  -d "$clientBody" \
  "$keycloak/admin/realms/master/clients/$clientId"

# get service account
serviceAccountUser=$(curl -s -XGET \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  "$keycloak/admin/realms/master/clients/$clientId/service-account-user" | jq -r '.id'
)

echo "---- service account user ------- [$serviceAccountUser]"
# get svc account roles
serviceAccountRoles=$(curl -s -XGET \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  "$keycloak/admin/realms/master/users/$serviceAccountUser/role-mappings/realm/available"
)
echo "---- assign service account roles ----"
curl -s -XPOST \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  -d "$serviceAccountRoles" \
  "$keycloak/admin/realms/master/users/$serviceAccountUser/role-mappings/realm"

echo "---- retrieve client secret"

export CLIENT_SECRET=$(curl -s -XGET \
  -H "Authorization:Bearer $token" \
  -H 'Content-Type: application/json' \
  "$keycloak/admin/realms/master/clients/$clientId/client-secret" | jq -r '.value'
)

echo "---- client secret ------- [$CLIENT_SECRET]"
