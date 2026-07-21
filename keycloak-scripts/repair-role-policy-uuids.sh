#!/usr/bin/env bash
# repair-role-policy-uuids.sh — Re-align FOLIO mod_roles_keycloak with Keycloak after a tenant
# realm is exported and re-imported into the SAME Keycloak cluster under a new name (the FOLIO
# schema carried over as-is).
#
# WHAT BREAKS. Such a migration desynchronises up to three things by three different mechanisms.
# Any one can occur without the others, so do not infer the whole picture from a single symptom:
#   1. realm import  → role UUIDs regenerated (keycloak_role has a cluster-wide primary key and the
#                      source realm still holds the old ids), leaving FOLIO's role.id stale and
#                      roles un-editable (404 from Keycloak);
#   2. user import   → folio user ids regenerated while Keycloak re-resolves its users by username,
#                      so every 'Policy for user: <folio id>' name points at a user id that no
#                      longer exists anywhere;
#   3. policy import → policy UUIDs may be regenerated or may carry over intact. Intact ids with
#                      stale NAME strings is a normal outcome, not a contradiction: the name embeds
#                      an entity id, and it is the entity that moved.
# Keycloak's own enforcement survives all three (policy_config is re-resolved on import); what
# breaks is mod-roles-keycloak's ability to find its policies by name.
#
# HOW IT MATCHES. Policies are matched between FOLIO and Keycloak by a canonical ENTITY KEY, never
# by policy name — a policy's name embeds the id of the entity it references, i.e. the very id that
# desyncs. The key is routed by name shape and resolved from the live entity reference:
#
#     name shape                  key            resolved from
#     Policy for role: <uuid>  →  role:<name>    KC: policy_config['roles'] → keycloak_role.name
#                                                FOLIO: policy_roles.role_id → role.name
#     Policy for user: <uuid>  →  user:<folioId> KC: policy_config['users'] → user_entity → attr 'user_id'
#                                                FOLIO: policy_users.user_id
#     anything else            →  name:<name>    the literal policy name (admin/TIME policies)
#
# Role names and folio user ids are stable across the migration, so the key matches even though the
# ids in the names do not. Names are OUTPUT: rewritten from the maps, never a join key.
#
# WHAT IT SYNCHRONISES. role.id and policy.id (FOLIO adopts Keycloak's), the FOLIO child tables
# referencing them, and every name/description string embedding a role id or folio user id on BOTH
# sides (policies AND permissions). Anything it cannot synchronise is reported, never silently
# skipped: unmatched policies, multi-entity or unresolvable policies, and — for the out-of-scope
# "users were recreated" case — a hard abort (this script has no folio-user-id map source).
#
# WRITE ORDER — DO NOT SWAP. Keycloak is rewritten first, the FOLIO transaction commits second.
# The two databases share no transaction, so a run can die between them; this order is what makes a
# plain re-run sufficient. Both id maps are derived from FOLIO's ids still differing from Keycloak's,
# and the Keycloak step rewrites only name/description STRINGS — never Keycloak ids. So after a crash
# in between, the next run re-derives exactly the same maps and finishes. Commit FOLIO first instead
# and the difference the maps are built from is gone, which is why that ordering needs a persisted
# map and a resume mode. It had one; it was removed on purpose.
#
# Required: KC_DB_URL, FOLIO_DB_URL (postgresql://...), TENANT (realm name, e.g. "diku")
# Optional: DRY_RUN — "true": skip the Keycloak rewrite, run the FOLIO transaction and ROLLBACK,
#                     print the report. Nothing is written to either database. Default: false.
#           FORCE   — "true": skip (instead of abort on) roles that exist in FOLIO but not Keycloak.
#                     Default: false.
#           WORK_DIR — Scratch space for the CSVs the run passes between the two databases; kept
#                     afterwards for diagnosis only. Default: /tmp/repair-role-policy-uuids-$TENANT
#
# Production prerequisites: run in a maintenance window (the FOLIO transaction locks the affected
# tables) and take a schema backup first:
#   pg_dump "$FOLIO_DB_URL" -n "${TENANT}_mod_roles_keycloak" > roles_backup.sql
# Keycloak caches authorization data in memory: after a repair, rolling-restart all Keycloak nodes
# OR call POST /admin/realms/$TENANT/clear-realm-cache before managing the repaired roles.

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
# The maps are computed in FOLIO but applied in Keycloak; these CSVs are the transport between the
# two connections, nothing more. They are not a recovery mechanism — a failed run is re-run.
ROLE_MAP_CSV="$WORK_DIR/role_id_map.csv"     # old_id,new_id,name  (role UUIDs, FOLIO→KC)
USER_MAP_CSV="$WORK_DIR/user_id_map.csv"     # old_id,new_id       (folio user ids in KC names)
KC_LEFTOVER=0                                # set by kc_rewrite; read by the final status
mkdir -p "$WORK_DIR"

# psql wrappers. NOTE: psql does NOT interpolate :variables in `-c` strings, and \copy interpolates
# nothing — statements using :'tenant'/:"schema" must go via stdin, and \copy lines must have the
# schema/path expanded by bash.
run_folio() { psql "$FOLIO_DB_URL" -v ON_ERROR_STOP=1 -v schema="$SCHEMA" -v tenant="$TENANT" "$@"; }
run_kc()    { psql "$KC_DB_URL"    -v ON_ERROR_STOP=1 -v tenant="$TENANT" "$@"; }
q_folio()   { run_folio -qtA "$@"; }
q_kc()      { run_kc -qtA "$@"; }

# Count Keycloak names of the form 'Policy/…​ for role|user: <id>' whose embedded id resolves to
# neither a live realm role nor a live folio user (user_id attribute). Used twice: as work detection
# before the run (names left pointing at entities the migration replaced) and as the leftover check
# after the rewrite (a stale id no map covered — e.g. a user with permissions but no policy).
kc_unresolved_count() {
    q_kc <<'SQL'
WITH ids AS (
  SELECT DISTINCT substring(rsp.name FROM 'for (?:role|user):? ''?([0-9a-fA-F-]{36})') AS uid
  FROM resource_server_policy rsp
  JOIN client c ON rsp.resource_server_id = c.id
  WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant')
    AND rsp.name ~ 'for (role|user):? '
)
SELECT count(*) FROM ids
WHERE uid IS NOT NULL
  AND uid NOT IN (SELECT id::text FROM keycloak_role
                  WHERE realm_id = (SELECT id FROM realm WHERE name = :'tenant') AND client_role = false)
  AND uid NOT IN (SELECT ua.value FROM user_attribute ua JOIN user_entity ue ON ue.id = ua.user_id
                  WHERE ua.name = 'user_id' AND ue.realm_id = (SELECT id FROM realm WHERE name = :'tenant'));
SQL
}

cleanup_staging() {
    run_folio <<SQL || warn "Failed to drop FOLIO staging tables."
DROP TABLE IF EXISTS :"schema".kc_roles_staging;
DROP TABLE IF EXISTS :"schema".kc_policies_staging;
DROP TABLE IF EXISTS :"schema".policy_key_staging;
DROP TABLE IF EXISTS :"schema".role_id_map_staging;
DROP TABLE IF EXISTS :"schema".kc_user_ids_staging;
SQL
    run_kc -c "DROP TABLE IF EXISTS role_uuid_map_staging; DROP TABLE IF EXISTS user_uuid_map_staging;" >/dev/null 2>&1 || true
}

# Everything this run could NOT synchronise. Called before every exit that follows classification —
# including the "nothing to repair" ones, where silence would otherwise read as "all clear".
# Reads the staging tables, so it must run before cleanup_staging; uses ur_total/ur_matched from
# the pre-flight, so it must run after step 3.
report_skipped() {
    local skipped
    skipped=$(q_folio <<'SQL'
SELECT string_agg(src || ' ' || class || ' "' || name || '" [' || status || ']', chr(10) ORDER BY status, name)
FROM (
  SELECT 'FOLIO' AS src, class, name, status FROM :"schema".policy_key_staging  WHERE status IN ('folio_only','multi','unresolved')
  UNION ALL
  SELECT 'KC',    class, name, status FROM :"schema".kc_policies_staging WHERE status IN ('kc_only','multi','unresolved')
) d;
SQL
) || die "Failed to collect the skipped-policy report."
    local stale_users=""
    if [[ "$ur_matched" != "$ur_total" ]]; then
        stale_users=$(q_folio <<'SQL'
SELECT string_agg(DISTINCT ur.user_id::text, chr(10))
FROM :"schema".user_role ur
LEFT JOIN :"schema".kc_user_ids_staging k ON k.folio_user_id = ur.user_id
WHERE k.folio_user_id IS NULL;
SQL
) || die "Failed to collect the stale user-link report."
    fi
    if [[ -n "$skipped" || -n "$stale_users" ]]; then
        warn "Could not synchronise (reported, not repaired):"
        [[ -n "$skipped" ]] && printf '%s\n' "$skipped" >&2
        [[ -n "$stale_users" ]] && warn "FOLIO user_role.user_id not known to Keycloak (stale user link):" && printf '%s\n' "$stale_users" >&2
        warn "(Anything created after the Keycloak export also lands here; re-run to confirm it is genuine.)"
    else
        log "Could not synchronise: nothing — every policy on both sides found its counterpart."
    fi
}

# ==========================================================================================
# Keycloak string rewrite (step 6, the FIRST of the two writes). Rewrites resource_server_policy
# name + description and policy_config['roles'] from the two map CSVs. Idempotent: it substitutes
# old ids that are no longer present after a first pass, so a repeat is a no-op.
# ==========================================================================================
kc_rewrite() {
    log "[6] Keycloak name/description rewrite..."

    run_kc <<'SQL' || die "Failed to create Keycloak staging tables."
DROP TABLE IF EXISTS role_uuid_map_staging;
DROP TABLE IF EXISTS user_uuid_map_staging;
CREATE TABLE role_uuid_map_staging (old_id uuid, new_id uuid, name text);
CREATE TABLE user_uuid_map_staging (old_id uuid, new_id uuid);
SQL
    run_kc -c "\copy role_uuid_map_staging (old_id, new_id, name) FROM '$ROLE_MAP_CSV' WITH (FORMAT csv, HEADER true);" \
        || die "Failed to load the role id map into Keycloak."
    run_kc -c "\copy user_uuid_map_staging (old_id, new_id) FROM '$USER_MAP_CSV' WITH (FORMAT csv, HEADER true);" \
        || die "Failed to load the user id map into Keycloak."

    # Empty maps mean nothing embeds a stale id in Keycloak (only FOLIO ids had drifted, or the names
    # were already current) — a legitimate no-op, not an error.
    local map_rows
    map_rows=$(q_kc -c "SELECT (SELECT count(*) FROM role_uuid_map_staging) + (SELECT count(*) FROM user_uuid_map_staging);")
    if [[ "${map_rows:-0}" == "0" ]]; then
        log "No Keycloak-side rewrite needed (maps are empty)."
        KC_LEFTOVER="$(kc_unresolved_count)"; KC_LEFTOVER="${KC_LEFTOVER:-0}"
        return 0
    fi

    # Abort cleanly rather than letting the UNIQUE (name, resource_server_id) constraint fire
    # mid-rewrite. Nothing has been written to either database at this point.
    local collision
    collision=$(q_kc <<'SQL'
WITH m AS (
  SELECT old_id::text AS old_id, new_id::text AS new_id FROM role_uuid_map_staging
  UNION ALL
  SELECT old_id::text, new_id::text FROM user_uuid_map_staging),
rewritten AS (
  SELECT rsp.resource_server_id AS rs,
         COALESCE((SELECT replace(rsp.name, m.old_id, m.new_id) FROM m
                   WHERE strpos(rsp.name, m.old_id) > 0 LIMIT 1), rsp.name) AS nm
  FROM resource_server_policy rsp
  JOIN client c ON rsp.resource_server_id = c.id
  WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant'))
SELECT count(*) FROM (SELECT rs, nm FROM rewritten GROUP BY rs, nm HAVING count(*) > 1) d;
SQL
)
    [[ "$collision" == "0" ]] || die "Keycloak rewrite would create $collision duplicate policy name(s). Nothing was written; resolve the duplicate names in Keycloak (maps for reference in $WORK_DIR) and re-run."

    run_kc <<'SQL' || die "Keycloak rewrite failed; it is a single transaction, so nothing was written. Fix the cause and re-run."
\set ON_ERROR_STOP on
BEGIN;
-- psql does not interpolate :'tenant' inside the dollar-quoted DO body below; pass it via a
-- transaction-local GUC instead.
SELECT set_config('repair.tenant', :'tenant', true);

-- Names + descriptions embedding a role id (policies and 'access for role ...' permissions) and a
-- folio user id (policies and 'access for user ...' permissions). Both maps, one pass each: every
-- target is a resource_server_policy row, so substring substitution covers all of them.
UPDATE resource_server_policy rsp
SET name        = replace(rsp.name,        m.old_id::text, m.new_id::text),
    description = replace(coalesce(rsp.description, ''), m.old_id::text, m.new_id::text)
FROM (SELECT old_id, new_id FROM role_uuid_map_staging
      UNION ALL SELECT old_id, new_id FROM user_uuid_map_staging) m
WHERE rsp.resource_server_id IN (
        SELECT c.id FROM client c WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant'))
  AND (strpos(rsp.name, m.old_id::text) > 0 OR strpos(coalesce(rsp.description,''), m.old_id::text) > 0);

-- policy_config 'roles' values are JSON arrays that may embed SEVERAL stale role ids, while
-- UPDATE ... FROM applies at most one map row per target row. Loop until no row matches (capped, so
-- a swapped map cannot spin forever). user policy_config['users'] holds internal KC user_entity.id,
-- which the import re-resolved — it is already correct and NOT a rewrite target.
DO $config_remap$
DECLARE n bigint; guard int := 0;
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
    guard := guard + 1;
    EXIT WHEN n = 0;
    IF guard > 100 THEN RAISE EXCEPTION 'policy_config remap did not converge in 100 passes (map has a chain or swap)'; END IF;
  END LOOP;
END
$config_remap$;
COMMIT;
SQL

    # Leftover check: after all rewrites, any name still embedding an id that resolves to no live
    # entity is a stale id no map covered (e.g. a user with permissions but no policy). Reported, not
    # fatal, but the run ends on a WARN, not "complete".
    KC_LEFTOVER="$(kc_unresolved_count)"
    KC_LEFTOVER="${KC_LEFTOVER:-0}"
}

log "tenant=$TENANT schema=$SCHEMA dry_run=$DRY_RUN force=$FORCE work_dir=$WORK_DIR"

# ---------- Step 1: Export current roles, policies and user ids from Keycloak ----------

log "[1] Exporting Keycloak realm roles, policies and user ids..."

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

# Policies restricted to the match set (role/user/time); scope/resource/client policies are not
# match candidates — they are rewrite targets only. Per policy we emit the canonical key plus refs
# (how many entities it references), which drives the multi-entity classification; an entity that
# does not resolve contributes no name, leaving the key empty. Config shapes differ:
#   roles  → [{"id":"<roleId>","required":false}, ...]   (array of objects)
#   users  → ["<user_entity.id>", ...]                    (array of scalars)
q_kc <<'SQL' > "$WORK_DIR/kc_policies.csv" || die "Failed to export Keycloak policies."
COPY (
  WITH pol AS (
    SELECT rsp.id, rsp.name, rsp.type
    FROM resource_server_policy rsp
    JOIN client c ON rsp.resource_server_id = c.id
    WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant')
      AND rsp.type IN ('role','user','time')
  ),
  role_ref AS (   -- role policies: config['roles'] -> keycloak_role.name
    SELECT p.id, count(*) AS refs, min(kr.name) AS ent
    FROM pol p
    JOIN policy_config pc ON pc.policy_id = p.id AND pc.name = 'roles' AND pc.value LIKE '[%'
    CROSS JOIN LATERAL json_array_elements(pc.value::json) e
    LEFT JOIN keycloak_role kr ON kr.id = (e->>'id')
      AND kr.realm_id = (SELECT id FROM realm WHERE name = :'tenant') AND kr.client_role = false
    WHERE p.name LIKE 'Policy for role: %'
    GROUP BY p.id
  ),
  user_ref AS (   -- user policies: config['users'] -> user_entity.id -> attr 'user_id' (folio id)
    -- count DISTINCT e, not rows: a user carrying two 'user_id' attribute rows would otherwise
    -- inflate refs to 2 and get the policy written off as multi-entity. (The role branch above
    -- joins on a primary key, so count(*) is already one row per referenced entity there — and
    -- DISTINCT is not even available on it, json having no equality operator.)
    SELECT p.id, count(DISTINCT e) AS refs, min(ua.value) AS ent
    FROM pol p
    JOIN policy_config pc ON pc.policy_id = p.id AND pc.name = 'users' AND pc.value LIKE '[%'
    CROSS JOIN LATERAL json_array_elements_text(pc.value::json) e
    LEFT JOIN user_attribute ua ON ua.user_id = e AND ua.name = 'user_id'
    WHERE p.name LIKE 'Policy for user: %'
    GROUP BY p.id
  )
  SELECT p.id, p.name, p.type AS class,
         COALESCE(rr.refs, ur.refs, 0) AS refs,
         CASE
           WHEN p.name LIKE 'Policy for role: %' THEN 'role:' || COALESCE(rr.ent, '')
           WHEN p.name LIKE 'Policy for user: %' THEN 'user:' || COALESCE(ur.ent, '')
           ELSE 'name:' || p.name
         END AS key
  FROM pol p
  LEFT JOIN role_ref rr ON rr.id = p.id
  LEFT JOIN user_ref ur ON ur.id = p.id
) TO STDOUT WITH (FORMAT csv, HEADER true);
SQL

# All folio user ids Keycloak knows (via the user_id attribute), for the §4 user-link check.
q_kc <<'SQL' > "$WORK_DIR/kc_user_ids.csv" || die "Failed to export Keycloak user ids."
COPY (
    SELECT DISTINCT ua.value AS folio_user_id
    FROM user_attribute ua
    JOIN user_entity ue ON ue.id = ua.user_id
    WHERE ua.name = 'user_id'
      AND ue.realm_id = (SELECT id FROM realm WHERE name = :'tenant')
) TO STDOUT WITH (FORMAT csv, HEADER true);
SQL

# ---------- Step 2: Stage the export in FOLIO, build maps, classify ----------

log "[2] Staging Keycloak export in FOLIO and classifying..."

run_folio <<'SQL' || die "Failed to create staging tables."
DROP TABLE IF EXISTS :"schema".kc_roles_staging;
DROP TABLE IF EXISTS :"schema".kc_policies_staging;
DROP TABLE IF EXISTS :"schema".policy_key_staging;
DROP TABLE IF EXISTS :"schema".role_id_map_staging;
DROP TABLE IF EXISTS :"schema".kc_user_ids_staging;
CREATE TABLE :"schema".kc_roles_staging    (id uuid, name text);
CREATE TABLE :"schema".kc_policies_staging (id uuid, name text, class text, refs int, key text, status text);
CREATE TABLE :"schema".policy_key_staging  (id uuid, name text, class text, refs int, key text, status text);
CREATE TABLE :"schema".role_id_map_staging (old_id uuid, new_id uuid, name text);
CREATE TABLE :"schema".kc_user_ids_staging (folio_user_id uuid);
SQL

run_folio <<SQL || die "Failed to load staging tables."
\\copy ${SCHEMA}.kc_roles_staging (id, name) FROM '$WORK_DIR/kc_roles.csv' WITH (FORMAT csv, HEADER true)
\\copy ${SCHEMA}.kc_policies_staging (id, name, class, refs, key) FROM '$WORK_DIR/kc_policies.csv' WITH (FORMAT csv, HEADER true)
\\copy ${SCHEMA}.kc_user_ids_staging (folio_user_id) FROM '$WORK_DIR/kc_user_ids.csv' WITH (FORMAT csv, HEADER true)
SQL

# FOLIO-side key staging, same shape and same name-shape classifier as the KC export.
run_folio <<'SQL' || die "Failed to build FOLIO key staging."
INSERT INTO :"schema".policy_key_staging (id, name, class, refs, key)
WITH pol AS (
  SELECT p.id, p.name, p.type::text AS type
  FROM :"schema".policy p
  WHERE p.type IN ('ROLE','USER','TIME')
),
role_ref AS (
  SELECT pr.policy_id AS id, count(*) AS refs, min(r.name) AS ent
  FROM :"schema".policy_roles pr
  LEFT JOIN :"schema".role r ON r.id = pr.role_id
  GROUP BY pr.policy_id
),
user_ref AS (
  SELECT pu.policy_id AS id, count(*) AS refs, min(pu.user_id::text) AS ent
  FROM :"schema".policy_users pu
  GROUP BY pu.policy_id
)
SELECT p.id, p.name, p.type,
       COALESCE(rr.refs, ur.refs, 0),
       CASE
         WHEN p.name LIKE 'Policy for role: %' THEN 'role:' || COALESCE(rr.ent, '')
         WHEN p.name LIKE 'Policy for user: %' THEN 'user:' || COALESCE(ur.ent, '')
         ELSE 'name:' || p.name
       END
FROM pol p
LEFT JOIN role_ref rr ON rr.id = p.id
LEFT JOIN user_ref ur ON ur.id = p.id;
SQL

# Role id map: same-named roles whose ids differ. Role NAME is the stable key.
run_folio <<'SQL' || die "Failed to build the role id map."
INSERT INTO :"schema".role_id_map_staging (old_id, new_id, name)
SELECT r.id, k.id, r.name
FROM :"schema".role r
JOIN :"schema".kc_roles_staging k ON k.name = r.name
WHERE r.id IS DISTINCT FROM k.id;
SQL

# Status, computed once on both staging tables (read everywhere downstream):
#   multi       refs > 1                       (key is not 1:1 — cannot repair safely)
#   unresolved  key is 'role:' / 'user:' bare  (the referenced entity contributed no name)
#   candidate → matched | folio_only | kc_only  by cross-side key
# The unresolved test is on the KEY, not on a count, because an empty key is exactly what makes a
# policy unmatchable — and a bare 'role:' would otherwise collide with every other bare 'role:'.
# It covers a policy referencing nothing at all as well as one whose reference this script cannot
# follow: a KC role policy over a CLIENT role resolves to no name here, because the join is
# restricted to realm roles. Name-shaped keys ('name:<policy name>') legitimately carry refs = 0.
# Known asymmetry: refs counts the entity reference only for 'Policy for role|user:'-shaped names;
# a custom-named admin policy over several roles is 'multi' on the FOLIO side (which counts
# policy_roles regardless of name) but keyed by name → 'kc_only' on the KC side. Both are skipped and
# reported, so it is safe — just not symmetric.
run_folio <<'SQL' || die "Failed to classify staged policies."
UPDATE :"schema".kc_policies_staging SET status =
  CASE WHEN refs > 1 THEN 'multi' WHEN key IN ('role:','user:') THEN 'unresolved' ELSE 'candidate' END;
UPDATE :"schema".policy_key_staging SET status =
  CASE WHEN refs > 1 THEN 'multi' WHEN key IN ('role:','user:') THEN 'unresolved' ELSE 'candidate' END;

UPDATE :"schema".policy_key_staging f SET status = 'matched'
WHERE f.status = 'candidate'
  AND f.key IN (SELECT key FROM :"schema".kc_policies_staging WHERE status = 'candidate');
UPDATE :"schema".kc_policies_staging k SET status = 'matched'
WHERE k.status = 'candidate'
  AND k.key IN (SELECT key FROM :"schema".policy_key_staging WHERE status = 'matched');
UPDATE :"schema".policy_key_staging SET status = 'folio_only' WHERE status = 'candidate';
UPDATE :"schema".kc_policies_staging SET status = 'kc_only'   WHERE status = 'candidate';
SQL

# ---------- Step 3: Pre-flight checks ----------

log "[3] Pre-flight checks..."

# Hard-coded reinsert column lists MUST match the live schema: an incomplete list would silently
# NULL/reset columns on reinsert (DEFAULT columns do not error). Abort on drift.
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

# Duplicate role names would make the role map non-deterministic.
dup_roles=$(echo 'SELECT string_agg(name, chr(44) ORDER BY name) FROM (SELECT name FROM :"schema".kc_roles_staging GROUP BY name HAVING count(*) > 1) d;' | q_folio)
[[ -z "$dup_roles" ]] || die "Duplicate realm role names in Keycloak (cannot map by name): $dup_roles"

# ABORT 1: duplicate effective key among match-eligible policies (either side). A duplicate key
# fans out the id UPDATE non-deterministically. Report the keys and stop.
dup_keys=$(q_folio <<'SQL'
SELECT string_agg(src || ':' || key, chr(44) ORDER BY key) FROM (
  SELECT 'FOLIO' AS src, key FROM :"schema".policy_key_staging  WHERE status = 'matched' GROUP BY key HAVING count(*) > 1
  UNION ALL
  SELECT 'KC',    key FROM :"schema".kc_policies_staging WHERE status = 'matched' GROUP BY key HAVING count(*) > 1
) d;
SQL
)
[[ -z "$dup_keys" ]] || die "Duplicate effective policy key(s) — cannot map deterministically: $dup_keys"

# ABORT 2: user link broken (out-of-scope "users recreated" migration). If NONE of FOLIO's
# user_role.user_id values is known to Keycloak as a user_id attribute, folio user ids were
# regenerated and this script has no map source for them — abort. A partial overlap is repaired
# where possible; the stale rows are enumerated in the report (see below), never silently passed.
IFS='|' read -r ur_total ur_matched < <(q_folio <<'SQL'
SELECT count(DISTINCT ur.user_id),
       count(DISTINCT ur.user_id) FILTER (WHERE k.folio_user_id IS NOT NULL)
FROM :"schema".user_role ur
LEFT JOIN :"schema".kc_user_ids_staging k ON k.folio_user_id = ur.user_id;
SQL
)
ur_total="${ur_total:-0}"; ur_matched="${ur_matched:-0}"
# Zero overlap is only evidence of regenerated user ids when there are enough rows for it to mean
# something: on a nearly empty tenant the one or two users present may simply not be provisioned in
# Keycloak yet (created in FOLIO, not yet synced), and aborting the whole repair over that would be
# wrong. Below the sample size the mismatched rows still surface in the skipped report.
USER_LINK_MIN_SAMPLE=3
if [[ "$ur_total" -ge "$USER_LINK_MIN_SAMPLE" && "$ur_matched" == "0" ]]; then
    die "User link broken: none of $ur_total FOLIO user_role.user_id values is known to Keycloak (user_id attribute). Folio user ids were regenerated — this migration ('users recreated') is out of scope; repair user provisioning first."
fi

# ABORT 3: roles present in FOLIO but not Keycloak (existing guard).
folio_only_roles=$(q_folio <<'SQL'
SELECT string_agg(r.name || ' (' || r.id || ')', ', ' ORDER BY r.name)
FROM :"schema".role r LEFT JOIN :"schema".kc_roles_staging k ON k.name = r.name
WHERE k.id IS NULL;
SQL
)
if [[ -n "$folio_only_roles" ]]; then
    if [[ "$FORCE" == "true" ]]; then
        warn "Roles present in FOLIO but not in Keycloak (FORCE => skipped, NOT repaired): $folio_only_roles"
    else
        die "Roles present in FOLIO but not in Keycloak (set FORCE=true to skip them): $folio_only_roles"
    fi
fi

# ---------- Step 4: Work detection ----------

# Three independent classes of work: drifted role ids, drifted policy ids among matched entities, and
# names still embedding an id that resolves to nothing. Any one of them alone is a real repair — a
# migration can regenerate folio user ids without moving a single policy id, which leaves nothing but
# stale name strings.
role_diff=$(echo 'SELECT count(*) FROM :"schema".role_id_map_staging;' | q_folio)
policy_diff=$(q_folio <<'SQL'
SELECT count(*) FROM :"schema".policy_key_staging f
JOIN :"schema".kc_policies_staging k ON k.key = f.key AND k.status = 'matched'
WHERE f.status = 'matched' AND f.id IS DISTINCT FROM k.id;
SQL
)
kc_stale=$(kc_unresolved_count)
log "    role id mismatches: $role_diff, policy id mismatches: $policy_diff, stale KC names: $kc_stale"

# Everything this run cannot synchronise, reported once, before either database is written — so it
# is on the operator's screen whichever way the run ends. It reads only the staging tables, which
# neither write touches, so the content is the same wherever it is called.
report_skipped

if [[ "$role_diff" == "0" && "$policy_diff" == "0" && "$kc_stale" == "0" ]]; then
    log "Nothing to repair: FOLIO ids already match Keycloak and no name embeds a dead id."
    cleanup_staging
    exit 0
fi

# ---------- Step 5: Write the map CSVs (transport into the Keycloak connection) ----------

echo 'COPY (SELECT old_id, new_id, name FROM :"schema".role_id_map_staging ORDER BY name) TO STDOUT WITH (FORMAT csv, HEADER true);' \
    | q_folio > "$ROLE_MAP_CSV" || die "Failed to write role id map."

# User map for the Keycloak rewrite: for each matched user policy, the folio user id embedded in the
# KC name (stale) → FOLIO's policy_users.user_id (current). Empty when KC names are already current.
q_folio <<'SQL' > "$USER_MAP_CSV" || die "Failed to write user id map."
COPY (
  SELECT DISTINCT substring(k.name FROM 'Policy for user: ([0-9a-fA-F-]{36})') AS old_id,
         pu.user_id AS new_id
  FROM :"schema".kc_policies_staging k
  JOIN :"schema".policy_key_staging f ON f.key = k.key AND f.status = 'matched'
  JOIN :"schema".policy_users pu ON pu.policy_id = f.id
  WHERE k.status = 'matched' AND k.key LIKE 'user:%'
    AND substring(k.name FROM 'Policy for user: ([0-9a-fA-F-]{36})') IS DISTINCT FROM pu.user_id::text
) TO STDOUT WITH (FORMAT csv, HEADER true);
SQL
log "[5] Maps written to $WORK_DIR (role_id_map.csv, user_id_map.csv)"

# ---------- Step 6: Keycloak rewrite — the FIRST write. See the WRITE ORDER note at the top. ----------

if [[ "$DRY_RUN" == "true" ]]; then
    log "[6] DRY_RUN: skipping the Keycloak rewrite (nothing is written to Keycloak)."
else
    kc_rewrite
fi

# ---------- Step 7: FOLIO transaction (id fix + name rewrite) — the SECOND write ----------

tx_end="COMMIT"
[[ "$DRY_RUN" == "true" ]] && tx_end="ROLLBACK"
log "[7] FOLIO transaction (end=$tx_end)..."

run_folio -v tx_end="$tx_end" <<'SQL' || die "FOLIO transaction failed (rolled back)."
\set ON_ERROR_STOP on
BEGIN;
SET search_path TO :"schema";

-- Block concurrent writers (mod-roles-keycloak) for the whole repair; readers pass.
LOCK TABLE role, policy, user_role, role_capability, role_capability_set,
           role_loadable, role_loadable_permission, policy_roles, policy_users
IN EXCLUSIVE MODE;

-- Maps built while names still embed the OLD ids. policy_map: matched policies whose ids differ.
CREATE TEMP TABLE role_map AS
  SELECT old_id, new_id, name FROM role_id_map_staging;
CREATE TEMP TABLE policy_map AS
  SELECT f.id AS old_id, k.id AS new_id
  FROM policy_key_staging f
  JOIN kc_policies_staging k ON k.key = f.key AND k.status = 'matched'
  WHERE f.status = 'matched' AND f.id IS DISTINCT FROM k.id;
-- FOLIO-side user map: folio user id embedded in a matched user policy's FOLIO name (if stale)
-- → policy_users.user_id. Empty in the carry-over case (FOLIO names are already current); present
-- only if a FOLIO user-policy name disagrees with its policy_users row.
CREATE TEMP TABLE user_map AS
  SELECT DISTINCT substring(f.name FROM 'Policy for user: ([0-9a-fA-F-]{36})') AS old_id,
         pu.user_id::text AS new_id
  FROM policy_key_staging f
  JOIN policy_users pu ON pu.policy_id = f.id
  WHERE f.status = 'matched' AND f.key LIKE 'user:%'
    AND substring(f.name FROM 'Policy for user: ([0-9a-fA-F-]{36})') IS DISTINCT FROM pu.user_id::text;

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

-- If a future migration adds a table with an FK to role(id)/policy(id) not handled above, these
-- UPDATEs fail on that FK and everything rolls back — never silent.
UPDATE role   r SET id = m.new_id FROM role_map   m WHERE r.id = m.old_id;
UPDATE policy p SET id = m.new_id FROM policy_map m WHERE p.id = m.old_id;

-- Names/descriptions embedding an OLD role id (role policies + descriptions).
UPDATE policy p
SET name        = replace(p.name,        m.old_id::text, m.new_id::text),
    description = replace(coalesce(p.description, ''), m.old_id::text, m.new_id::text)
FROM role_map m
WHERE p.name LIKE '%' || m.old_id::text || '%'
   OR coalesce(p.description,'') LIKE '%' || m.old_id::text || '%';
-- Names/descriptions embedding an OLD folio user id (matched user policies only; no-op when the
-- FOLIO name already holds policy_users.user_id, which is the carry-over case).
UPDATE policy p
SET name        = replace(p.name,        m.old_id, m.new_id),
    description = replace(coalesce(p.description, ''), m.old_id, m.new_id)
FROM user_map m
WHERE p.name LIKE '%' || m.old_id || '%'
   OR coalesce(p.description,'') LIKE '%' || m.old_id || '%';

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
\echo '--- per-class policy summary (class, status, count) ---'
SELECT class, status, count(*) FROM policy_key_staging GROUP BY 1,2 ORDER BY 1,2;
\echo '--- policies whose id was remapped ---'
SELECT count(*) AS policies_remapped FROM policy_map;

:tx_end;
SQL

# ---------- Step 8: Cleanup + final status ----------

if [[ "$DRY_RUN" == "true" ]]; then
    cleanup_staging
    log "Dry-run complete: Keycloak untouched, FOLIO transaction rolled back. Maps preview in $WORK_DIR."
    exit 0
fi

cleanup_staging
log "Intermediate CSVs left in $WORK_DIR for diagnosis — safe to delete."
warn "Keycloak caches authorization data in memory: rolling-restart all Keycloak nodes OR call"
warn "POST /admin/realms/$TENANT/clear-realm-cache before actively managing the repaired roles."
if [[ "$KC_LEFTOVER" != "0" ]]; then
    warn "INCOMPLETE: $KC_LEFTOVER Keycloak name(s)/description(s) still embed an id that resolves to no live role or user (a target absent from the maps — e.g. a user with permissions but no policy). A folio user id can be rebuilt from FOLIO on a re-run; a role id cannot, because its old→new mapping existed only while the two sides disagreed. Investigate before clearing caches."
    exit 3
fi
log "Repair complete for tenant $TENANT. Re-run to verify: it must report 'Nothing to repair'."
