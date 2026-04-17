#!/bin/bash


set -euo pipefail

KEYCLOAK_URL=${KEYCLOAK_URL:-"http://localhost:8080"}
ADMIN_USER=${1:-${KC_ADMIN_USER:-"admin"}}
ADMIN_PASS=${2:-${KC_ADMIN_PASSWORD:-"admin"}}
CLIENT_ID_PATTERN=${CLIENT_ID_PATTERN:-"-application$"}
DRY_RUN=${DRY_RUN:-"true"}
PAGE_SIZE=${PAGE_SIZE:-100}
TENANT_IDS=${TENANT_IDS:-""}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-5}

# Global Counters
TOTAL_REALMS_PROCESSED=0
TOTAL_CLIENTS_CHECKED=0
TOTAL_DEAD_ROLE_POLICIES=0
TOTAL_DEAD_PERMISSIONS=0

if [[ "$DRY_RUN" == "true" ]]; then
  echo "================================================================"
  echo "RUNNING IN DRY-RUN MODE. Set DRY_RUN=false to perform deletions."
  echo "================================================================"
fi

TOKEN_TIMESTAMP=0

get_token() {
  local response
  response=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d 'grant_type=password' \
    -d 'client_id=admin-cli')

  local token
  token=$(echo "$response" | jq -r .access_token)
  if [[ "$token" == "null" || -z "$token" ]]; then
    local error_msg
    error_msg=$(echo "$response" | jq -r .error_description)
    echo "ERROR: Failed to retrieve admin token. Please check credentials." >&2
    [[ -n "$error_msg" ]] && echo "Details: $error_msg" >&2
    exit 1
  fi
  echo "$token"
}

refresh_token_if_needed() {
  local now
  now=$(date +%s)
  local elapsed=$(( now - TOKEN_TIMESTAMP ))
  if [[ $elapsed -ge 300 ]]; then
    TOKEN=$(get_token)
    TOKEN_TIMESTAMP=$(date +%s)
    echo "  [TOKEN] Refreshed admin token (was ${elapsed}s old)"
  fi
}

# Curl wrapper with retry logic and HTTP status checking.
# Usage: curl_with_retry [-X METHOD] URL
# Outputs response body to stdout. Exits on persistent failure.
curl_with_retry() {
  local attempt=0 http_code body response
  while (( attempt < MAX_RETRIES )); do
    ((++attempt))
    response=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" "$@")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      echo "$body"
      return 0
    fi

    if [[ "$http_code" == "401" ]]; then
      echo "  [RETRY] Got 401, refreshing token (attempt ${attempt}/${MAX_RETRIES})..." >&2
      TOKEN=$(get_token)
      TOKEN_TIMESTAMP=$(date +%s)
      continue
    fi

    if [[ "$http_code" =~ ^5[0-9][0-9]$ ]] && (( attempt < MAX_RETRIES )); then
      echo "  [RETRY] Got HTTP ${http_code}, retrying in ${RETRY_DELAY}s (attempt ${attempt}/${MAX_RETRIES})..." >&2
      sleep "$RETRY_DELAY"
      continue
    fi

    echo "ERROR: HTTP ${http_code} after ${attempt} attempts for: curl $*" >&2
    echo "$body" >&2
    return 1
  done

  echo "ERROR: Exhausted ${MAX_RETRIES} retries for: curl $*" >&2
  return 1
}

# DELETE wrapper with retry and status verification.
# Returns 0 on success (2xx), 1 on failure.
curl_delete_with_retry() {
  local attempt=0 http_code response
  while (( attempt < MAX_RETRIES )); do
    ((++attempt))
    refresh_token_if_needed
    response=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $TOKEN" "$@")

    if [[ "$response" =~ ^2[0-9][0-9]$ ]]; then
      return 0
    fi

    if [[ "$response" == "401" ]]; then
      echo "    [RETRY] Got 401 on DELETE, refreshing token (attempt ${attempt}/${MAX_RETRIES})..." >&2
      TOKEN=$(get_token)
      TOKEN_TIMESTAMP=$(date +%s)
      continue
    fi

    if [[ "$response" =~ ^5[0-9][0-9]$ ]] && (( attempt < MAX_RETRIES )); then
      echo "    [RETRY] Got HTTP ${response} on DELETE, retrying in ${RETRY_DELAY}s (attempt ${attempt}/${MAX_RETRIES})..." >&2
      sleep "$RETRY_DELAY"
      continue
    fi

    echo "    WARNING: DELETE returned HTTP ${response} after ${attempt} attempts for: $*" >&2
    return 1
  done

  echo "    WARNING: DELETE exhausted ${MAX_RETRIES} retries for: $*" >&2
  return 1
}

role_exists() {
  local realm=$1 role_id=$2 token=$3
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" \
    "${KEYCLOAK_URL}/admin/realms/${realm}/roles-by-id/${role_id}")
  [[ "$code" == "200" ]]
}

TOKEN=$(get_token)
TOKEN_TIMESTAMP=$(date +%s)

if [[ -n "$TENANT_IDS" ]]; then
  IFS=',' read -ra REALMS <<< "$TENANT_IDS"
  # Remove duplicates while preserving order
  declare -A seen_realms
  unique_realms=()
  for r in "${REALMS[@]}"; do
    if [[ -z "${seen_realms[$r]+x}" ]]; then
      seen_realms[$r]=1
      unique_realms+=("$r")
    fi
  done
  REALMS=("${unique_realms[@]}")
  unset seen_realms unique_realms
  echo "Using specified realms: ${REALMS[*]}"
else
  mapfile -t REALMS < <(curl_with_retry "${KEYCLOAK_URL}/admin/realms" | jq -r '.[].realm')
  echo "Fetched all realms from Keycloak (${#REALMS[@]} total)"
fi

for realm in "${REALMS[@]}"; do
  [[ "$realm" == "master" ]] && continue
  ((++TOTAL_REALMS_PROCESSED))
  refresh_token_if_needed
  echo "Processing realm: $realm"

  clients=$(curl_with_retry "${KEYCLOAK_URL}/admin/realms/${realm}/clients")

  while read -r client; do
    [[ -z "$client" ]] && continue
    ((++TOTAL_CLIENTS_CHECKED))
    refresh_token_if_needed

    client_uuid=$(echo "$client" | jq -r '.id')
    client_id=$(echo "$client" | jq -r '.clientId')
    echo "  Checking client: $client_id ($client_uuid)"

    # Initialize variables
    dead_role_policy_ids=()
    dead_permission_ids=()
    declare -A dead_role_policy_set=()
    
    # --- PHASE 1: Identify all Dead Role Policies (Paginated) ---
    offset=0
    while true; do
      refresh_token_if_needed
      policies_chunk=$(curl_with_retry \
        "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy?type=role&first=${offset}&max=${PAGE_SIZE}")
      
      count=$(echo "$policies_chunk" | jq '. | length')
      [[ "$count" -eq 0 ]] && break

      while read -r policy; do
        pid=$(echo "$policy" | jq -r '.id')
        pname=$(echo "$policy" | jq -r '.name')
        
        policy_detail=$(curl_with_retry \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${pid}")
        
        roles_json=$(echo "$policy_detail" | jq -r '.roles // .config.roles // empty')
        
        if [[ -n "$roles_json" ]]; then
          if [[ "$roles_json" == \[* ]]; then
             referenced_role_ids=$(echo "$roles_json" | jq -r '.[].id')
          else
             referenced_role_ids=$(echo "$roles_json" | jq -r '.[].id' 2>/dev/null || echo "")
          fi
          
          if [[ -n "$referenced_role_ids" ]]; then
            total_roles=0
            existing_roles=0
            while read -r rid; do
              [[ -z "$rid" ]] && continue
              ((++total_roles))
              if role_exists "$realm" "$rid" "$TOKEN"; then
                ((++existing_roles))
              fi
            done <<< "$referenced_role_ids"

            if [[ $total_roles -gt 0 && $existing_roles -eq 0 ]]; then
              echo "    Found dead role policy: $pname ($pid)"
              dead_role_policy_ids=("${dead_role_policy_ids[@]+"${dead_role_policy_ids[@]}"}" "$pid")
              dead_role_policy_set[$pid]=1
              ((++TOTAL_DEAD_ROLE_POLICIES))
            fi
          fi
        fi
      done < <(echo "$policies_chunk" | jq -c '.[]')

      [[ "$count" -lt "$PAGE_SIZE" ]] && break
      ((offset += PAGE_SIZE))
    done

    if [[ ${#dead_role_policy_ids[@]} -eq 0 ]]; then
      echo "    No dead role policies found."
      continue
    fi

    # --- PHASE 2: Identify Dead Permissions (Paginated) ---
    for type in "scope" "resource"; do
      offset=0
      while true; do
        refresh_token_if_needed
        perms_chunk=$(curl_with_retry \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy?type=${type}&first=${offset}&max=${PAGE_SIZE}")
        
        count=$(echo "$perms_chunk" | jq '. | length')
        [[ "$count" -eq 0 ]] && break

        while read -r perm; do
          permid=$(echo "$perm" | jq -r '.id')
          permname=$(echo "$perm" | jq -r '.name')
          
          perm_detail=$(curl_with_retry \
            "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${permid}")
          
          assoc_policies=$(echo "$perm_detail" | jq -r '.associatedPolicies // .config.applyPolicies // empty')

          if [[ -n "$assoc_policies" ]]; then
            if [[ "$assoc_policies" == \[* ]]; then
               assoc_ids=$(echo "$assoc_policies" | jq -r '.[] | if type == "object" then .id else . end')
            else
               assoc_ids=$(echo "$assoc_policies" | tr ',' '\n')
            fi
            
            if [[ -n "$assoc_ids" ]]; then
              all_assoc_are_dead=true
              has_at_least_one_dead=false
              
              while read -r aid; do
                [[ -z "$aid" ]] && continue
                if [[ -n "${dead_role_policy_set[$aid]+x}" ]]; then
                  has_at_least_one_dead=true
                else
                  all_assoc_are_dead=false
                  break
                fi
              done <<< "$assoc_ids"

              if [[ "$has_at_least_one_dead" == "true" && "$all_assoc_are_dead" == "true" ]]; then
                echo "    Found dead permission: $permname ($permid)"
                dead_permission_ids=("${dead_permission_ids[@]+"${dead_permission_ids[@]}"}" "$permid")
                ((++TOTAL_DEAD_PERMISSIONS))
              fi
            fi
          fi
        done < <(echo "$perms_chunk" | jq -c '.[]')

        [[ "$count" -lt "$PAGE_SIZE" ]] && break
        ((offset += PAGE_SIZE))
      done
    done

    # --- PHASE 3: Deletion ---
    for dpid in ${dead_permission_ids[@]+"${dead_permission_ids[@]}"}; do
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [DRY-RUN] Would delete permission $dpid"
      else
        echo "    Deleting permission $dpid..."
        if ! curl_delete_with_retry \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${dpid}"; then
          echo "    WARNING: Failed to delete permission $dpid"
        fi
      fi
    done

    for drpid in ${dead_role_policy_ids[@]+"${dead_role_policy_ids[@]}"}; do
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [DRY-RUN] Would delete role policy $drpid"
      else
        echo "    Deleting role policy $drpid..."
        if ! curl_delete_with_retry \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${drpid}"; then
          echo "    WARNING: Failed to delete role policy $drpid"
        fi
      fi
    done

  done < <(echo "$clients" | jq -c --arg pattern "$CLIENT_ID_PATTERN" '.[] | select(.clientId | test($pattern)) | select(.authorizationServicesEnabled == true)')
done

echo ""
echo "================================================================"
echo "SUMMARY REPORT"
echo "================================================================"
echo "Realms processed:        $TOTAL_REALMS_PROCESSED"
echo "Clients checked:         $TOTAL_CLIENTS_CHECKED"
echo "----------------------------------------------------------------"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dead Role Policies found: $TOTAL_DEAD_ROLE_POLICIES (NOT deleted)"
  echo "Dead Permissions found:   $TOTAL_DEAD_PERMISSIONS (NOT deleted)"
else
  echo "Dead Role Policies deleted: $TOTAL_DEAD_ROLE_POLICIES"
  echo "Dead Permissions deleted:   $TOTAL_DEAD_PERMISSIONS"
fi
echo "================================================================"
echo "Done."
