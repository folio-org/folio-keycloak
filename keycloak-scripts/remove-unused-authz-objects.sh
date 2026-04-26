#!/bin/bash
# =============================================================================
# Keycloak Authorization Cleanup — Streaming, Resumable, Parallel
# =============================================================================
#
# Removes orphaned (dead) role-based policies and the permissions that depend
# only on them, for every client matching CLIENT_ID_PATTERN in one or all realms.
#
#
# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
#   ./keycloak-cleanup.sh [admin_user] [admin_password]
#
# Environment variables (all optional):
#   KEYCLOAK_URL          Base URL                      (default http://localhost:8080)
#   KC_ADMIN_USER         Admin user                    (default admin)
#   KC_ADMIN_PASSWORD     Admin password                (default admin)
#   CLIENT_ID_PATTERN     Regex for clientId            (default -application$)
#   TENANT_IDS            Comma-separated realms; empty = all realms
#   DRY_RUN               true|false                    (default true)
#   PAGE_SIZE             Page size for list endpoints  (default 100)
#   BATCH_SIZE            Deletes flushed per batch     (default 50)
#   PARALLEL_DELETES      Concurrent DELETE requests    (default 4)
#   BATCH_SLEEP_MS        Sleep between batches (ms)    (default 0)
#   MAX_RETRIES           Per-request retry count       (default 3)
#   RETRY_DELAY           Backoff between retries (s)   (default 5)
#   STATE_DIR             Where checkpoints live        (default ./.kc-cleanup-state)
#   RESET_STATE           true to wipe state and restart (default false)
#   LOG_FILE              Append structured log here    (default $STATE_DIR/run.log)
#
# -----------------------------------------------------------------------------
# Resume behaviour
# -----------------------------------------------------------------------------
# State layout:
#   $STATE_DIR/
#     run.log                       structured append-only log
#     realms.done                   one realm name per line, fully processed
#     <realm>/
#       clients.done                one client UUID per line, fully processed
#       roles.cache                 cached realm role IDs (rebuilt each run)
#       <client_uuid>.cursor        "phase=<n>;offset=<n>" for the in-progress client
#       <client_uuid>.dead_roles    newline list of dead role-policy IDs found so far
#                                   (kept so phase 2 can match permissions even on resume)
#
# A re-run with the same STATE_DIR skips everything in *.done and continues the
# in-progress client from its last cursor. Set RESET_STATE=true to start clean.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
KEYCLOAK_URL=${KEYCLOAK_URL:-"http://localhost:8080"}
ADMIN_USER=${1:-${KC_ADMIN_USER:-"admin"}}
ADMIN_PASS=${2:-${KC_ADMIN_PASSWORD:-"admin"}}
CLIENT_ID_PATTERN=${CLIENT_ID_PATTERN:-"-application$"}
TENANT_IDS=${TENANT_IDS:-""}
DRY_RUN=${DRY_RUN:-"true"}
PAGE_SIZE=${PAGE_SIZE:-100}
BATCH_SIZE=${BATCH_SIZE:-50}
PARALLEL_DELETES=${PARALLEL_DELETES:-4}
BATCH_SLEEP_MS=${BATCH_SLEEP_MS:-0}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-5}
STATE_DIR=${STATE_DIR:-"./.kc-cleanup-state"}
RESET_STATE=${RESET_STATE:-"false"}
LOG_FILE=${LOG_FILE:-"${STATE_DIR}/run.log"}

# Counters (persisted summary only; per-run aggregates)
TOTAL_REALMS_PROCESSED=0
TOTAL_CLIENTS_CHECKED=0
TOTAL_DEAD_ROLE_POLICIES=0
TOTAL_DEAD_PERMISSIONS=0
TOTAL_DELETED=0
TOTAL_DELETE_FAILURES=0

TOKEN=""
TOKEN_TIMESTAMP=0

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
[[ "$RESET_STATE" == "true" ]] && rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
: > /dev/null  # ensure shell evaluates redirections cleanly

log() {
  local level=$1; shift
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s [%s] %s\n' "$ts" "$level" "$*" | tee -a "$LOG_FILE"
}

die() { log "FATAL" "$*"; exit 1; }

if [[ "$DRY_RUN" == "true" ]]; then
  log "INFO" "DRY-RUN mode: no deletions will be performed. Set DRY_RUN=false to delete."
fi

log "INFO" "Config: url=$KEYCLOAK_URL pattern=$CLIENT_ID_PATTERN page=$PAGE_SIZE batch=$BATCH_SIZE parallel=$PARALLEL_DELETES sleep_ms=$BATCH_SLEEP_MS state=$STATE_DIR"

# -----------------------------------------------------------------------------
# Token handling
# -----------------------------------------------------------------------------
get_token() {
  local response token
  response=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d 'grant_type=password' \
    -d 'client_id=admin-cli')
  token=$(echo "$response" | jq -r '.access_token // empty')
  if [[ -z "$token" || "$token" == "null" ]]; then
    log "ERROR" "Token request failed: $(echo "$response" | jq -r '.error_description // .error // .')"
    return 1
  fi
  printf '%s' "$token"
}

ensure_token() {
  local now
  now=$(date +%s)
  if [[ -z "$TOKEN" || $(( now - TOKEN_TIMESTAMP )) -ge 240 ]]; then
    TOKEN=$(get_token) || die "Cannot obtain admin token"
    TOKEN_TIMESTAMP=$(date +%s)
  fi
}

# -----------------------------------------------------------------------------
# HTTP helpers — single retrying GET that prints body on stdout
# -----------------------------------------------------------------------------
api_get() {
  local url=$1 attempt=0 http_code body response
  while (( attempt < MAX_RETRIES )); do
    ((++attempt))
    ensure_token
    response=$(curl -s -w $'\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$url" || true)
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      printf '%s' "$body"
      return 0
    fi
    if [[ "$http_code" == "401" ]]; then
      log "WARN"  "GET 401 ($attempt/$MAX_RETRIES) — refreshing token"
      TOKEN=""; continue
    fi
    if [[ "$http_code" =~ ^5[0-9][0-9]$ ]] && (( attempt < MAX_RETRIES )); then
      log "WARN"  "GET $http_code ($attempt/$MAX_RETRIES) — sleeping ${RETRY_DELAY}s — $url"
      sleep "$RETRY_DELAY"; continue
    fi
    log "ERROR" "GET $http_code after $attempt attempts: $url"
    return 1
  done
  return 1
}

# DELETE one URL, returns 0 on 2xx/404, 1 otherwise. 404 is treated as
# already-deleted (idempotent — important for resume safety).
api_delete() {
  local url=$1 attempt=0 code
  while (( attempt < MAX_RETRIES )); do
    ((++attempt))
    ensure_token
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
      -H "Authorization: Bearer $TOKEN" "$url" || echo "000")
    if [[ "$code" =~ ^2[0-9][0-9]$ ]] || [[ "$code" == "404" ]]; then
      return 0
    fi
    if [[ "$code" == "401" ]]; then TOKEN=""; continue; fi
    if [[ "$code" =~ ^5[0-9][0-9]$ ]] && (( attempt < MAX_RETRIES )); then
      sleep "$RETRY_DELAY"; continue
    fi
    log "WARN" "DELETE $code: $url"
    return 1
  done
  return 1
}
export -f api_delete ensure_token get_token log
export TOKEN TOKEN_TIMESTAMP MAX_RETRIES RETRY_DELAY KEYCLOAK_URL ADMIN_USER ADMIN_PASS LOG_FILE

# -----------------------------------------------------------------------------
# Parallel batch deleter
# -----------------------------------------------------------------------------
# Reads URLs from stdin and DELETEs them in parallel. Writes "OK <url>" or
# "FAIL <url>" to stdout so the caller can update its checkpoint.
flush_delete_batch() {
  local urls_file=$1
  [[ ! -s "$urls_file" ]] && return 0

  if [[ "$DRY_RUN" == "true" ]]; then
    while IFS= read -r u; do
      log "INFO" "[DRY-RUN] DELETE $u"
      ((++TOTAL_DELETED))
    done < "$urls_file"
    return 0
  fi

  # Refresh token in the parent so all parallel workers inherit a fresh one.
  # (xargs -P spawns subshells which cannot mutate the parent's TOKEN.)
  ensure_token
  export TOKEN TOKEN_TIMESTAMP

  # xargs -P fans out parallel DELETEs. Each worker re-uses the fresh TOKEN
  # from the environment; on its own 401 it retries once with a re-auth.
  local results
  results=$(xargs -a "$urls_file" -I{} -P "$PARALLEL_DELETES" \
    bash -c 'if api_delete "$1"; then echo "OK $1"; else echo "FAIL $1"; fi' _ {})

  while IFS= read -r line; do
    case "$line" in
      OK\ *)   ((++TOTAL_DELETED));;
      FAIL\ *) ((++TOTAL_DELETE_FAILURES)); log "WARN" "$line";;
    esac
  done <<< "$results"

  if (( BATCH_SLEEP_MS > 0 )); then
    sleep "$(awk "BEGIN { print $BATCH_SLEEP_MS / 1000 }")"
  fi
}

# -----------------------------------------------------------------------------
# State / checkpoint helpers
# -----------------------------------------------------------------------------
realm_state_dir() { printf '%s/%s' "$STATE_DIR" "$1"; }

is_realm_done()  { grep -Fxq -- "$1" "$STATE_DIR/realms.done" 2>/dev/null; }
mark_realm_done(){ echo "$1" >> "$STATE_DIR/realms.done"; }

is_client_done() { grep -Fxq -- "$2" "$(realm_state_dir "$1")/clients.done" 2>/dev/null; }
mark_client_done(){ echo "$2" >> "$(realm_state_dir "$1")/clients.done"; }

# Cursor format:  phase=<1|2-scope|2-resource>;offset=<n>
read_cursor() {
  local realm=$1 client=$2 file
  file="$(realm_state_dir "$realm")/${client}.cursor"
  [[ -f "$file" ]] && cat "$file" || echo "phase=1;offset=0"
}
write_cursor() {
  local realm=$1 client=$2 phase=$3 offset=$4
  local dir; dir="$(realm_state_dir "$realm")"
  mkdir -p "$dir"
  printf 'phase=%s;offset=%s' "$phase" "$offset" > "${dir}/${client}.cursor"
}
clear_cursor() {
  rm -f "$(realm_state_dir "$1")/${2}.cursor" \
        "$(realm_state_dir "$1")/${2}.dead_roles"
}

append_dead_role() {
  echo "$3" >> "$(realm_state_dir "$1")/${2}.dead_roles"
}
load_dead_roles() {
  local f="$(realm_state_dir "$1")/${2}.dead_roles"
  [[ -f "$f" ]] && cat "$f" || true
}

# -----------------------------------------------------------------------------
# Realm role cache — single paged fetch, then O(1) lookups
# -----------------------------------------------------------------------------
declare -A REALM_ROLE_IDS
load_realm_roles() {
  local realm=$1 offset=0 chunk count
  REALM_ROLE_IDS=()
  log "INFO" "[$realm] Caching realm role IDs..."
  while :; do
    chunk=$(api_get "${KEYCLOAK_URL}/admin/realms/${realm}/roles?first=${offset}&max=${PAGE_SIZE}") || die "Failed to list roles in $realm"
    count=$(jq 'length' <<< "$chunk")
    [[ "$count" -eq 0 ]] && break
    while IFS= read -r rid; do
      [[ -n "$rid" ]] && REALM_ROLE_IDS["$rid"]=1
    done < <(jq -r '.[].id' <<< "$chunk")
    (( count < PAGE_SIZE )) && break
    (( offset += PAGE_SIZE ))
  done

  # Also cache client-level roles for every client, since role policies can
  # reference roles that live on a client (composite scenarios). One bulk call:
  local clients_json client_uuid roles_json
  clients_json=$(api_get "${KEYCLOAK_URL}/admin/realms/${realm}/clients?first=0&max=10000") || return 0
  while IFS= read -r client_uuid; do
    [[ -z "$client_uuid" ]] && continue
    roles_json=$(api_get "${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/roles?first=0&max=10000") || continue
    while IFS= read -r rid; do
      [[ -n "$rid" ]] && REALM_ROLE_IDS["$rid"]=1
    done < <(jq -r '.[].id' <<< "$roles_json")
  done < <(jq -r '.[].id' <<< "$clients_json")

  log "INFO" "[$realm] Cached ${#REALM_ROLE_IDS[@]} role IDs (realm + client roles)"
}

# -----------------------------------------------------------------------------
# Phase 1 — stream role policies, mark dead ones, delete in batches
# -----------------------------------------------------------------------------
process_role_policies() {
  local realm=$1 client_uuid=$2 client_id=$3 start_offset=$4
  local base="${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server"
  local offset=$start_offset chunk count batch_file
  local dead_in_phase=0
  batch_file=$(mktemp)
  trap "rm -f '$batch_file'" RETURN

  while :; do
    write_cursor "$realm" "$client_uuid" 1 "$offset"
    chunk=$(api_get "${base}/policy?type=role&first=${offset}&max=${PAGE_SIZE}") || break
    count=$(jq 'length' <<< "$chunk")
    [[ "$count" -eq 0 ]] && break

    # Each role policy embeds its referenced role ids inside .config.roles
    # which is a JSON-encoded string. Single jq pass extracts (id, name, [roleIds]).
    while IFS=$'\t' read -r pid pname role_ids_csv; do
      [[ -z "$pid" ]] && continue

      # If config.roles wasn't present on the list response, fall back to a
      # detail GET (rare path — newer Keycloak inlines it).
      if [[ -z "$role_ids_csv" || "$role_ids_csv" == "null" ]]; then
        local detail
        detail=$(api_get "${base}/policy/${pid}") || continue
        role_ids_csv=$(jq -r '
          (.config.roles // (.roles|tostring))
          | (try fromjson catch .)
          | if type=="array" then [.[].id] | join(",") else "" end
        ' <<< "$detail")
      fi

      [[ -z "$role_ids_csv" ]] && continue

      # Decide if every referenced role is missing.
      local total=0 alive=0 rid
      IFS=',' read -ra _rids <<< "$role_ids_csv"
      for rid in "${_rids[@]}"; do
        [[ -z "$rid" ]] && continue
        ((++total))
        [[ -n "${REALM_ROLE_IDS[$rid]+x}" ]] && ((++alive))
      done

      if (( total > 0 && alive == 0 )); then
        log "INFO" "  [$realm/$client_id] dead role-policy: $pname ($pid) refs=$total"
        echo "${base}/policy/${pid}" >> "$batch_file"
        append_dead_role "$realm" "$client_uuid" "$pid"
        ((++dead_in_phase))
        ((++TOTAL_DEAD_ROLE_POLICIES))

        if (( $(wc -l < "$batch_file") >= BATCH_SIZE )); then
          flush_delete_batch "$batch_file"
          : > "$batch_file"
        fi
      fi
    done < <(jq -r '
      .[] |
      [ .id,
        .name,
        ( (.config.roles // "")
          | (try fromjson catch [])
          | if type=="array" then [.[].id] | join(",") else "" end )
      ] | @tsv
    ' <<< "$chunk")

    (( count < PAGE_SIZE )) && break
    (( offset += PAGE_SIZE ))
  done

  flush_delete_batch "$batch_file"
  log "INFO" "  [$realm/$client_id] phase 1 complete — $dead_in_phase dead role policies in this client"
}

# -----------------------------------------------------------------------------
# Phase 2 — stream scope/resource permissions; delete those whose every
# associated policy is in our dead-role-policy set.
# -----------------------------------------------------------------------------
process_permissions() {
  local realm=$1 client_uuid=$2 client_id=$3 ptype=$4 start_offset=$5
  local base="${KEYCLOAK_URL}/admin/realms/${realm}/clients/${client_uuid}/authz/resource-server"
  local offset=$start_offset chunk count batch_file
  local phase_tag="2-${ptype}"
  local dead_in_phase=0
  batch_file=$(mktemp)
  trap "rm -f '$batch_file'" RETURN

  # Build a hash of dead role policy ids for this client.
  declare -A DEAD
  while IFS= read -r d; do [[ -n "$d" ]] && DEAD["$d"]=1; done < <(load_dead_roles "$realm" "$client_uuid")
  if (( ${#DEAD[@]} == 0 )); then
    log "INFO" "  [$realm/$client_id] no dead role policies — skipping permissions ($ptype)"
    return 0
  fi

  while :; do
    write_cursor "$realm" "$client_uuid" "$phase_tag" "$offset"
    chunk=$(api_get "${base}/policy?type=${ptype}&first=${offset}&max=${PAGE_SIZE}") || break
    count=$(jq 'length' <<< "$chunk")
    [[ "$count" -eq 0 ]] && break

    while IFS=$'\t' read -r pid pname assoc_csv; do
      [[ -z "$pid" ]] && continue

      if [[ -z "$assoc_csv" || "$assoc_csv" == "null" ]]; then
        # Fallback: GET associatedPolicies sub-resource (Keycloak >= 12)
        local assoc
        assoc=$(api_get "${base}/policy/${pid}/associatedPolicies") || continue
        assoc_csv=$(jq -r '[.[].id] | join(",")' <<< "$assoc")
      fi

      [[ -z "$assoc_csv" ]] && continue

      local total=0 dead=0 aid
      IFS=',' read -ra _aids <<< "$assoc_csv"
      for aid in "${_aids[@]}"; do
        [[ -z "$aid" ]] && continue
        ((++total))
        [[ -n "${DEAD[$aid]+x}" ]] && ((++dead))
      done

      if (( total > 0 && dead == total )); then
        log "INFO" "  [$realm/$client_id] dead $ptype permission: $pname ($pid)"
        echo "${base}/policy/${pid}" >> "$batch_file"
        ((++dead_in_phase))
        ((++TOTAL_DEAD_PERMISSIONS))

        if (( $(wc -l < "$batch_file") >= BATCH_SIZE )); then
          flush_delete_batch "$batch_file"
          : > "$batch_file"
        fi
      fi
    done < <(jq -r '
      .[] |
      [ .id,
        .name,
        ( (.config.applyPolicies // "")
          | (try fromjson catch [])
          | if type=="array" then (map(if type=="object" then .id else . end) | join(",")) else "" end )
      ] | @tsv
    ' <<< "$chunk")

    (( count < PAGE_SIZE )) && break
    (( offset += PAGE_SIZE ))
  done

  flush_delete_batch "$batch_file"
  log "INFO" "  [$realm/$client_id] phase $phase_tag complete — $dead_in_phase dead $ptype permissions"
}

# -----------------------------------------------------------------------------
# Per-client driver — honours resume cursor
# -----------------------------------------------------------------------------
process_client() {
  local realm=$1 client_uuid=$2 client_id=$3
  if is_client_done "$realm" "$client_uuid"; then
    log "DEBUG" "  [$realm/$client_id] already done — skipping"
    return 0
  fi
  ((++TOTAL_CLIENTS_CHECKED))
  log "INFO" "  [$realm/$client_id] starting (uuid=$client_uuid)"

  local cursor phase offset
  cursor=$(read_cursor "$realm" "$client_uuid")
  phase=${cursor#phase=}; phase=${phase%%;*}
  offset=${cursor##*offset=}
  log "INFO" "  [$realm/$client_id] resume cursor: phase=$phase offset=$offset"

  case "$phase" in
    1)
      process_role_policies "$realm" "$client_uuid" "$client_id" "$offset"
      process_permissions   "$realm" "$client_uuid" "$client_id" "scope"    0
      process_permissions   "$realm" "$client_uuid" "$client_id" "resource" 0
      ;;
    2-scope)
      process_permissions   "$realm" "$client_uuid" "$client_id" "scope"    "$offset"
      process_permissions   "$realm" "$client_uuid" "$client_id" "resource" 0
      ;;
    2-resource)
      process_permissions   "$realm" "$client_uuid" "$client_id" "resource" "$offset"
      ;;
    *)
      log "WARN" "Unknown phase '$phase' — restarting client"
      process_role_policies "$realm" "$client_uuid" "$client_id" 0
      process_permissions   "$realm" "$client_uuid" "$client_id" "scope"    0
      process_permissions   "$realm" "$client_uuid" "$client_id" "resource" 0
      ;;
  esac

  clear_cursor "$realm" "$client_uuid"
  mark_client_done "$realm" "$client_uuid"
  log "INFO" "  [$realm/$client_id] done"
}

# -----------------------------------------------------------------------------
# Per-realm driver
# -----------------------------------------------------------------------------
process_realm() {
  local realm=$1
  if is_realm_done "$realm"; then
    log "INFO" "[$realm] already complete — skipping"
    return 0
  fi
  ((++TOTAL_REALMS_PROCESSED))
  mkdir -p "$(realm_state_dir "$realm")"
  : >> "$(realm_state_dir "$realm")/clients.done"

  log "INFO" "[$realm] processing"
  load_realm_roles "$realm"

  local clients_json
  clients_json=$(api_get "${KEYCLOAK_URL}/admin/realms/${realm}/clients?first=0&max=10000") \
    || { log "ERROR" "[$realm] could not list clients"; return 1; }

  # Filter clients up-front in a single jq pass.
  while IFS=$'\t' read -r cuuid cid; do
    [[ -z "$cuuid" ]] && continue
    process_client "$realm" "$cuuid" "$cid"
  done < <(jq -r --arg pat "$CLIENT_ID_PATTERN" '
    .[]
    | select(.clientId | test($pat))
    | select(.authorizationServicesEnabled == true)
    | [.id, .clientId] | @tsv
  ' <<< "$clients_json")

  mark_realm_done "$realm"
  log "INFO" "[$realm] complete"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
trap 'log "WARN" "Interrupted — checkpoint preserved in $STATE_DIR. Re-run to resume."; exit 130' INT TERM

ensure_token

if [[ -n "$TENANT_IDS" ]]; then
  IFS=',' read -ra REALMS <<< "$TENANT_IDS"
  # de-dup
  declare -A _seen; uniq=()
  for r in "${REALMS[@]}"; do
    r=$(echo "$r" | xargs) # trim
    [[ -z "$r" ]] && continue
    [[ -z "${_seen[$r]+x}" ]] && { _seen[$r]=1; uniq+=("$r"); }
  done
  REALMS=("${uniq[@]}")
  log "INFO" "Targeting ${#REALMS[@]} realm(s): ${REALMS[*]}"
else
  mapfile -t REALMS < <(api_get "${KEYCLOAK_URL}/admin/realms" | jq -r '.[].realm')
  log "INFO" "Discovered ${#REALMS[@]} realm(s)"
fi

: >> "$STATE_DIR/realms.done"

for realm in "${REALMS[@]}"; do
  [[ "$realm" == "master" ]] && continue
  process_realm "$realm" || log "ERROR" "Realm $realm did not finish cleanly — will resume on next run"
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "================================================================"
echo "SUMMARY"
echo "================================================================"
printf 'Realms processed:          %s\n' "$TOTAL_REALMS_PROCESSED"
printf 'Clients checked:           %s\n' "$TOTAL_CLIENTS_CHECKED"
printf 'Dead role policies found:  %s\n' "$TOTAL_DEAD_ROLE_POLICIES"
printf 'Dead permissions found:    %s\n' "$TOTAL_DEAD_PERMISSIONS"
if [[ "$DRY_RUN" == "true" ]]; then
  printf '(dry-run — nothing was deleted)\n'
else
  printf 'Successfully deleted:      %s\n' "$TOTAL_DELETED"
  printf 'Delete failures:           %s\n' "$TOTAL_DELETE_FAILURES"
fi
echo "State dir: $STATE_DIR  (delete or set RESET_STATE=true to start fresh)"
echo "================================================================"
log "INFO" "Run finished."
