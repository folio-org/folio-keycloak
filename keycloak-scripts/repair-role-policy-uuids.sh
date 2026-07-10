#!/usr/bin/env bash
# repair-role-policy-uuids.sh — Repair role + policy UUID mapping after a realm migration
# that regenerated Keycloak UUIDs: FOLIO's role.id / policy.id go stale and roles become
# un-editable (404 from Keycloak). Role-and-policy counterpart of repair-policy-uuids.sh;
# both are fixed in ONE FOLIO transaction because role ids are embedded in policy names
# on both sides: ids are re-mapped by name BEFORE any name is rewritten.
#
# Required: KC_DB_URL, FOLIO_DB_URL (postgresql://...), TENANT (realm name, e.g. "diku")
# Optional: DRY_RUN  — "true": run the FOLIO transaction and ROLLBACK, print the report,
#                      skip the Keycloak step entirely. Default: false.
#           FORCE    — "true": skip (instead of abort on) roles that exist in FOLIO but
#                      not in Keycloak. Default: false.
#           WORK_DIR — Where the role id map CSV is persisted.
#                      Default: /tmp/repair-role-policy-uuids-$TENANT
#
# Production prerequisites: run in a maintenance window (the FOLIO transaction locks the
# affected tables) and take a schema backup first:
#   pg_dump "$FOLIO_DB_URL" -n "${TENANT}_mod_roles_keycloak" > roles_backup.sql

set -euo pipefail

log()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "INFO"  "$1" >&2; }
warn() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "WARN"  "$1" >&2; }
die()  { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "ERROR" "$1" >&2; exit "${2:-1}"; }

require_env() {
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "Required environment variable not set: $v"
    done
}

require_env KC_DB_URL FOLIO_DB_URL TENANT

DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
WORK_DIR="${WORK_DIR:-/tmp/repair-role-policy-uuids-$TENANT}"
SCHEMA="${TENANT}_mod_roles_keycloak"
MAP_CSV="$WORK_DIR/role_id_map.csv"
mkdir -p "$WORK_DIR"

# psql wrappers. NOTE: psql does NOT interpolate :variables in `-c` strings, and \copy
# interpolates nothing at all — statements using :'tenant'/:"schema" must go via stdin,
# and \copy lines must have the schema expanded by bash.
run_folio() { psql "$FOLIO_DB_URL" -v ON_ERROR_STOP=1 -v schema="$SCHEMA" -v tenant="$TENANT" "$@"; }
run_kc()    { psql "$KC_DB_URL"    -v ON_ERROR_STOP=1 -v tenant="$TENANT" "$@"; }
q_folio()   { run_folio -qtA "$@"; }
q_kc()      { run_kc -qtA "$@"; }

cleanup_staging() {
    run_folio <<SQL || warn "Failed to drop FOLIO staging tables."
DROP TABLE IF EXISTS :"schema".kc_roles_staging;
DROP TABLE IF EXISTS :"schema".kc_policies_staging;
DROP TABLE IF EXISTS :"schema".role_id_map_staging;
SQL
    run_kc -c "DROP TABLE IF EXISTS role_uuid_map_staging;" >/dev/null 2>&1 || true
}

log "tenant=$TENANT schema=$SCHEMA dry_run=$DRY_RUN force=$FORCE work_dir=$WORK_DIR"

# ---------- Step 1: Export current roles and policies from Keycloak ----------

log "[1] Exporting Keycloak realm roles and policies..."

echo "SELECT 1 FROM realm WHERE name = :'tenant';" | q_kc | grep -q 1 \
    || die "Realm '$TENANT' not found in Keycloak."
echo "SELECT 1 FROM information_schema.schemata WHERE schema_name = :'schema';" | q_folio | grep -q 1 \
    || die "Schema '$SCHEMA' not found in FOLIO database."

q_kc <<'SQL' > "$WORK_DIR/kc_roles.csv" || die "Failed to export Keycloak realm roles."
COPY (
    SELECT id, name FROM keycloak_role
    WHERE realm_id = (SELECT id FROM realm WHERE name = :'tenant') AND client_role = false
) TO STDOUT WITH (FORMAT csv, HEADER true);
SQL

q_kc <<'SQL' > "$WORK_DIR/kc_policies.csv" || die "Failed to export Keycloak policies."
COPY (
    SELECT rsp.id, rsp.name
    FROM resource_server_policy rsp
    JOIN client c ON rsp.resource_server_id = c.id
    WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant')
) TO STDOUT WITH (FORMAT csv, HEADER true);
SQL

# ---------- Step 2: Stage the export in FOLIO and build the role map ---------

log "[2] Staging Keycloak export in FOLIO..."

run_folio <<'SQL' || die "Failed to create staging tables."
DROP TABLE IF EXISTS :"schema".kc_roles_staging;
DROP TABLE IF EXISTS :"schema".kc_policies_staging;
DROP TABLE IF EXISTS :"schema".role_id_map_staging;
CREATE TABLE :"schema".kc_roles_staging   (id uuid, name text);
CREATE TABLE :"schema".kc_policies_staging (id uuid, name text);
CREATE TABLE :"schema".role_id_map_staging (old_id uuid, new_id uuid, name text);
SQL

run_folio <<SQL || die "Failed to load staging tables."
\\copy ${SCHEMA}.kc_roles_staging (id, name) FROM '$WORK_DIR/kc_roles.csv' WITH (FORMAT csv, HEADER true)
\\copy ${SCHEMA}.kc_policies_staging (id, name) FROM '$WORK_DIR/kc_policies.csv' WITH (FORMAT csv, HEADER true)
SQL

run_folio <<'SQL' || die "Failed to build the role id map."
INSERT INTO :"schema".role_id_map_staging (old_id, new_id, name)
SELECT r.id, k.id, r.name
FROM :"schema".role r
JOIN :"schema".kc_roles_staging k ON k.name = r.name
WHERE r.id IS DISTINCT FROM k.id;
SQL

# ---------- Step 3: Pre-flight checks -----------------------------------------

log "[3] Pre-flight checks..."

# Hard-coded reinsert column lists MUST match the live schema: an incomplete list would
# silently NULL/reset columns on reinsert (DEFAULT columns do not error). Abort on drift.
col_mismatch=$(q_folio <<'SQL'
WITH expected(tbl, cols) AS (
  VALUES
    ('user_role',               ARRAY['user_id','role_id','created_by_user_id','created_date','updated_by_user_id','updated_date']),
    ('role_capability',         ARRAY['role_id','capability_id','created_by_user_id','created_date','updated_by_user_id','updated_date']),
    ('role_capability_set',     ARRAY['role_id','capability_set_id','created_by_user_id','created_date','updated_by_user_id','updated_date']),
    ('role_loadable',           ARRAY['id','loaded_from_file']),
    ('role_loadable_permission',ARRAY['role_loadable_id','folio_permission','capability_id','capability_set_id','created_by_user_id','created_date','updated_by_user_id','updated_date']),
    ('policy_roles',            ARRAY['policy_id','role_id','required']),
    ('policy_users',            ARRAY['policy_id','user_id'])
),
actual AS (
  SELECT table_name::text AS tbl, array_agg(column_name::text ORDER BY column_name::text) AS cols
  FROM information_schema.columns
  WHERE table_schema = :'schema'
  GROUP BY table_name
)
SELECT e.tbl || ' expected=' || (SELECT array_agg(c ORDER BY c) FROM unnest(e.cols) c)::text
              || ' actual='   || COALESCE(a.cols::text, '<missing table>')
FROM expected e
LEFT JOIN actual a ON a.tbl = e.tbl
WHERE a.cols IS NULL
   OR (SELECT array_agg(c ORDER BY c) FROM unnest(e.cols) c) IS DISTINCT FROM a.cols;
SQL
)
[[ -z "$col_mismatch" ]] || die "Schema drift detected; fix the script's column lists before running:
$col_mismatch"

# Names are the mapping keys — duplicates would make the repair non-deterministic.
dup_roles=$(echo 'SELECT string_agg(name, chr(44)) FROM (SELECT name FROM :"schema".kc_roles_staging GROUP BY name HAVING count(*) > 1) d;' | q_folio)
[[ -z "$dup_roles" ]] || die "Duplicate realm role names in Keycloak (cannot map by name): $dup_roles"
dup_policies=$(echo 'SELECT string_agg(name, chr(44)) FROM (SELECT name FROM :"schema".kc_policies_staging GROUP BY name HAVING count(*) > 1) d;' | q_folio)
[[ -z "$dup_policies" ]] || die "Duplicate policy names across Keycloak resource servers (cannot map by name): $dup_policies"

folio_only=$(q_folio <<'SQL'
SELECT string_agg(r.name || ' (' || r.id || ')', ', ')
FROM :"schema".role r LEFT JOIN :"schema".kc_roles_staging k ON k.name = r.name
WHERE k.id IS NULL;
SQL
)
if [[ -n "$folio_only" ]]; then
    if [[ "$FORCE" == "true" ]]; then
        warn "Roles present in FOLIO but not in Keycloak (FORCE => skipped, NOT repaired): $folio_only"
    else
        die "Roles present in FOLIO but not in Keycloak (set FORCE=true to skip them): $folio_only"
    fi
fi

# Work detection: role/policy id drift + stale role ids embedded in names (either side).
role_diff=$(echo 'SELECT count(*) FROM :"schema".role_id_map_staging;' | q_folio)
policy_diff=$(q_folio <<'SQL'
SELECT count(*) FROM :"schema".policy p
JOIN :"schema".kc_policies_staging k ON k.name = p.name
WHERE p.id IS DISTINCT FROM k.id;
SQL
)
folio_stale=$(q_folio <<'SQL'
SET search_path TO :"schema";
SELECT count(*) FROM policy
WHERE name LIKE 'Policy for role: %'
  AND substring(name FROM 'Policy for role: (.*)$') NOT IN (SELECT id::text FROM role);
SQL
)
kc_stale=$(q_kc <<'SQL'
WITH ids AS (
  SELECT DISTINCT substring(rsp.name FROM 'for role:? ''?([0-9a-fA-F-]{36})') AS uid
  FROM resource_server_policy rsp
  JOIN client c ON rsp.resource_server_id = c.id
  WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant')
    AND (rsp.name LIKE 'Policy for role: %' OR rsp.name LIKE '% access for role %')
)
SELECT count(*) FROM ids
WHERE uid IS NOT NULL AND uid NOT IN (
  SELECT id::text FROM keycloak_role
  WHERE realm_id = (SELECT id FROM realm WHERE name = :'tenant') AND client_role = false);
SQL
)
log "    role id mismatches: $role_diff, policy id mismatches: $policy_diff, stale names: FOLIO=$folio_stale KC=$kc_stale"

if [[ "$role_diff" == "0" && "$policy_diff" == "0" ]]; then
    if [[ "$folio_stale" == "0" && "$kc_stale" == "0" ]]; then
        log "Nothing to do: FOLIO ids already match Keycloak and no stale names. Exiting."
        cleanup_staging
        exit 0
    fi
    die "Ids match but stale names remain (FOLIO=$folio_stale, KC=$kc_stale) — a previous run likely failed between the FOLIO commit and the Keycloak step. See 'Manual recovery' in README.md (uses $MAP_CSV from that run)."
fi

# ---------- Step 4: Persist the role id map (recovery key) --------------------

echo 'COPY (SELECT old_id, new_id, name FROM :"schema".role_id_map_staging) TO STDOUT WITH (FORMAT csv, HEADER true);' \
    | q_folio > "$MAP_CSV" || die "Failed to write role id map."
log "[4] Role id map written to $MAP_CSV"

# ---------- Step 5: FOLIO transaction (id fix + name rewrite) -----------------

tx_end="COMMIT"
[[ "$DRY_RUN" == "true" ]] && tx_end="ROLLBACK"
log "[5] FOLIO transaction (end=$tx_end)..."

run_folio -v tx_end="$tx_end" <<'SQL' || die "FOLIO transaction failed (rolled back)."
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"schema";

-- Block concurrent writers (mod-roles-keycloak) for the whole repair; readers pass.
LOCK TABLE role, policy, user_role, role_capability, role_capability_set,
           role_loadable, role_loadable_permission, policy_roles, policy_users
IN EXCLUSIVE MODE;

-- Maps must be built while names still embed the OLD role ids on both sides.
CREATE TEMP TABLE role_map AS
  SELECT old_id, new_id, name FROM role_id_map_staging;
CREATE TEMP TABLE policy_map AS
  SELECT p.id AS old_id, k.id AS new_id, p.name
  FROM policy p JOIN kc_policies_staging k ON k.name = p.name
  WHERE p.id IS DISTINCT FROM k.id;

-- Capture children with NEW ids substituted, then delete/update/reinsert: no FK is
-- ON UPDATE CASCADE or deferrable, and role_loadable is ON DELETE RESTRICT.
CREATE TEMP TABLE b_user_role AS
  SELECT rm.new_id AS role_id, t.user_id, t.created_by_user_id, t.created_date, t.updated_by_user_id, t.updated_date
  FROM user_role t JOIN role_map rm ON rm.old_id = t.role_id;
CREATE TEMP TABLE b_role_capability AS
  SELECT rm.new_id AS role_id, t.capability_id, t.created_by_user_id, t.created_date, t.updated_by_user_id, t.updated_date
  FROM role_capability t JOIN role_map rm ON rm.old_id = t.role_id;
CREATE TEMP TABLE b_role_capability_set AS
  SELECT rm.new_id AS role_id, t.capability_set_id, t.created_by_user_id, t.created_date, t.updated_by_user_id, t.updated_date
  FROM role_capability_set t JOIN role_map rm ON rm.old_id = t.role_id;
CREATE TEMP TABLE b_role_loadable AS
  SELECT rm.new_id AS id, t.loaded_from_file
  FROM role_loadable t JOIN role_map rm ON rm.old_id = t.id;
CREATE TEMP TABLE b_role_loadable_permission AS
  SELECT rm.new_id AS role_loadable_id, t.folio_permission, t.capability_id, t.capability_set_id,
         t.created_by_user_id, t.created_date, t.updated_by_user_id, t.updated_date
  FROM role_loadable_permission t JOIN role_map rm ON rm.old_id = t.role_loadable_id;
CREATE TEMP TABLE b_policy_roles AS
  SELECT COALESCE(pm.new_id, t.policy_id) AS policy_id,
         COALESCE(rm.new_id, t.role_id)   AS role_id, t.required
  FROM policy_roles t
  LEFT JOIN policy_map pm ON pm.old_id = t.policy_id
  LEFT JOIN role_map   rm ON rm.old_id = t.role_id
  WHERE pm.new_id IS NOT NULL OR rm.new_id IS NOT NULL;
CREATE TEMP TABLE b_policy_users AS
  SELECT pm.new_id AS policy_id, t.user_id
  FROM policy_users t JOIN policy_map pm ON pm.old_id = t.policy_id;

DELETE FROM role_loadable_permission WHERE role_loadable_id IN (SELECT old_id FROM role_map);
DELETE FROM role_loadable            WHERE id       IN (SELECT old_id FROM role_map);
DELETE FROM user_role                WHERE role_id  IN (SELECT old_id FROM role_map);
DELETE FROM role_capability          WHERE role_id  IN (SELECT old_id FROM role_map);
DELETE FROM role_capability_set      WHERE role_id  IN (SELECT old_id FROM role_map);
DELETE FROM policy_roles
  WHERE policy_id IN (SELECT old_id FROM policy_map)
     OR role_id   IN (SELECT old_id FROM role_map);
DELETE FROM policy_users             WHERE policy_id IN (SELECT old_id FROM policy_map);

-- If a future migration adds a table with an FK to role(id)/policy(id) not handled
-- above, these UPDATEs fail on that FK and everything rolls back — never silent.
UPDATE role   r SET id = m.new_id FROM role_map   m WHERE r.id = m.old_id;
UPDATE policy p SET id = m.new_id FROM policy_map m WHERE p.id = m.old_id;

UPDATE policy p
SET name        = replace(p.name,        m.old_id::text, m.new_id::text),
    description = replace(p.description, m.old_id::text, m.new_id::text)
FROM role_map m
WHERE p.name LIKE '%' || m.old_id::text || '%'
   OR p.description LIKE '%' || m.old_id::text || '%';

INSERT INTO role_loadable (id, loaded_from_file)
  SELECT id, loaded_from_file FROM b_role_loadable;
INSERT INTO role_loadable_permission
  (role_loadable_id, folio_permission, capability_id, capability_set_id,
   created_by_user_id, created_date, updated_by_user_id, updated_date)
  SELECT * FROM b_role_loadable_permission;
INSERT INTO user_role (role_id, user_id, created_by_user_id, created_date, updated_by_user_id, updated_date)
  SELECT * FROM b_user_role;
INSERT INTO role_capability (role_id, capability_id, created_by_user_id, created_date, updated_by_user_id, updated_date)
  SELECT * FROM b_role_capability;
INSERT INTO role_capability_set (role_id, capability_set_id, created_by_user_id, created_date, updated_by_user_id, updated_date)
  SELECT * FROM b_role_capability_set;
INSERT INTO policy_roles (policy_id, role_id, required)
  SELECT * FROM b_policy_roles;
INSERT INTO policy_users (policy_id, user_id)
  SELECT * FROM b_policy_users;

-- Every role with a same-named Keycloak role must now carry the Keycloak id.
DO $assert$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM role r
  WHERE r.id NOT IN (SELECT id FROM kc_roles_staging)
    AND r.name IN (SELECT name FROM kc_roles_staging);
  IF bad > 0 THEN RAISE EXCEPTION 'ASSERT: % role(s) still have ids absent from Keycloak', bad; END IF;
END
$assert$;

\echo '--- role id remap (name, old_id, new_id) ---'
SELECT name, old_id, new_id FROM role_map ORDER BY name;
\echo '--- policy id remap count ---'
SELECT count(*) AS policies_remapped FROM policy_map;

:tx_end;
SQL

if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN: FOLIO transaction rolled back; Keycloak step skipped."
    cleanup_staging
    log "Dry-run complete. Map preview at $MAP_CSV."
    exit 0
fi

# ---------- Step 6: Keycloak rewrite (policy names + policy_config) -----------

log "[6] Keycloak name rewrite..."

run_kc <<'SQL' || die "Failed to create Keycloak staging table."
DROP TABLE IF EXISTS role_uuid_map_staging;
CREATE TABLE role_uuid_map_staging (old_id uuid, new_id uuid, name text);
SQL
run_kc -c "\copy role_uuid_map_staging (old_id, new_id, name) FROM '$MAP_CSV' WITH (FORMAT csv, HEADER true);" \
    || die "Failed to load the role id map into Keycloak."

# FOLIO is already committed here, so abort with a clear message rather than letting the
# UNIQUE (name, resource_server_id) constraint fire mid-rewrite.
kc_collision=$(q_kc <<'SQL'
WITH rewritten AS (
  SELECT rsp.resource_server_id AS rs,
         COALESCE((SELECT replace(rsp.name, m.old_id::text, m.new_id::text)
                   FROM role_uuid_map_staging m
                   WHERE strpos(rsp.name, m.old_id::text) > 0 LIMIT 1), rsp.name) AS nm
  FROM resource_server_policy rsp
  JOIN client c ON rsp.resource_server_id = c.id
  WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant')
)
SELECT count(*) FROM (SELECT rs, nm FROM rewritten GROUP BY rs, nm HAVING count(*) > 1) d;
SQL
)
[[ "$kc_collision" == "0" ]] || die "Keycloak rewrite would create $kc_collision duplicate policy name(s); FOLIO is already committed — resolve manually (see README 'Manual recovery', map: $MAP_CSV)."

run_kc <<'SQL' || die "Keycloak rewrite failed; FOLIO is already committed — re-apply via README 'Manual recovery' using the saved map."
\set ON_ERROR_STOP on
BEGIN;
-- psql does not interpolate :'tenant' inside the dollar-quoted DO body below;
-- pass it via a transaction-local GUC instead.
SELECT set_config('repair.tenant', :'tenant', true);

UPDATE resource_server_policy rsp
SET name = replace(rsp.name, m.old_id::text, m.new_id::text)
FROM role_uuid_map_staging m
WHERE rsp.resource_server_id IN (
        SELECT c.id FROM client c WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant'))
  AND strpos(rsp.name, m.old_id::text) > 0;

-- policy_config 'roles' values are JSON arrays that may embed SEVERAL stale role ids,
-- while UPDATE ... FROM applies at most one map row per target row. Loop until no row
-- matches; a no-op when the config is already consistent.
DO $config_remap$
DECLARE n bigint;
BEGIN
  LOOP
    UPDATE policy_config pc
    SET value = replace(pc.value, m.old_id::text, m.new_id::text)
    FROM role_uuid_map_staging m
    WHERE pc.name = 'roles'
      AND strpos(pc.value, m.old_id::text) > 0
      AND pc.policy_id IN (
        SELECT rsp.id FROM resource_server_policy rsp
        JOIN client c ON rsp.resource_server_id = c.id
        WHERE c.realm_id = (SELECT id FROM realm WHERE name = current_setting('repair.tenant')));
    GET DIAGNOSTICS n = ROW_COUNT;
    EXIT WHEN n = 0;
  END LOOP;
END
$config_remap$;
COMMIT;
SQL

# ---------- Step 7: Cleanup ----------------------------------------------------

cleanup_staging
log "Repair complete for tenant $TENANT. Re-run the script to verify: it must report 'Nothing to do'."
log "Map kept at $MAP_CSV — delete it once roles are confirmed editable."
warn "Keycloak caches authorization data in memory: perform a rolling restart of all"
warn "Keycloak nodes OR call POST /admin/realms/$TENANT/clear-realm-cache before"
warn "actively managing the repaired roles."
