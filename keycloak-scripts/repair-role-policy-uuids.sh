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
# sides (policies AND permissions).
#
# FAILURE POLICY — BEST EFFORT. The two databases are snapshots of the same tenant taken at
# different moments, and no run can assume they agree everywhere. So: repair every entity that maps
# 1:1, skip every entity that does not, and report the skipped ones. An anomaly in the DATA does not
# abort the run — aborting would block the entities that ARE repairable, which on a live migration is
# the worse outcome.
# Consequently this script NEVER deletes a role, policy or permission. (It does DELETE and reinsert
# child rows inside its own transaction, because the FKs are neither ON UPDATE CASCADE nor
# deferrable — that is a rewrite, not a removal.) Removing a leftover is a separate, deliberate
# operation for an operator who has confirmed what depends on it.
#
# The skip classes, all reported: 'multi' / 'unresolved' (key is not usable), 'folio_only' /
# 'kc_only' (no counterpart), 'ambiguous' (several policies share one key — see below), duplicate
# Keycloak role names, roles present in FOLIO but absent from Keycloak, FOLIO policy types outside
# ROLE/USER/TIME (a type a later mod-roles-keycloak may add, which this script cannot key), a stale
# FOLIO-to-Keycloak user link, and map rows dropped because rewriting them would collide on a
# Keycloak policy name.
#
# EXIT CODES. 0 = ran to completion (skips may have been reported — read them). 3 = ran, wrote, but a
# Keycloak name still embeds an id that no live entity and no reported skip accounts for, or the
# leftover count could not be read; the databases are written, the run is simply not certified clean.
# 1 = aborted. The abort cases are: cannot work at all (missing env var, realm, schema, or a query
# the run depends on failing), or a write failed. Two data-driven aborts also survive inside the
# transactions, both deliberate because continuing would corrupt: the policy_config remap failing to
# converge (a chained or swapped map) and the closing assertion that every uniquely-named role now
# carries Keycloak's id. Both roll their transaction back.
#
# ABORT DOES NOT ALWAYS MEAN "NOTHING HAPPENED". Each write is a single transaction, but there are
# TWO of them in two databases. An abort during or before the Keycloak rewrite leaves both untouched;
# an abort in the FOLIO transaction rolls FOLIO back while the Keycloak rewrite has already committed,
# leaving the sides half-aligned. That state is designed for — re-running finishes the job — but do
# not read exit 1 as "no change".
#
# AMBIGUOUS KEYS are the normal residue of an environment running mod-users-keycloak 3.0.x, where a
# module system user receives its capabilities by DIRECT user-capability assignment: every change of
# that user's folio id orphans its 'Policy for user: <old id>' and the next assignment creates a new
# one, so Keycloak ends up holding several policies that all resolve to the same live user. Nothing
# here can choose between them, so both sides step aside and are reported. This is not a dead end:
# remove the surplus policy on whichever side actually holds more than one — the report prints the
# per-key counts for both sides — and re-run; the key becomes 1:1 and the pair repairs itself. Note
# that a key duplicated on the FOLIO side is demoted on the Keycloak side too, so "delete it in
# Keycloak" is NOT universal advice. (The class disappears for good on mod-users-keycloak 4.x, where
# system users go through a default role instead of direct user-capability assignment.)
#
# WRITE ORDER — DO NOT SWAP. Keycloak is rewritten first, the FOLIO transaction commits second.
# The two databases share no transaction, so a run can die between them; this order is what makes a
# plain re-run sufficient. Both id maps are derived from FOLIO's ids still differing from Keycloak's,
# the Keycloak step never changes a Keycloak PRIMARY KEY — it rewrites name/description strings and
# the role id references inside policy_config, both of which are derived from the maps. So after a crash
# in between, the next run re-derives exactly the same maps and finishes. Commit FOLIO first instead
# and the difference the maps are built from is gone, which is why that ordering needs a persisted
# map and a resume mode. It had one; it was removed on purpose.
#
# Required: KC_DB_URL, FOLIO_DB_URL (postgresql://...), TENANT (realm name, e.g. "diku")
# Optional: DRY_RUN — exactly the string "true" (anything else, including "1"/"yes", is a REAL run):
#                     skip the Keycloak rewrite, run the FOLIO transaction and ROLLBACK, print the
#                     report. No tenant data is written to either database; the run still creates and
#                     drops its own staging tables in the FOLIO schema, and reads Keycloak.
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
WORK_DIR="${WORK_DIR:-/tmp/repair-role-policy-uuids-$TENANT}"
SCHEMA="${TENANT}_mod_roles_keycloak"
# The maps are computed in FOLIO but applied in Keycloak; these CSVs are the transport between the
# two connections, nothing more. They are not a recovery mechanism — a failed run is re-run.
ROLE_MAP_CSV="$WORK_DIR/role_id_map.csv"     # old_id,new_id,name  (role UUIDs, FOLIO→KC)
USER_MAP_CSV="$WORK_DIR/user_id_map.csv"     # old_id,new_id       (folio user ids in KC names)
KC_LEFTOVER=0                                # set by refresh_kc_leftover; read by the final status
ur_total=0; ur_matched=0                     # set by the pre-flight; read by report_skipped
SKIPPED_ROLE_NAMES=""                        # set by the pre-flight; read by report_skipped
FOLIO_ONLY_ROLES=""                          # set by the pre-flight; read by report_skipped
mkdir -p "$WORK_DIR"

# psql wrappers. NOTE: psql does NOT interpolate :variables in `-c` strings, and \copy interpolates
# nothing — statements using :'tenant'/:"schema" must go via stdin, and \copy lines must have the
# schema/path expanded by bash.
# Keycloak has no per-tenant schema to hide in and these tables must outlive a single psql session
# (written by \copy, read by the rewrite), so they cannot be TEMP. Qualify them by tenant instead:
# two repairs running against the same Keycloak cluster for different tenants would otherwise share
# one table name, and either one's DROP would destroy the other's map mid-run.
KC_TBL_SUFFIX=$(printf '%s' "$TENANT" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '_')
KC_ROLE_MAP_TBL="role_uuid_map_staging_$KC_TBL_SUFFIX"
KC_USER_MAP_TBL="user_uuid_map_staging_$KC_TBL_SUFFIX"

run_folio() { psql "$FOLIO_DB_URL" -v ON_ERROR_STOP=1 -v schema="$SCHEMA" -v tenant="$TENANT" "$@"; }
run_kc()    { psql "$KC_DB_URL"    -v ON_ERROR_STOP=1 -v tenant="$TENANT" \
                       -v rolemap="$KC_ROLE_MAP_TBL" -v usermap="$KC_USER_MAP_TBL" "$@"; }
q_folio()   { run_folio -qtA "$@"; }
q_kc()      { run_kc -qtA "$@"; }

# The leftover count runs AFTER the Keycloak rewrite has committed, so a failure here must not abort:
# the write already happened and the FOLIO transaction still has to run. Degrade to an unknown count
# and say so, rather than dying between the two writes with no output.
refresh_kc_leftover() {
    local n
    if n=$(kc_unresolved_count); then
        KC_LEFTOVER="${n:-0}"
    else
        KC_LEFTOVER="?"
        warn "Could not count leftover Keycloak names — the query failed. Writes already made stand; re-run for a clean verdict."
    fi
}

# Ids embedded in the NAME of a Keycloak policy this run deliberately skipped. Such an id is stale by
# design and will stay stale — the script does not rewrite a policy it could not match, and never
# deletes one. Counting it as leftover would make a tenant whose steady state includes a skip class
# permanently "INCOMPLETE": the run could never reach exit 0 and 'Nothing to repair' would be
# unreachable advice. So these ids are EXPLAINED and excluded from the leftover count; what remains
# is a stale id attributable to no reported skip, which is the thing actually worth investigating.
# The list is computed in FOLIO and inlined into the Keycloak query as SQL literals, NOT staged in a
# table: the leftover count runs on the read-only DRY_RUN path too, and creating a table there would
# both break "nothing is written" and make a read-only Keycloak endpoint unusable for a preview.
# Inlining is safe because every value comes from a [0-9a-fA-F-]{36} capture and cannot carry a quote;
# it travels on stdin, so there is no argument-length limit either.
EXPLAINED_IDS=""    # set by collect_explained_ids; read by kc_unresolved_count
collect_explained_ids() {
    EXPLAINED_IDS=$(q_folio <<'SQL'
SELECT string_agg(DISTINCT quote_literal(uid), ',')
FROM (
  SELECT substring(name FROM 'for (?:role|user):? ''?([0-9a-fA-F-]{36})') AS uid
  FROM :"schema".kc_policies_staging
  WHERE status IN ('ambiguous','kc_only','multi','unresolved')
) d
WHERE uid IS NOT NULL;
SQL
) || die "Failed to collect the ids explained by a reported skip."
}

# Count Keycloak names of the form 'Policy/…​ for role|user: <id>' whose embedded id resolves to
# neither a live realm role nor a live folio user (user_id attribute) AND is not explained by a
# reported skip. Read-only. Used for work detection before the run (names left pointing at entities
# the migration replaced) and as the leftover check after the rewrite (a stale id no map covered —
# e.g. a user with permissions but no policy). Requires collect_explained_ids to have run.
kc_unresolved_count() {
    local explained="TRUE"
    [[ -z "$EXPLAINED_IDS" ]] || explained="uid NOT IN ($EXPLAINED_IDS)"
    q_kc <<SQL
WITH scanned AS (
  -- Descriptions carry the id too ("System generated policy for role: <id>") and are rewritten by
  -- the same UPDATE, so a check that only read names would certify a run clean with a stale
  -- description still in place — and the INCOMPLETE message claims to cover both.
  SELECT rsp.name AS txt FROM resource_server_policy rsp
  JOIN client c ON rsp.resource_server_id = c.id
  WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant') AND rsp.name ~ 'for (role|user):? '
  UNION ALL
  SELECT rsp.description FROM resource_server_policy rsp
  JOIN client c ON rsp.resource_server_id = c.id
  WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant')
    AND coalesce(rsp.description, '') ~ 'for (role|user):? '
),
ids AS (
  SELECT DISTINCT substring(txt FROM 'for (?:role|user):? ''?([0-9a-fA-F-]{36})') AS uid FROM scanned
)
SELECT count(*) FROM ids
WHERE uid IS NOT NULL
  AND $explained
  AND uid NOT IN (SELECT id::text FROM keycloak_role
                  WHERE realm_id = (SELECT id FROM realm WHERE name = :'tenant') AND client_role = false)
  -- ua.value is nullable (upstream declares no NOT NULL, and 24.0.0 added an explicit NULL path):
  -- a single NULL in a NOT IN subquery makes the whole predicate NULL for every row, so the count
  -- would silently come back 0 and certify a dirty realm as clean.
  AND uid NOT IN (SELECT ua.value FROM user_attribute ua JOIN user_entity ue ON ue.id = ua.user_id
                  WHERE ua.name = 'user_id' AND ua.value IS NOT NULL
                    AND ue.realm_id = (SELECT id FROM realm WHERE name = :'tenant'));
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
    run_kc -c "DROP TABLE IF EXISTS $KC_ROLE_MAP_TBL; DROP TABLE IF EXISTS $KC_USER_MAP_TBL;" >/dev/null 2>&1 || true
}

# Everything this run could NOT synchronise, split by what the operator has to DO about it — a flat
# list reads as one undifferentiated pile, and these classes call for opposite actions. Called before
# every exit that follows classification, including the "nothing to repair" ones, where silence would
# otherwise read as "all clear". Reads the staging tables, so it must run before cleanup_staging;
# reads ur_total/ur_matched, SKIPPED_ROLE_NAMES and FOLIO_ONLY_ROLES from the pre-flight, so it must
# run after step 3.
report_class() {   # $1 = staging table, $2 = status list (SQL literals), $3 = side label
    q_folio -v tbl="$1" -v side="$3" <<SQL || die "Failed to collect the report for status $2."
SELECT string_agg(rpad(:'side', 6) || class || ' "' || name || '"' ||
                  CASE WHEN status = 'ambiguous' THEN '  key=' || key ELSE '' END, chr(10) ORDER BY key, name)
FROM :"schema".:"tbl" WHERE status IN ($2);
SQL
}

report_skipped() {
    local ambiguous_kc ambiguous_folio ambiguous_keys folio_only kc_only unusable_folio unusable_kc stale_users="" unknown_types
    ambiguous_kc=$(report_class    kc_policies_staging "'ambiguous'"          KC)
    ambiguous_folio=$(report_class policy_key_staging  "'ambiguous'"          FOLIO)
    # Per-key counts, because the remedy depends on WHICH side is duplicated: a key duplicated only in
    # FOLIO is not fixed by deleting anything in Keycloak. Telling an operator otherwise mid-incident
    # is worse than telling them nothing.
    ambiguous_keys=$(q_folio <<'SQL'
SELECT string_agg('   ' || key || '  ->  keycloak=' || kc_n || '  folio=' || f_n, chr(10) ORDER BY key)
FROM (
  SELECT k.key,
         (SELECT count(*) FROM :"schema".kc_policies_staging x WHERE x.key = k.key AND x.status = 'ambiguous') AS kc_n,
         (SELECT count(*) FROM :"schema".policy_key_staging  y WHERE y.key = k.key AND y.status = 'ambiguous') AS f_n
  FROM (SELECT DISTINCT key FROM :"schema".kc_policies_staging WHERE status = 'ambiguous') k
) d;
SQL
) || die "Failed to summarise ambiguous keys."
    folio_only=$(report_class      policy_key_staging  "'folio_only'"         FOLIO)
    kc_only=$(report_class         kc_policies_staging "'kc_only'"            KC)
    unusable_folio=$(report_class  policy_key_staging  "'multi','unresolved'" FOLIO)
    unusable_kc=$(report_class     kc_policies_staging "'multi','unresolved'" KC)

    # A policy type this script does not know is worse than an unmatched one: it never enters the
    # staging tables at all, so without this it would be neither repaired nor reported — silently
    # invisible, which is exactly what the failure policy above forbids. A later mod-roles-keycloak
    # may add a type; this line is how the operator finds out instead of guessing.
    unknown_types=$(q_folio <<'SQL'
SELECT string_agg(t, ', ' ORDER BY t) FROM (
  SELECT DISTINCT type::text || ' (' || count(*) OVER (PARTITION BY type) || ')' AS t
  FROM :"schema".policy WHERE type::text NOT IN ('ROLE','USER','TIME')) d;
SQL
) || die "Failed to check for unknown FOLIO policy types."

    if [[ "$ur_matched" != "$ur_total" ]]; then
        stale_users=$(q_folio <<'SQL'
SELECT string_agg(DISTINCT ur.user_id::text, chr(10))
FROM :"schema".user_role ur
LEFT JOIN :"schema".kc_user_ids_staging k ON k.folio_user_id = ur.user_id
WHERE k.folio_user_id IS NULL;
SQL
) || die "Failed to collect the stale user-link report."
    fi

    if [[ -z "$ambiguous_kc$ambiguous_folio$ambiguous_keys$folio_only$kc_only$unusable_folio$unusable_kc$stale_users$SKIPPED_ROLE_NAMES$FOLIO_ONLY_ROLES$unknown_types" ]]; then
        log "Could not synchronise: nothing — every role and policy on both sides found its counterpart."
        return 0
    fi

    warn "======== NOT REPAIRED (skipped by design, nothing was deleted) ========"

    if [[ -n "$ambiguous_kc$ambiguous_folio" ]]; then
        warn "-- AMBIGUOUS: several policies resolve to one entity, so no id can be assigned"
        warn "   deterministically. ACTION: on whichever side shows a count above 1 below, remove the"
        warn "   surplus policy (in Keycloak: the policy and its permissions), then re-run — once the"
        warn "   key is 1:1 the pair repairs itself. A count above 1 on the FOLIO side is NOT fixed by"
        warn "   deleting anything in Keycloak."
        [[ -n "$ambiguous_keys" ]] && printf '%s\n' "$ambiguous_keys" >&2
        [[ -n "$ambiguous_kc"    ]] && printf '%s\n' "$ambiguous_kc" >&2
        [[ -n "$ambiguous_folio" ]] && printf '%s\n' "$ambiguous_folio" >&2
    fi
    if [[ -n "$folio_only" ]]; then
        warn "-- FOLIO POLICY WITH NO KEYCLOAK COUNTERPART: mod-roles-keycloak addresses Keycloak by the"
        warn "   FOLIO policy id, so the next update of these will hit a missing object. This is a live"
        warn "   breakage, not residue — it usually means the realm snapshot predates the FOLIO schema."
        printf '%s\n' "$folio_only" >&2
    fi
    if [[ -n "$kc_only" ]]; then
        warn "-- KEYCLOAK-ONLY: no FOLIO counterpart. Harmless where it is (Keycloak still enforces it),"
        warn "   but unmanaged: mod-roles-keycloak will never find or revoke it. Clean up deliberately."
        printf '%s\n' "$kc_only" >&2
    fi
    if [[ -n "$unusable_folio$unusable_kc" ]]; then
        warn "-- UNUSABLE KEY: policy references several entities ('multi') or none this script can"
        warn "   resolve ('unresolved', e.g. a policy over a CLIENT role). Not repairable by id matching."
        [[ -n "$unusable_folio" ]] && printf '%s\n' "$unusable_folio" >&2
        [[ -n "$unusable_kc"    ]] && printf '%s\n' "$unusable_kc" >&2
    fi
    if [[ -n "$SKIPPED_ROLE_NAMES" ]]; then
        warn "-- DUPLICATE KEYCLOAK ROLE NAMES: role name is this script's only stable key, so these"
        warn "   roles and everything hanging off them were left untouched: $SKIPPED_ROLE_NAMES"
    fi
    if [[ -n "$FOLIO_ONLY_ROLES" ]]; then
        warn "-- ROLES IN FOLIO BUT NOT IN KEYCLOAK: no id to adopt, left as they are: $FOLIO_ONLY_ROLES"
    fi
    if [[ -n "$unknown_types" ]]; then
        warn "-- UNKNOWN FOLIO POLICY TYPE(S): outside ROLE/USER/TIME, so this script never even looked"
        warn "   at them. A newer mod-roles-keycloak may have added a type — the script needs teaching"
        warn "   before it can repair these: $unknown_types"
    fi
    if [[ -n "$stale_users" ]]; then
        warn "-- FOLIO user_role.user_id NOT KNOWN TO KEYCLOAK (stale user link):"
        printf '%s\n' "$stale_users" >&2
    fi
    warn "(Anything created after the Keycloak export also lands here; re-run to confirm it is genuine.)"
    warn "======================================================================"
}

# ==========================================================================================
# Keycloak string rewrite (step 6, the FIRST of the two writes). Rewrites resource_server_policy
# name + description and policy_config['roles'] from the two map CSVs. Idempotent: it substitutes
# old ids that are no longer present after a first pass, so a repeat is a no-op.
# ==========================================================================================
kc_rewrite() {
    log "[6] Keycloak name/description rewrite..."

    run_kc <<'SQL' || die "Failed to create Keycloak staging tables."
DROP TABLE IF EXISTS :"rolemap";
DROP TABLE IF EXISTS :"usermap";
CREATE TABLE :"rolemap" (old_id uuid, new_id uuid, name text);
CREATE TABLE :"usermap" (old_id uuid, new_id uuid);
SQL
    run_kc -c "\copy $KC_ROLE_MAP_TBL (old_id, new_id, name) FROM '$ROLE_MAP_CSV' WITH (FORMAT csv, HEADER true);" \
        || die "Failed to load the role id map into Keycloak."
    run_kc -c "\copy $KC_USER_MAP_TBL (old_id, new_id) FROM '$USER_MAP_CSV' WITH (FORMAT csv, HEADER true);" \
        || die "Failed to load the user id map into Keycloak."

    # Empty maps mean nothing embeds a stale id in Keycloak (only FOLIO ids had drifted, or the names
    # were already current) — a legitimate no-op, not an error.
    local map_rows
    map_rows=$(q_kc -c "SELECT (SELECT count(*) FROM $KC_ROLE_MAP_TBL) + (SELECT count(*) FROM $KC_USER_MAP_TBL);") \
        || die "Failed to count the staged Keycloak id maps."
    if [[ "${map_rows:-0}" == "0" ]]; then
        log "No Keycloak-side rewrite needed (maps are empty)."
        refresh_kc_leftover
        return 0
    fi

    # A map row whose rewrite would land two policies on the same (resource_server_id, name) cannot
    # be applied — UNIQUE would fire mid-rewrite. Drop those rows from the map instead of aborting:
    # every other rewrite in the same run is unaffected and correct. A pre-existing duplicate name is
    # impossible (the constraint already forbids it), so every collision group contains at least one
    # rewritten row, and removing the ids it maps from is always enough to resolve it.
    # Note the asymmetry this leaves behind: the FOLIO side still adopts Keycloak's id for such an
    # entity, so its Keycloak NAME keeps the old id embedded. That residue is counted by
    # kc_unresolved_count and reported as INCOMPLETE at the end — visible, not silent.
    local excluded
    excluded=$(q_kc <<'SQL'
WITH m AS (
  SELECT old_id::text AS old_id, new_id::text AS new_id FROM :"rolemap"
  UNION ALL
  SELECT old_id::text, new_id::text FROM :"usermap"),
rewritten AS (
  -- One LATERAL, ordered: two independent LIMIT 1 subqueries could take `hit` from one map row and
  -- `nm` from another for a name matching several, and then exclude an innocent id.
  SELECT rsp.resource_server_id AS rs, h.old_id AS hit,
         COALESCE(replace(rsp.name, h.old_id, h.new_id), rsp.name) AS nm
  FROM resource_server_policy rsp
  JOIN client c ON rsp.resource_server_id = c.id
  LEFT JOIN LATERAL (SELECT m.old_id, m.new_id FROM m
                     WHERE strpos(rsp.name, m.old_id) > 0 ORDER BY m.old_id LIMIT 1) h ON true
  WHERE c.realm_id = (SELECT id FROM realm WHERE name = :'tenant')),
collided AS (SELECT rs, nm FROM rewritten GROUP BY rs, nm HAVING count(*) > 1)
SELECT string_agg(DISTINCT r.hit, chr(44))
FROM rewritten r JOIN collided c ON c.rs = r.rs AND c.nm = r.nm
WHERE r.hit IS NOT NULL;
SQL
) || die "Failed to check the Keycloak rewrite for name collisions."

    if [[ -n "$excluded" ]]; then
        warn "Keycloak rewrite would collide on policy names; dropping these ids from the map and"
        warn "rewriting everything else. Their Keycloak names keep the old id and are reported as"
        warn "INCOMPLETE at the end: $excluded"
        run_kc -v excluded="$excluded" <<'SQL' || die "Failed to drop colliding rows from the Keycloak id maps."
DELETE FROM :"rolemap" WHERE old_id::text = ANY (string_to_array(:'excluded', ','));
DELETE FROM :"usermap" WHERE old_id::text = ANY (string_to_array(:'excluded', ','));
SQL
        map_rows=$(q_kc -c "SELECT (SELECT count(*) FROM $KC_ROLE_MAP_TBL) + (SELECT count(*) FROM $KC_USER_MAP_TBL);") \
            || die "Failed to re-count the staged Keycloak id maps."
        if [[ "${map_rows:-0}" == "0" ]]; then
            log "Nothing left in the maps after excluding collisions — no Keycloak rewrite to do."
            refresh_kc_leftover
            return 0
        fi
    fi

    run_kc <<'SQL' || die "Keycloak rewrite failed; it is a single transaction, so nothing was written. Fix the cause and re-run."
\set ON_ERROR_STOP on
BEGIN;
-- psql interpolates neither :'tenant' nor :"rolemap" inside the dollar-quoted DO body below. The
-- tenant travels as a transaction-local GUC; the tenant-qualified map table is copied into a temp
-- table with a FIXED name, which the DO body can then reference literally.
SELECT set_config('repair.tenant', :'tenant', true);
CREATE TEMP TABLE role_map_local ON COMMIT DROP AS SELECT old_id, new_id FROM :"rolemap";

-- Names + descriptions embedding a role id (policies and 'access for role ...' permissions) and a
-- folio user id (policies and 'access for user ...' permissions). Both maps, one pass each: every
-- target is a resource_server_policy row, so substring substitution covers all of them.
UPDATE resource_server_policy rsp
SET name        = replace(rsp.name,        m.old_id::text, m.new_id::text),
    description = CASE WHEN rsp.description IS NULL THEN NULL
                       ELSE replace(rsp.description, m.old_id::text, m.new_id::text) END
FROM (SELECT old_id, new_id FROM :"rolemap"
      UNION ALL SELECT old_id, new_id FROM :"usermap") m
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
    FROM role_map_local m
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
    refresh_kc_leftover
}

log "tenant=$TENANT schema=$SCHEMA dry_run=$DRY_RUN work_dir=$WORK_DIR"

# ---------- Step 1: Export current roles, policies and user ids from Keycloak ----------

log "[1] Exporting Keycloak realm roles, policies and user ids..."

# Captured, not piped into grep: under `pipefail` a `grep -q` that exits on the first match can
# SIGPIPE psql and turn a present realm into "not found" — an abort stating the opposite of the truth.
realm_present=$(echo "SELECT 1 FROM realm WHERE name = :'tenant';" | q_kc) \
    || die "Failed to query Keycloak for realm '$TENANT'."
[[ "$realm_present" == "1" ]] || die "Realm '$TENANT' not found in Keycloak."
schema_present=$(echo "SELECT 1 FROM information_schema.schemata WHERE schema_name = :'schema';" | q_folio) \
    || die "Failed to query the FOLIO database for schema '$SCHEMA'."
[[ "$schema_present" == "1" ]] || die "Schema '$SCHEMA' not found in FOLIO database."

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
    -- ent is NULL when the referenced user carries MORE THAN ONE distinct 'user_id' value: the
    -- attribute PK is ID, not (NAME, USER_ID) (upstream jpa-changelog-1.4.0.xml:161-162), so that is
    -- legal, and min() would silently key the policy to an arbitrary one of them — producing a
    -- confident 'no counterpart' verdict instead of an honest 'cannot resolve'. NULL ent leaves the
    -- key bare ('user:') and the policy is classified 'unresolved' and reported.
    SELECT p.id, count(DISTINCT e) AS refs,
           CASE WHEN count(DISTINCT ua.value) > 1 THEN NULL ELSE min(ua.value) END AS ent
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
-- count DISTINCT, not rows: neither policy_roles nor policy_users has a primary key or unique
-- constraint (create-policy-schema.xml adds FKs only), so the same (policy, entity) pair can appear
-- twice. count(*) would read that as multi-entity and skip a policy that references exactly one.
role_ref AS (
  SELECT pr.policy_id AS id, count(DISTINCT pr.role_id) AS refs, min(r.name) AS ent
  FROM :"schema".policy_roles pr
  LEFT JOIN :"schema".role r ON r.id = pr.role_id
  GROUP BY pr.policy_id
),
user_ref AS (
  SELECT pu.policy_id AS id, count(DISTINCT pu.user_id) AS refs, min(pu.user_id::text) AS ent
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

# Role id map: same-named roles whose ids differ. Role NAME is the stable key — so a name carried by
# two Keycloak roles has no usable key at all and is left out of the map entirely (it would otherwise
# produce two map rows for one FOLIO role and fan the id UPDATE out). The pre-flight reports them.
run_folio <<'SQL' || die "Failed to build the role id map."
INSERT INTO :"schema".role_id_map_staging (old_id, new_id, name)
SELECT r.id, k.id, r.name
FROM :"schema".role r
JOIN :"schema".kc_roles_staging k ON k.name = r.name
WHERE r.id IS DISTINCT FROM k.id
  AND NOT EXISTS (SELECT 1 FROM :"schema".kc_roles_staging d
                  WHERE d.name IS NOT DISTINCT FROM k.name GROUP BY d.name HAVING count(*) > 1);
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

-- 'ambiguous': the key is not 1:1 — several policies on one side carry it, so the id UPDATE would
-- fan out non-deterministically. Both sides step aside; skipped and reported, never guessed at.
-- Keycloak first: that statement demotes the rows for keys duplicated on EITHER side, which lets the
-- FOLIO statement read the resulting keys back instead of recomputing a set the first UPDATE has
-- just changed. Every matched FOLIO key has at least one matched Keycloak row by construction, so
-- reading them back is complete.
UPDATE :"schema".kc_policies_staging SET status = 'ambiguous'
WHERE status = 'matched' AND key IN (
  SELECT key FROM :"schema".kc_policies_staging WHERE status = 'matched' GROUP BY key HAVING count(*) > 1
  UNION
  SELECT key FROM :"schema".policy_key_staging  WHERE status = 'matched' GROUP BY key HAVING count(*) > 1);
UPDATE :"schema".policy_key_staging SET status = 'ambiguous'
WHERE status = 'matched'
  AND key IN (SELECT key FROM :"schema".kc_policies_staging WHERE status = 'ambiguous');
SQL

# ---------- Step 3: Pre-flight checks ----------

log "[3] Pre-flight checks..."

# The FOLIO transaction copies child rows with SELECT *, so it needs no column inventory and cannot
# be broken by a column being added or renamed elsewhere in the table. What it does need is the
# handful of columns it joins and rewrites on. Only those are checked, and only their ABSENCE is
# fatal — this is a guard against the script silently doing nothing, not a schema-version pin.
missing_cols=$(q_folio <<'SQL'
WITH required(tbl, col) AS (
  VALUES ('role','id'), ('role','name'),
         ('policy','id'), ('policy','name'), ('policy','description'), ('policy','type'),
         ('user_role','role_id'), ('user_role','user_id'),
         ('role_capability','role_id'), ('role_capability_set','role_id'),
         ('role_loadable','id'), ('role_loadable_permission','role_loadable_id'),
         ('policy_roles','policy_id'), ('policy_roles','role_id'),
         ('policy_users','policy_id'), ('policy_users','user_id')
)
SELECT string_agg(r.tbl || '.' || r.col, ', ' ORDER BY r.tbl, r.col)
FROM required r
LEFT JOIN information_schema.columns c
       ON c.table_schema = :'schema' AND c.table_name = r.tbl AND c.column_name = r.col
WHERE c.column_name IS NULL;
SQL
) || die "Failed to inspect the FOLIO schema."
[[ -z "$missing_cols" ]] || die "Schema does not provide the columns this script works on — it is not a
mod_roles_keycloak schema, or the model changed. Missing: $missing_cols"

# Duplicate Keycloak role names: role name is the only stable key for the role map, so these roles
# (and every child row hanging off them) are left untouched. Excluded from the map above, reported
# here, never guessed at.
SKIPPED_ROLE_NAMES=$(echo 'SELECT string_agg(name, chr(44) ORDER BY name) FROM (SELECT name FROM :"schema".kc_roles_staging GROUP BY name HAVING count(*) > 1) d;' | q_folio) \
    || die "Failed to check for duplicate Keycloak role names."

# User link: how much of FOLIO's user_role overlaps what Keycloak knows. Zero overlap means folio
# user ids were regenerated and this script has no map source for them — but that is a statement
# about the user-policy class only, and the role class is repaired regardless, so it warns rather
# than aborts. The rows themselves are enumerated by report_skipped.
# Captured before parsing, not piped through process substitution: `read < <(...)` throws the query's
# exit status away, so a failed query and a real answer would be indistinguishable.
ur_counts=$(q_folio <<'SQL'
SELECT count(DISTINCT ur.user_id),
       count(DISTINCT ur.user_id) FILTER (WHERE k.folio_user_id IS NOT NULL)
FROM :"schema".user_role ur
LEFT JOIN :"schema".kc_user_ids_staging k ON k.folio_user_id = ur.user_id;
SQL
) || die "Failed to measure the FOLIO-to-Keycloak user link."
IFS='|' read -r ur_total ur_matched <<<"$ur_counts"
ur_total="${ur_total:-0}"; ur_matched="${ur_matched:-0}"
# Zero overlap only means something when there are enough rows for it to: on a nearly empty tenant
# the one or two users present may simply not be provisioned in Keycloak yet.
USER_LINK_MIN_SAMPLE=3
if [[ "$ur_total" -ge "$USER_LINK_MIN_SAMPLE" && "$ur_matched" == "0" ]]; then
    warn "User link broken: none of $ur_total FOLIO user_role.user_id values is known to Keycloak (user_id attribute) — folio user ids were regenerated. Nothing in the user-policy class can be mapped this run; roles are repaired anyway."
fi

# Roles present in FOLIO but not in Keycloak: no id to adopt, so they keep the one they have.
FOLIO_ONLY_ROLES=$(q_folio <<'SQL'
SELECT string_agg(r.name || ' (' || r.id || ')', ', ' ORDER BY r.name)
FROM :"schema".role r LEFT JOIN :"schema".kc_roles_staging k ON k.name = r.name
WHERE k.id IS NULL;
SQL
) || die "Failed to check for FOLIO-only roles."

# ---------- Step 4: Work detection ----------

# Three independent classes of work: drifted role ids, drifted policy ids among matched entities, and
# names still embedding an id that resolves to nothing. Any one of them alone is a real repair — a
# migration can regenerate folio user ids without moving a single policy id, which leaves nothing but
# stale name strings.
role_diff=$(echo 'SELECT count(*) FROM :"schema".role_id_map_staging;' | q_folio) \
    || die "Failed to count role id mismatches."
policy_diff=$(q_folio <<'SQL'
SELECT count(*) FROM :"schema".policy_key_staging f
JOIN :"schema".kc_policies_staging k ON k.key = f.key AND k.status = 'matched'
WHERE f.status = 'matched' AND f.id IS DISTINCT FROM k.id;
SQL
) || die "Failed to count policy id mismatches."
collect_explained_ids
kc_stale=$(kc_unresolved_count) || die "Failed to count unexplained stale Keycloak names."
# Fourth drift class, independent of the other three: a matched FOLIO policy whose NAME embeds a folio
# user id that disagrees with its policy_users row. Ids can all be aligned and Keycloak's names
# current while this is still stale — without counting it the run would report "Nothing to repair"
# and skip the very UPDATE that fixes it.
folio_name_diff=$(q_folio <<'SQL'
SELECT count(*) FROM (
  SELECT DISTINCT f.id
  FROM :"schema".policy_key_staging f
  JOIN :"schema".policy_users pu ON pu.policy_id = f.id
  WHERE f.status = 'matched' AND f.key LIKE 'user:%'
    AND substring(f.name FROM 'Policy for user: ([0-9a-fA-F-]{36})') IS DISTINCT FROM pu.user_id::text
) d;
SQL
) || die "Failed to count stale FOLIO policy names."
log "    role id mismatches: $role_diff, policy id mismatches: $policy_diff, stale FOLIO names: $folio_name_diff, unexplained stale KC names: $kc_stale"

# Everything this run cannot synchronise, reported once, before either database is written — so it
# is on the operator's screen whichever way the run ends. It reads only the staging tables, which
# neither write touches, so the content is the same wherever it is called.
report_skipped

if [[ "$role_diff" == "0" && "$policy_diff" == "0" && "$folio_name_diff" == "0" && "$kc_stale" == "0" ]]; then
    log "Nothing to repair: FOLIO ids already match Keycloak, and every name still embedding a dead id belongs to a policy reported above as skipped."
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

run_folio -v tx_end="$tx_end" <<'SQL' || die "FOLIO transaction failed and rolled back — but the Keycloak rewrite before it has already COMMITTED, so the two sides are now half-aligned. Fix the cause and re-run: the maps are re-derived from the ids that still differ, and the Keycloak rewrite is a no-op the second time."
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

-- Capture children, then delete/update/reinsert: no FK is ON UPDATE CASCADE or deferrable, and
-- role_loadable is ON DELETE RESTRICT.
-- The copies are taken with SELECT * and reinserted without a column list, so the script carries no
-- inventory of these tables and a column added or renamed by a future mod-roles-keycloak migration
-- flows through untouched. (Naming the columns instead means an out-of-date list silently resets
-- whatever it omits — DEFAULTs do not error.) The id substitution is a separate UPDATE on the copy;
-- one UPDATE touches each row at most once, so a map that chains A→B, B→C cannot double-apply.
CREATE TEMP TABLE b_user_role AS
  SELECT t.* FROM user_role t JOIN role_map rm ON rm.old_id = t.role_id;
UPDATE b_user_role b SET role_id = rm.new_id FROM role_map rm WHERE rm.old_id = b.role_id;

CREATE TEMP TABLE b_role_capability AS
  SELECT t.* FROM role_capability t JOIN role_map rm ON rm.old_id = t.role_id;
UPDATE b_role_capability b SET role_id = rm.new_id FROM role_map rm WHERE rm.old_id = b.role_id;

CREATE TEMP TABLE b_role_capability_set AS
  SELECT t.* FROM role_capability_set t JOIN role_map rm ON rm.old_id = t.role_id;
UPDATE b_role_capability_set b SET role_id = rm.new_id FROM role_map rm WHERE rm.old_id = b.role_id;

CREATE TEMP TABLE b_role_loadable AS
  SELECT t.* FROM role_loadable t JOIN role_map rm ON rm.old_id = t.id;
UPDATE b_role_loadable b SET id = rm.new_id FROM role_map rm WHERE rm.old_id = b.id;

CREATE TEMP TABLE b_role_loadable_permission AS
  SELECT t.* FROM role_loadable_permission t JOIN role_map rm ON rm.old_id = t.role_loadable_id;
UPDATE b_role_loadable_permission b SET role_loadable_id = rm.new_id
  FROM role_map rm WHERE rm.old_id = b.role_loadable_id;

CREATE TEMP TABLE b_policy_roles AS
  SELECT t.* FROM policy_roles t
  LEFT JOIN policy_map pm ON pm.old_id = t.policy_id
  LEFT JOIN role_map   rm ON rm.old_id = t.role_id
  WHERE pm.new_id IS NOT NULL OR rm.new_id IS NOT NULL;
UPDATE b_policy_roles b SET policy_id = pm.new_id FROM policy_map pm WHERE pm.old_id = b.policy_id;
UPDATE b_policy_roles b SET role_id   = rm.new_id FROM role_map   rm WHERE rm.old_id = b.role_id;

CREATE TEMP TABLE b_policy_users AS
  SELECT t.* FROM policy_users t JOIN policy_map pm ON pm.old_id = t.policy_id;
UPDATE b_policy_users b SET policy_id = pm.new_id FROM policy_map pm WHERE pm.old_id = b.policy_id;

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
    description = CASE WHEN p.description IS NULL THEN NULL
                       ELSE replace(p.description, m.old_id::text, m.new_id::text) END
FROM role_map m
WHERE p.name LIKE '%' || m.old_id::text || '%'
   OR coalesce(p.description,'') LIKE '%' || m.old_id::text || '%';
-- Names/descriptions embedding an OLD folio user id (matched user policies only; no-op when the
-- FOLIO name already holds policy_users.user_id, which is the carry-over case).
UPDATE policy p
SET name        = replace(p.name,        m.old_id, m.new_id),
    description = CASE WHEN p.description IS NULL THEN NULL
                       ELSE replace(p.description, m.old_id, m.new_id) END
FROM user_map m
WHERE p.name LIKE '%' || m.old_id || '%'
   OR coalesce(p.description,'') LIKE '%' || m.old_id || '%';

-- No column lists: the copies were taken with SELECT *, so they match the live tables by
-- construction. See the note above the CREATE TEMP TABLEs.
INSERT INTO role_loadable            SELECT * FROM b_role_loadable;
INSERT INTO role_loadable_permission SELECT * FROM b_role_loadable_permission;
INSERT INTO user_role                SELECT * FROM b_user_role;
INSERT INTO role_capability          SELECT * FROM b_role_capability;
INSERT INTO role_capability_set      SELECT * FROM b_role_capability_set;
INSERT INTO policy_roles             SELECT * FROM b_policy_roles;
INSERT INTO policy_users             SELECT * FROM b_policy_users;

-- Every role with exactly one same-named Keycloak role must now carry the Keycloak id. Names held by
-- two Keycloak roles are deliberately outside the map, so they are outside the assertion too —
-- otherwise a skip the script chose on purpose would blow up the transaction that honours it.
DO $assert$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM role r
  WHERE r.id NOT IN (SELECT id FROM kc_roles_staging)
    AND r.name IN (SELECT name FROM kc_roles_staging GROUP BY name HAVING count(*) = 1);
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

if [[ "$KC_LEFTOVER" == "0" ]]; then
    cleanup_staging
else
    warn "Staging tables kept in $SCHEMA for diagnosis (the classification behind the report below);"
    warn "the next run drops and rebuilds them."
fi
log "Intermediate CSVs left in $WORK_DIR for diagnosis — safe to delete."
warn "Keycloak caches authorization data in memory: rolling-restart all Keycloak nodes OR call"
warn "POST /admin/realms/$TENANT/clear-realm-cache before actively managing the repaired roles."
if [[ "$KC_LEFTOVER" == "?" ]]; then
    warn "INCOMPLETE: the leftover count could not be read, so this run cannot certify the Keycloak side. Writes already made stand; re-run for a verdict."
    exit 3
fi
if [[ "$KC_LEFTOVER" != "0" ]]; then
    warn "INCOMPLETE: $KC_LEFTOVER Keycloak name(s)/description(s) still embed an id that resolves to no live role or user AND belongs to no policy reported above — a target absent from the maps, e.g. a user with permissions but no policy. (Stale ids inside a reported skip are expected and are not counted here.) A folio user id can be rebuilt from FOLIO on a re-run; a role id cannot, because its old→new mapping existed only while the two sides disagreed. Investigate before clearing caches."
    exit 3
fi
log "Repair complete for tenant $TENANT. Re-run to verify: it must report 'Nothing to repair'."
