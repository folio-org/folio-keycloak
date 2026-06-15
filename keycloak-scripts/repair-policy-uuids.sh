#!/usr/bin/env bash
# repair-policy-uuids.sh — Repair corrupted tenant data after realm migration.
#
# This script re-aligns policy UUIDs between Keycloak and FOLIO after a migration.
# It exports resource data from Keycloak and synchronizes it in the FOLIO database.
#
# Required environment variables:
#   KC_DB_URL       — Keycloak database connection URL (postgresql://...)
#   FOLIO_DB_URL    — FOLIO database connection URL (postgresql://...)
#   TENANT          — The tenant name (e.g., "diku")
#
# Optional environment variables:
#   CSV_PATH        — Temporary CSV file path (default: /tmp/keycloak_policies.csv)

set -euo pipefail

# ---------- helpers ----------------------------------------------------------

log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "INFO" "$1" >&2; }
die() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "ERROR" "$1" >&2; exit "${2:-1}"; }

require_env() {
    local v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || die "Required environment variable not set: $v"
    done
}

# ---------- configuration ----------------------------------------------------

require_env KC_DB_URL FOLIO_DB_URL TENANT

CSV_PATH="${CSV_PATH:-/tmp/keycloak_policies.csv}"

# ---------- Step 1: Export Resource Data from Keycloak -----------------------

log "Exporting resource data from Keycloak database ($TENANT)..."

psql "$KC_DB_URL" -c "
\copy (
    SELECT 
        rsp.id,
        rsp.name
    FROM resource_server_policy rsp
    JOIN client c ON rsp.resource_server_id = c.id
    WHERE c.realm_id = (
        SELECT id FROM realm r WHERE r.name = '$TENANT'
    )
) TO '$CSV_PATH' WITH (FORMAT csv, HEADER true);
" || die "Failed to export data from Keycloak database."

# ---------- Step 2: Prepare Staging Table in FOLIO ---------------------------

log "Preparing staging table in FOLIO database..."

psql "$FOLIO_DB_URL" -c "
DROP TABLE IF EXISTS names_csv_staging;
CREATE TABLE names_csv_staging (
    name text,
    id uuid
);
" || die "Failed to create staging table in FOLIO database."

# ---------- Step 3: Load Data into FOLIO -------------------------------------

log "Loading exported data into FOLIO staging table..."

psql "$FOLIO_DB_URL" -c "
\copy names_csv_staging (id, name) FROM '$CSV_PATH' WITH (FORMAT csv, HEADER true);
" || die "Failed to load CSV data into FOLIO database."

# ---------- Step 4: Synchronize UUIDs in FOLIO -------------------------------

log "Synchronizing UUIDs in FOLIO database for tenant $TENANT..."

SCHEMA="${TENANT}_mod_roles_keycloak"

psql "$FOLIO_DB_URL" -c "
BEGIN;

-- 1) Backup role assignments
CREATE TEMP TABLE policy_roles_backup AS
SELECT
    pr.role_id,
    pr.required,
    p.name AS policy_name
FROM $SCHEMA.policy_roles pr
JOIN $SCHEMA.\"policy\" p
    ON pr.policy_id = p.id;

-- 2) Backup user assignments
CREATE TEMP TABLE policy_users_backup AS
SELECT
    pu.user_id,
    p.name AS policy_name
FROM $SCHEMA.policy_users pu
JOIN $SCHEMA.\"policy\" p
    ON pu.policy_id = p.id;

-- 3) Remove existing assignments
DELETE FROM $SCHEMA.policy_roles;
DELETE FROM $SCHEMA.policy_users;

-- 4) Update policy UUIDs from staging table
UPDATE $SCHEMA.\"policy\" p
SET id = c.id
FROM names_csv_staging c
WHERE p.name = c.name
  AND c.id IS NOT NULL
  AND p.id IS DISTINCT FROM c.id;

-- 5) Restore role assignments
INSERT INTO $SCHEMA.policy_roles (policy_id, role_id, required)
SELECT
    p.id,
    b.role_id,
    b.required
FROM policy_roles_backup b
JOIN $SCHEMA.\"policy\" p
    ON p.name = b.policy_name;

-- 6) Restore user assignments
INSERT INTO $SCHEMA.policy_users (policy_id, user_id)
SELECT
    p.id,
    b.user_id
FROM policy_users_backup b
JOIN $SCHEMA.\"policy\" p
    ON p.name = b.policy_name;

COMMIT;
" || die "Failed to synchronize UUIDs in FOLIO database."

# ---------- Step 5: Cleanup --------------------------------------------------

log "Cleaning up staging table and temporary file..."

psql "$FOLIO_DB_URL" -c "DROP TABLE IF EXISTS names_csv_staging;" || log "Warning: Failed to drop staging table."
rm -f "$CSV_PATH" || log "Warning: Failed to remove temporary CSV file: $CSV_PATH"

log "Successfully repaired policy UUIDs for tenant $TENANT."
