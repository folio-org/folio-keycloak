#!/bin/bash


set -euo pipefail

KEYCLOAK_URL=${KEYCLOAK_URL:-"http://localhost:8080"}
ADMIN_USER=${1:-${KC_ADMIN_USER:-"admin"}}
ADMIN_PASS=${2:-${KC_ADMIN_PASSWORD:-"admin"}}
CLIENT_ID_PATTERN=${CLIENT_ID_PATTERN:-"-application$"}
DRY_RUN=${DRY_RUN:-"true"}
PAGE_SIZE=${PAGE_SIZE:-100}

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

role_exists() {
  local realm=$1 role_id=$2 token=$3
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" \
    "${KEYCLOAK_URL}/admin/realms/${realm}/roles-by-id/${role_id}")
  [[ "$code" == "200" ]]
}

TOKEN=$(get_token)

REALMS=$(curl -s -H "Authorization: Bearer $TOKEN" "${KEYCLOAK_URL}/admin/realms" | jq -r '.[].realm')

for realm in $REALMS; do
  [[ "$realm" == "master" ]] && continue
  ((++TOTAL_REALMS_PROCESSED))
  echo "Processing realm: $realm"

  clients=$(curl -s -H "Authorization: Bearer $TOKEN" "${KEYCLOAK_URL}/admin/realms/${realm}/clients")
  
  while read -r client; do
    [[ -z "$client" ]] && continue
    ((++TOTAL_CLIENTS_CHECKED))

    client_uuid=$(echo "$client" | jq -r '.id')
    client_id=$(echo "$client" | jq -r '.clientId')
    echo "  Checking client: $client_id ($client_uuid)"

    # Initialize variables
    dead_role_policy_ids=()
    dead_permission_ids=()
    
    # --- PHASE 1: Identify all Dead Role Policies (Paginated) ---
    offset=0
    while true; do
      policies_chunk=$(curl -s -H "Authorization: Bearer $TOKEN" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy?type=role&first=${offset}&max=${PAGE_SIZE}")
      
      count=$(echo "$policies_chunk" | jq '. | length')
      [[ "$count" -eq 0 ]] && break

      while read -r policy; do
        pid=$(echo "$policy" | jq -r '.id')
        pname=$(echo "$policy" | jq -r '.name')
        
        policy_detail=$(curl -s -H "Authorization: Bearer $TOKEN" \
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
        perms_chunk=$(curl -s -H "Authorization: Bearer $TOKEN" \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy?type=${type}&first=${offset}&max=${PAGE_SIZE}")
        
        count=$(echo "$perms_chunk" | jq '. | length')
        [[ "$count" -eq 0 ]] && break

        while read -r perm; do
          permid=$(echo "$perm" | jq -r '.id')
          permname=$(echo "$perm" | jq -r '.name')
          
          perm_detail=$(curl -s -H "Authorization: Bearer $TOKEN" \
            "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${permid}")
          
          assoc_policies=$(echo "$perm_detail" | jq -r '.associatedPolicies // .config.applyPolicies // empty')

          if [[ -n "$assoc_policies" ]]; then
            if [[ "$assoc_policies" == \[* ]]; then
               assoc_ids=$(echo "$assoc_policies" | jq -r '.[].id')
            else
               assoc_ids=$(echo "$assoc_policies" | tr ',' '\n')
            fi
            
            if [[ -n "$assoc_ids" ]]; then
              all_assoc_are_dead=true
              has_at_least_one_dead=false
              
              while read -r aid; do
                [[ -z "$aid" ]] && continue
                is_dead=false
                for dead_id in "${dead_role_policy_ids[@]+"${dead_role_policy_ids[@]}"}"; do
                  if [[ "$aid" == "$dead_id" ]]; then
                    is_dead=true
                    has_at_least_one_dead=true
                    break
                  fi
                done
                if [[ "$is_dead" == "false" ]]; then
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
        curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${dpid}"
      fi
    done

    for drpid in ${dead_role_policy_ids[@]+"${dead_role_policy_ids[@]}"}; do
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "    [DRY-RUN] Would delete role policy $drpid"
      else
        echo "    Deleting role policy $drpid..."
        curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
          "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server/policy/${drpid}"
      fi
    done

  done < <(echo "$clients" | jq -c ".[] | select(.clientId | test(\"$CLIENT_ID_PATTERN\")) | select(.authorizationServicesEnabled == true)")
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
