#!/bin/bash

set -euo pipefail

# --- Configuration & Defaults ---
KEYCLOAK_URL=${KEYCLOAK_URL:-"http://localhost:8080"}
ADMIN_USER=${1:-${KC_ADMIN_USER:-"admin"}}
ADMIN_PASS=${2:-${KC_ADMIN_PASSWORD:-"admin"}}
CLIENT_ID_PATTERN=${CLIENT_ID_PATTERN:-"-application$"}
DRY_RUN=${DRY_RUN:-"true"}
PAGE_SIZE=${PAGE_SIZE:-100}
TENANT_IDS=${TENANT_IDS:-""}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-5}

# New Batching & Resilience Config
STATE_DIR="${STATE_DIR:-/tmp/kc_cleanup_$(id -u)}"
BATCH_SIZE="${BATCH_SIZE:-100}"
MAX_PARALLEL="${MAX_PARALLEL:-5}"
SLEEP_BETWEEN_BATCHES="${SLEEP_BETWEEN_BATCHES:-1}"

# Global Counters
TOTAL_REALMS_PROCESSED=0
TOTAL_CLIENTS_CHECKED=0
TOTAL_DEAD_ROLE_POLICIES=0
TOTAL_DEAD_PERMISSIONS=0

# In-Memory Cache for role existence checks
declare -A ROLE_EXISTS_CACHE

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
  return 1
}

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
      TOKEN=$(get_token)
      TOKEN_TIMESTAMP=$(date +%s)
      continue
    fi

    if [[ "$response" =~ ^5[0-9][0-9]$ ]] && (( attempt < MAX_RETRIES )); then
      sleep "$RETRY_DELAY"
      continue
    fi
    return 1
  done
  return 1
}

role_exists() {
  local realm=$1 role_id=$2
  
  # Check cache first
  if [[ -n "${ROLE_EXISTS_CACHE["$realm:$role_id"]+x}" ]]; then
    [[ "${ROLE_EXISTS_CACHE["$realm:$role_id"]}" == "true" ]]
    return $?
  fi

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${realm}/roles-by-id/${role_id}")
  
  if [[ "$code" == "200" ]]; then
    ROLE_EXISTS_CACHE["$realm:$role_id"]="true"
    return 0
  else
    ROLE_EXISTS_CACHE["$realm:$role_id"]="false"
    return 1
  fi
}

# --- Initialization ---
TOKEN=$(get_token)
TOKEN_TIMESTAMP=$(date +%s)
mkdir -p "$STATE_DIR"

if [[ -n "$TENANT_IDS" ]]; then
  IFS=',' read -ra REALMS <<< "$TENANT_IDS"
  declare -A seen_realms
  unique_realms=()
  for r in "${REALMS[@]}"; do
    if [[ -z "${seen_realms[$r]+x}" ]]; then
      seen_realms[$r]=1
      unique_realms+=("$r")
    fi
  done
  REALMS=("${unique_realms[@]}")
  echo "Using specified realms: ${REALMS[*]}"
else
  mapfile -t REALMS < <(curl_with_retry "${KEYCLOAK_URL}/admin/realms" | jq -r '.[].realm')
  echo "Fetched all realms from Keycloak (${#REALMS[@]} total)"
fi

# --- Main Processing Loop ---
for realm in "${REALMS[@]}"; do
  [[ "$realm" == "master" ]] && continue
  ((++TOTAL_REALMS_PROCESSED))
  refresh_token_if_needed
  echo "Processing realm: $realm"

  clients=$(curl_with_retry "${KEYCLOAK_URL}/admin/realms/${realm}/clients")

  while read -r client; do
    [[ -z "$client" ]] && continue
    client_uuid=$(echo "$client" | jq -r '.id')
    client_id=$(echo "$client" | jq -r '.clientId')
    
    # State directory for this specific client
    CLIENT_STATE_DIR="$STATE_DIR/$realm/$client_uuid"
    mkdir -p "$CLIENT_STATE_DIR"
    
    DEAD_ROLES_FILE="$CLIENT_STATE_DIR/dead_roles.txt"
    DEAD_PERMS_FILE="$CLIENT_STATE_DIR/dead_perms.txt"
    DELETED_IDS_FILE="$CLIENT_STATE_DIR/deleted_ids.txt"
    OFFSET_P1_FILE="$CLIENT_STATE_DIR/offset_p1.txt"
    OFFSET_P2_FILE="$CLIENT_STATE_DIR/offset_p2.txt"
    
    touch "$DEAD_ROLES_FILE" "$DEAD_PERMS_FILE" "$DELETED_IDS_FILE"

    ((++TOTAL_CLIENTS_CHECKED))
    refresh_token_if_needed
    echo "  Checking client: $client_id ($client_uuid)"

    # --- PHASE 1: Identify Dead Role Policies ---
    if [[ ! -f "$CLIENT_STATE_DIR/phase1_done" ]]; then
      offset=$(cat "$OFFSET_P1_FILE" 2>/dev/null || echo 0)
      [[ $offset -gt 0 ]] && echo "    [RESUME] Phase 1 at offset $offset"
      
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
            referenced_role_ids=$(echo "$roles_json" | jq -r 'if type == "array" then .[].id else .id end' 2>/dev/null || echo "")
            
            if [[ -n "$referenced_role_ids" ]]; then
              total_roles=0
              existing_roles=0
              while read -r rid; do
                [[ -z "$rid" ]] && continue
                ((++total_roles))
                if role_exists "$realm" "$rid"; then
                  ((++existing_roles))
                fi
              done <<< "$referenced_role_ids"

              if [[ $total_roles -gt 0 && $existing_roles -eq 0 ]]; then
                echo "    Found dead role policy: $pname ($pid)"
                echo "$pid" >> "$DEAD_ROLES_FILE"
                ((++TOTAL_DEAD_ROLE_POLICIES))
              fi
            fi
          fi
        done < <(echo "$policies_chunk" | jq -c '.[]')

        [[ "$count" -lt "$PAGE_SIZE" ]] && break
        ((offset += PAGE_SIZE))
        echo "$offset" > "$OFFSET_P1_FILE"
      done
      touch "$CLIENT_STATE_DIR/phase1_done"
      echo "    Phase 1 complete."
    else
      echo "    Phase 1 already complete, skipping."
    fi

    # --- PHASE 2: Identify Dead Permissions ---
    if [[ ! -f "$CLIENT_STATE_DIR/phase2_done" ]]; then
      # Build a local set of dead role IDs for fast lookup in Phase 2
      declare -A local_dead_roles
      while read -r dr_id; do local_dead_roles[$dr_id]=1; done < "$DEAD_ROLES_FILE"

      for type in "scope" "resource"; do
        offset=$(cat "${OFFSET_P2_FILE}_${type}" 2>/dev/null || echo 0)
        [[ $offset -gt 0 ]] && echo "    [RESUME] Phase 2 ($type) at offset $offset"

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
                  if [[ -n "${local_dead_roles[$aid]+x}" ]]; then
                    has_at_least_one_dead=true
                  else
                    all_assoc_are_dead=false
                    break
                  fi
                done <<< "$assoc_ids"

                if [[ "$has_at_least_one_dead" == "true" && "$all_assoc_are_dead" == "true" ]]; then
                  echo "    Found dead permission: $permname ($permid)"
                  echo "$permid" >> "$DEAD_PERMS_FILE"
                  ((++TOTAL_DEAD_PERMISSIONS))
                fi
              fi
            fi
          done < <(echo "$perms_chunk" | jq -c '.[]')

          [[ "$count" -lt "$PAGE_SIZE" ]] && break
          ((offset += PAGE_SIZE))
          echo "$offset" > "${OFFSET_P2_FILE}_${type}"
        done
      done
      touch "$CLIENT_STATE_DIR/phase2_done"
      echo "    Phase 2 complete."
      unset local_dead_roles
    else
      echo "    Phase 2 already complete, skipping."
    fi

    # --- PHASE 3: Deletion in Batches ---
    # Combine lists and filter out already deleted
    # We use sort -u to ensure uniqueness and then comm to find what hasn't been deleted yet
    sort -u "$DEAD_PERMS_FILE" > "${DEAD_PERMS_FILE}.tmp" && mv "${DEAD_PERMS_FILE}.tmp" "$DEAD_PERMS_FILE"
    sort -u "$DEAD_ROLES_FILE" > "${DEAD_ROLES_FILE}.tmp" && mv "${DEAD_ROLES_FILE}.tmp" "$DEAD_ROLES_FILE"
    sort -u "$DELETED_IDS_FILE" > "${DELETED_IDS_FILE}.tmp" && mv "${DELETED_IDS_FILE}.tmp" "$DELETED_IDS_FILE"

    # Order of deletion: Permissions FIRST, then Role Policies
    ALL_PENDING_PERMS=$(comm -23 "$DEAD_PERMS_FILE" "$DELETED_IDS_FILE")
    ALL_PENDING_ROLES=$(comm -23 "$DEAD_ROLES_FILE" "$DELETED_IDS_FILE")

    for list_type in "PERMISSIONS" "ROLE_POLICIES"; do
      if [[ "$list_type" == "PERMISSIONS" ]]; then 
        PENDING="$ALL_PENDING_PERMS"
      else 
        PENDING="$ALL_PENDING_ROLES"
      fi

      [[ -z "$PENDING" ]] && continue

      TOTAL_PENDING=$(echo "$PENDING" | wc -l | xargs)
      echo "    Starting deletion of $TOTAL_PENDING $list_type..."
      
      current_batch_count=0
      current_total_processed=0
      
      while read -r obj_id; do
        [[ -z "$obj_id" ]] && continue
        
        if [[ "$DRY_RUN" == "true" ]]; then
          echo "    [DRY-RUN] Would delete $list_type $obj_id"
          echo "$obj_id" >> "$DELETED_IDS_FILE"
        else
          # Execute in background for parallelism
          (
            if curl_delete_with_retry "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${obj_id}"; then
              echo "$obj_id" >> "$DELETED_IDS_FILE"
            else
              echo "    WARNING: Failed to delete $obj_id" >&2
            fi
          ) &
          
          ((++current_batch_count))
          if [[ $current_batch_count -ge $MAX_PARALLEL ]]; then
            wait
            current_batch_count=0
            sleep "$SLEEP_BETWEEN_BATCHES"
          fi
        fi

        ((++current_total_processed))
        if [[ $((current_total_processed % BATCH_SIZE)) -eq 0 || $current_total_processed -eq $TOTAL_PENDING ]]; then
           echo "    Progress: $current_total_processed / $TOTAL_PENDING $list_type processed."
        fi

      done <<< "$PENDING"
      wait # final wait for last background jobs
    done

    # Cleanup state for this client upon completion
    echo "    Completed client $client_id. Cleaning up state."
    rm -rf "$CLIENT_STATE_DIR"

  done < <(echo "$clients" | jq -c --arg pattern "$CLIENT_ID_PATTERN" '.[] | select(.clientId | test($pattern)) | select(.authorizationServicesEnabled == true)')
  
  # Cleanup realm state if empty
  rmdir "$STATE_DIR/$realm" 2>/dev/null || true
done

# Final cleanup of state root if empty
rmdir "$STATE_DIR" 2>/dev/null || true

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
  echo "Dead Role Policies handled: $TOTAL_DEAD_ROLE_POLICIES"
  echo "Dead Permissions handled:   $TOTAL_DEAD_PERMISSIONS"
fi
echo "================================================================"
echo "Done."
