# folio-keycloak

## Introduction

A docker image for keycloak installation

## Version Compatibility

This table documents tested compatibility between folio-keycloak and FOLIO releases. Not all combinations have been
tested. Combinations not explicitly stated may work, but are not guaranteed.

> **Note:**  
> If you are a product or have tested a FOLIO Keycloak version with a specific FOLIO release, please contribute your
> findings. If you can confirm compatibility or incompatibility, create a PR in this project to update the documentation.
> Include evidence or explanations for your results to help keep the compatibility table current.  
> _We appreciate your contributions!_

| folio-keycloak | Compatible With             | Not Compatible With         |
|----------------|-----------------------------|-----------------------------|
| v26.7.0        | Umbrellaleaf (in dev)       |                             |
| v26.6.0        | Trillium, Sunflower CSP 8+  |                             |
| v26.5.x        | Sunflower CSP4+             | Sunflower CSP0-3 (TLS mode) |
| v26.4.x        | Sunflower CSP4+             | Sunflower CSP0-3 (TLS mode) |
| v26.3.x        | Sunflower CSP2-3            |                             |
| v26.2.x        | Sunflower CSP1              |                             |
| v26.1.x        | Sunflower GA, Ramsons CSP2+ |                             |

### Notes

**v26.4.x+ (and newer versions)**

- Does not work with Sunflower CSP0-3 in TLS mode due to missing JacksonProvider fix (KEYCLOAK-90). Use CSP4 or later.
  The issue is not with Keycloak but with the modules. Modules for CSP3 and earlier do not work with Keycloak 26.4.x or
  newer.
  **For release notes**, see [NEWS.md](NEWS.md).

## Keycloak Upgrades

See [docs/keycloak-upgrade.md](docs/keycloak-upgrade.md) for the runbook and merge gate details.

## Add custom theme

Copy `custom-theme` folder to /opt/jboss/keycloak/themes/

### Run container in docker

Build application with:

```shell
docker build -t folio-keycloak .
```

### Development mode

Set `KC_RUN_MODE=dev` to start Keycloak with `start-dev` instead of `start --optimized`. This skips the build step
and is useful for local development or environments where a pre-built optimized image is not available.

```shell
docker run -e KC_RUN_MODE=dev ... folio-keycloak
```

> **Note:** `start-dev` disables production hardening (e.g. it enables HTTP by default). Do not use in production.
> This mode is also used when running Keycloak as part of integration test environments.

### Additional variables for container

| METHOD                                                                                  | REQUIRED | DEFAULT VALUE                                                   | DESCRIPTION                                                                    |
|:----------------------------------------------------------------------------------------|:--------:|:----------------------------------------------------------------|:-------------------------------------------------------------------------------|
| KC_RUN_MODE                                                                             |  false   | prod                                                            | Startup mode: `prod` (optimized) or `dev` (start-dev, no `--optimized`)        |
| KC_FOLIO_BE_ADMIN_CLIENT_ID                                                             |  false   | folio-backend-admin-client                                      | Folio backend client id                                                        |
| KC_FOLIO_BE_ADMIN_CLIENT_SECRET                                                         |   true   | -                                                               | Folio backend client secret                                                    |
| KC_BOOTSTRAP_ADMIN_USERNAME                                                             |  false   | admin                                                           | Keycloak admin username used by `configure-realms.sh`                          |
| KC_BOOTSTRAP_ADMIN_PASSWORD                                                             |  false   | admin                                                           | Keycloak admin password used by `configure-realms.sh`                          |
| KC_HTTPS_KEY_STORE_TYPE                                                                 |  false   | BCFKS                                                           | Keystore type                                                                  |
| KC_HTTPS_KEY_STORE_FILE                                                                 |  false   | /opt/keycloak/conf/test.server.keystore                         | Keystore file                                                                  |
| KC_HTTPS_KEY_STORE_PASSWORD                                                             |   true   | SecretPassword                                                  | Keystore password                                                              |
| KCADM_HTTPS_TRUST_STORE_TYPE                                                            |  false   | BCFKS                                                           | Truststore type                                                                |
| KCADM_HTTPS_TRUST_STORE                                                                 |  false   | /opt/keycloak/conf/test.server.truststore                       | Truststore file                                                                |
| KCADM_HTTPS_TRUST_STORE_PASSWORD                                                        |   true   | SecretPassword                                                  | Truststore password                                                            |
| KC_LOG_LEVEL                                                                            |  false   | INFO,org.keycloak.common.crypto:TRACE,org.keycloak.crypto:TRACE | Keycloak log level                                                             |
| KC_CACHE_EMBEDDED_AUTHORIZATION_MAX_COUNT                                               |  false   | 80000                                                           | Authorization cache max entries                                                |
| KC_CACHE_EMBEDDED_OFFLINE_SESSIONS_MAX_COUNT                                            |  false   | 100000                                                          | Offline sessions cache max entries                                             |
| KC_CACHE_EMBEDDED_OFFLINE_CLIENT_SESSIONS_MAX_COUNT                                     |  false   | 100000                                                          | Offline client sessions cache max entries                                      |
| KC_SPI_LOGIN_PROTOCOL__OPENID_CONNECT__ALLOW_TOKEN_INTROSPECTION_WITHOUT_AUDIENCE_CHECK |  false   | true                                                            | Allow token introspection without audience validation. Should be set as `true` |
| KC_SPI_LOGIN_PROTOCOL__OPENID_CONNECT__ALLOW_USERINFO_WITH_LIGHTWEIGHT_ACCESS_TOKEN     |  false   | true                                                            | Allow UserInfo with lightweight access tokens. Should be set as `true`         |

#### Note – Temporary setting required to retain Keycloak 26.5.7 OIDC behavior expected by FOLIO.

The published `folio-keycloak` image defaults the following variables to `true`. This retains the Keycloak 26.5.7 OIDC
behavior expected by FOLIO.

- `KC_SPI_LOGIN_PROTOCOL__OPENID_CONNECT__ALLOW_TOKEN_INTROSPECTION_WITHOUT_AUDIENCE_CHECK`
- `KC_SPI_LOGIN_PROTOCOL__OPENID_CONNECT__ALLOW_USERINFO_WITH_LIGHTWEIGHT_ACCESS_TOKEN`

Custom images not based on the `folio-keycloak` image must set them explicitly:

```dockerfile
ENV KC_SPI_LOGIN_PROTOCOL__OPENID_CONNECT__ALLOW_TOKEN_INTROSPECTION_WITHOUT_AUDIENCE_CHECK=true \
    KC_SPI_LOGIN_PROTOCOL__OPENID_CONNECT__ALLOW_USERINFO_WITH_LIGHTWEIGHT_ACCESS_TOKEN=true
```

### Cluster Cache Discovery

The image uses Keycloak's supported `jdbc-ping` cache stack for embedded Infinispan cluster discovery. The legacy
custom `cache-ispn-jdbc.xml` file is no longer used by the image.

The legacy XML did not set a count limit for offline session caches, while Keycloak's built-in cache configuration
defaults them to 10000 entries. This image sets supported offline cache max-count options to 100000 by default to reduce
database lookups from cache eviction. Use the offline cache max-count variables above to tune this per deployment.

When health checks are enabled, `/health/ready` should include the `Keycloak cluster health check`, and metrics should
expose `vendor_cluster_size` for cluster membership monitoring.

## Setup Admin Client [setup-admin-client.sh](folio/setup-admin-client.sh)

Script to create or update Keycloak admin client with lightweight token support. Executed automatically during container
initialization.

### What the Script Does

- Creates a new admin client if it doesn't exist with service accounts and proper credentials
- Enables lightweight access tokens for the client
- Configures realm roles protocol mapper with lightweight claim support
- Assigns admin and create-realm roles to the service account
- For existing clients: enables lightweight tokens and adds missing mappers if needed
- Idempotent - safe to run multiple times without side effects

## Migrate Existing Realms to Lightweight Tokens

**Script:** [migrate-tenants-to-lightweight-tokens.sh](keycloak-scripts/migrate-tenants-to-lightweight-tokens.sh)

Migrates existing cluster realms to lightweight tokens, reducing token footprint and preventing issues caused by
oversized request headers.

**Affected clients:** ImpersonationClient, LoginClient, PasswordResetClient, Module-to-Module Client

### Requirements

- Keycloak Admin REST API access
- Keycloak admin username and password
- Bash shell
- Required tools: `curl`, `jq`

### Usage

**1. Set environment variables:**

```bash
export KC_LOGIN_CLIENT_SUFFIX="-login-application"
export KC_SERVICE_CLIENT_ID="sidecar-module-access-client"
export KC_PASSWORD_RESET_CLIENT_ID="password-reset-client"
export KC_IMPERSONATION_CLIENT="impersonation-client"
export KEYCLOAK_URL="http://your-keycloak-host:8080"
```

**2. Run the script:**

```bash
migrate-tenants-to-lightweight-tokens.sh <admin_username> <admin_password>
```

### What the Script Does

1. Fetches all realms (except `master`)
2. For each specified client in each realm:
    - Adds or patches the `sub` and `user_id mapper` protocol mappers
    - Enables `client.use.lightweight.access.token.enabled`
    - Sets `lightweight.claim=true` on the `user_id mapper`
3. Patches all role policies to enable `fetchRoles`

If any operation fails (client not found, API error, etc.), outputs a warning instead of stopping.

### Notes

- **Safe for reruns:** existing mappers and policies are updated, not duplicated
- Ensure your Keycloak admin user has sufficient permissions
- Always test in staging before running in production

## Migrate Existing Realms to Regular Tokens

**Script:** [migrate-tenants-to-regular-tokens.sh](keycloak-scripts/migrate-tenants-to-regular-tokens.sh)

Reverts realms back to regular tokens, undoing the changes made by the lightweight token migration script.

**Affected clients:** ImpersonationClient, LoginClient, PasswordResetClient, Module-to-Module Client

### Requirements

- Keycloak Admin REST API access
- Keycloak admin username and password
- Bash shell
- Required tools: `curl`, `jq`

### Usage

**1. Set environment variables:**

```bash
export KC_LOGIN_CLIENT_SUFFIX="-login-application"
export KC_SERVICE_CLIENT_ID="sidecar-module-access-client"
export KC_PASSWORD_RESET_CLIENT_ID="password-reset-client"
export KC_IMPERSONATION_CLIENT="impersonation-client"
export KEYCLOAK_URL="http://your-keycloak-host:8080"
```

**2. Run the script:**

```bash
migrate-tenants-to-regular-tokens.sh <admin_username> <admin_password>
```

### What the Script Does

1. Fetches all realms (except `master`)
2. For each specified client in each realm:
    - Adds or patches the `sub` and `user_id mapper` protocol mappers
    - Disables `client.use.lightweight.access.token.enabled`
3. Patches all role policies to disable `fetchRoles`

If any operation fails (client not found, API error, etc.), outputs a warning instead of stopping.

### Notes

- **Safe for reruns:** existing mappers and policies are updated, not duplicated
- Ensure your Keycloak admin user has sufficient permissions
- Always test in staging before running in production

## Remove Unused Authorization Objects [remove-unused-authz-objects.sh](keycloak-scripts/remove-unused-authz-objects.sh)

Script to identify and remove Keycloak Authorization policies and permissions that reference roles that no longer exist.

### What the Script Does

- **Identifies Dead Role Policies:** Finds policies of type 'role' where all referenced roles have been deleted.
- **Identifies Dead Permissions:** Finds 'scope' or 'resource' permissions that exclusively use the identified dead
  policies.
- **Streaming & Resumable:** Streams each page of policies/permissions and deletes orphans immediately, never holding
  the full ID set in memory. Persists progress in a state directory so a crash or restart can resume from the last
  committed offset.
- **High Performance:** Pre-loads all realm role IDs into an in-memory hash, drastically speeding up lookups (often
  50-200x on large realms), and uses single-pass `jq` filters per page.
- **Parallel Deletions:** Deletes in configurable batches with bounded parallelism (`xargs -P`) and optional throttling
  between batches.
- **Dry-Run Mode:** By default, it only previews what would be deleted without making any changes.
- **Summary Report:** Provides a detailed count of processed realms, checked clients, and found/deleted resources.

### Requirements

- Keycloak Admin REST API access
- Keycloak admin username and password
- Bash shell (3.2+ compatible)
- Required tools: `curl`, `jq`

### Usage

**1. Set environment variables (optional):**

```bash
export KEYCLOAK_URL="http://localhost:8080"
export KC_ADMIN_USER="admin"                 # Alternative to positional argument
export KC_ADMIN_PASSWORD="admin"             # Alternative to positional argument
export CLIENT_ID_PATTERN="-application$"     # Regex pattern to filter clients
export TENANT_IDS=""                         # Comma-separated realms; empty = all realms
export DRY_RUN="true"                        # Set to "false" to perform actual deletions
export PAGE_SIZE=100                         # Number of items per API request
export BATCH_SIZE=50                         # Deletes flushed per batch
export PARALLEL_DELETES=4                    # Concurrent DELETE requests
export BATCH_SLEEP_MS=0                      # Sleep between batches (ms)
export MAX_RETRIES=3                         # Per-request retry count
export RETRY_DELAY=5                         # Backoff between retries (s)
export STATE_DIR="./.kc-cleanup-state"       # Where checkpoints live
export RESET_STATE="false"                   # true to wipe state and restart
export LOG_FILE="./.kc-cleanup-state/run.log" # Append structured log here
```

### Examples

**Dry-run, all realms, default settings:**

```bash
DRY_RUN=true ./keycloak-scripts/remove-unused-authz-objects.sh admin <pwd>
```

**One tenant, real deletions, more parallelism:**

```bash
DRY_RUN=false TENANT_IDS=acme PARALLEL_DELETES=8 BATCH_SIZE=100 \
  ./keycloak-scripts/remove-unused-authz-objects.sh admin <pwd>
```

**Multiple tenants, gentle on Keycloak:**

```bash
DRY_RUN=false TENANT_IDS=acme,globex,initech PARALLEL_DELETES=2 BATCH_SLEEP_MS=250 \
  ./keycloak-scripts/remove-unused-authz-objects.sh admin <pwd>
```

**Resume after a Keycloak restart (same command, same STATE_DIR):**

```bash
DRY_RUN=false TENANT_IDS=acme ./keycloak-scripts/remove-unused-authz-objects.sh admin <pwd>
```

**Start over (wipes previous state):**

```bash
RESET_STATE=true DRY_RUN=true ./keycloak-scripts/remove-unused-authz-objects.sh admin <pwd>
```

### Resume Behavior

The script saves its execution state to a `.kc-cleanup-state/` directory by default. This allows the script to safely
resume where it left off in the event of a crash, Keycloak restart, or early termination (SIGTERM).

The state layout includes:

- `run.log`: A structured append-only log.
- `realms.done`: Tracks fully processed realms.
- `clients.done`: Tracks fully processed clients within a realm.
- `<client_uuid>.cursor`: Tracks the exact phase and offset for in-progress clients.

A re-run with the same `STATE_DIR` skips everything already marked as "done" and continues the in-progress client from
its last cursor. To start completely fresh, use `RESET_STATE=true`.

## Online Realm Migration [migrate-realm.sh](keycloak-scripts/migrate-realm.sh)

Script for online cluster-to-cluster Keycloak realm migration using the Admin REST API with zero downtime.

### What the Script Does

- **Atomic Realm Creation:** Imports realm configuration (login, tokens, themes, etc.), roles, groups, clients (with
  full authorization settings), authentication flows, and identity providers in a single POST request.
- **Batched User Import:** Migrates users separately using the `partialImport` API in configurable batches to avoid
  body-size limits and ensure reliability.
- **Pre-flight Validation:** Verifies the destination realm doesn't exist, checks for required signing keys to maintain
  token validity, and summarizes authorization settings coverage.
- **Cache Verification:** Optionally verifies that the newly created realm is visible across all nodes in the
  destination cluster to ensure proper JGroups propagation.
- **Post-Import Spot-checks:** Performs deep validation of authorization objects (resources, policies, permissions) and
  user counts to ensure migration integrity.
- **Resumable:** If user import fails, it can be resumed by re-running the script; it uses the `FAIL` strategy for
  `partialImport` to remain idempotent.

### Requirements

- Keycloak Admin REST API access on the destination cluster.
- Admin service-account credentials for the `master` realm.
- A realm export bundle produced by `kc.sh export` (containing `<TENANT>-realm.json`).
- Bash shell (4.0+ recommended).
- Required tools: `curl`, `jq`.

### Usage

**1. Set environment variables:**

```bash
export KC_URL="https://keycloak.dest.example.com"
export KC_ADMIN_CLIENT_ID="admin-cli"
export KC_ADMIN_CLIENT_SECRET="your-secret"
export TENANT="my-realm"
export EXPORT_DIR="/path/to/export/files"

# Optional
export DEST_NODES="https://node1.internal:8443,https://node2.internal:8443"
export USER_BATCH_SIZE=1000
```

**2. Run the script:**

```bash
./keycloak-scripts/migrate-realm.sh
```

### Exit Codes

| Code | Meaning                                                        |
|:-----|:---------------------------------------------------------------|
| 0    | Success                                                        |
| 1    | Pre-flight failure (no writes performed)                       |
| 2    | Failure during realm creation (realm may need manual deletion) |
| 3    | Failure during user import (realm exists, safe to resume)      |
| 4    | Cache verification failure (investigate JGroups)               |
| 5    | Post-import authorization spot-check failed                    |

### Notes

- **Zero Downtime:** Designed to migrate realms to a running cluster without requiring a restart.
- **Sessions:** User sessions and offline tokens are **NOT** migrated. Users will need to re-authenticate.
- **Signing Keys:** The script ensures signing keys are imported so that refresh tokens from the source cluster remain
  valid (if the client is already configured to trust them).
- **Fine-Grained Admin Permissions:** If using FGAP V2, ensure the feature is enabled on both source and destination
  clusters.

## Repair Corrupted Tenant Data [repair-policy-uuids.sh](keycloak-scripts/repair-policy-uuids.sh)

This procedure explains how to repair corrupted tenant data after a Keycloak realm migration by re-aligning policy UUIDs
between Keycloak and FOLIO.

### Problem Description

After realm migration, some resource identifiers (UUIDs) in Keycloak change. However, FOLIO (`mod-roles-keycloak`) may
still reference the old UUIDs.

This leads to:

- Broken references between FOLIO and Keycloak.
- Missing resources when resolving policies.
- Inability to manage roles and permissions correctly.

To resolve this, we must synchronize the correct UUIDs from Keycloak into the FOLIO database.

Because PostgreSQL does not support cross-database joins, the required data must be exported from Keycloak and imported
into FOLIO.

### Step 1: Export Resource Data from Keycloak

Run the following query on the Keycloak database:

```sql
SELECT rsp.id   AS id,
       rsp.name AS name
FROM resource_server_policy rsp
         JOIN client c ON rsp.resource_server_id = c.id
WHERE c.realm_id = (SELECT id
                    FROM realm r
                    WHERE r.name = '$tenantName');
```

Replace `$tenantName` with the actual tenant name.

**Export to CSV (psql):**

```sql
\copy
(
SELECT rsp.id,
       rsp.name
FROM resource_server_policy rsp
         JOIN client c ON rsp.resource_server_id = c.id
WHERE c.realm_id = (SELECT id
                    FROM realm r
                    WHERE r.name = '$tenantName') ) TO '/tmp/keycloak_policies.csv'
WITH (FORMAT csv, HEADER true);
```

### Step 2: Import Data into FOLIO Database

Connect to the FOLIO database and create a staging table:

```sql
CREATE TABLE names_csv_staging
(
    name text,
    id   uuid
);
```

**Load the CSV file:**

```sql
COPY names_csv_staging (id, name)
    FROM '/tmp/keycloak_policies.csv'
    WITH (FORMAT csv, HEADER true);
```

### Step 3: Synchronize UUIDs in FOLIO

Execute the following script in a single transaction:

```sql
BEGIN;

-- 1) Backup role assignments
CREATE
TEMP TABLE policy_roles_backup AS
SELECT pr.role_id,
       pr.required,
       p.name AS policy_name
FROM $tenantName_mod_roles_keycloak.policy_roles pr
         JOIN $tenantName_mod_roles_keycloak."policy" p
              ON pr.policy_id = p.id;

-- 2) Backup user assignments
CREATE
TEMP TABLE policy_users_backup AS
SELECT pu.user_id,
       p.name AS policy_name
FROM $tenantName_mod_roles_keycloak.policy_users pu
         JOIN $tenantName_mod_roles_keycloak."policy" p
              ON pu.policy_id = p.id;

-- 3) Remove existing assignments
DELETE
FROM $tenantName_mod_roles_keycloak.policy_roles;
DELETE
FROM $tenantName_mod_roles_keycloak.policy_users;

-- 4) Update policy UUIDs from staging table
UPDATE $tenantName_mod_roles_keycloak."policy" p
SET id = c.id FROM names_csv_staging c
WHERE p.name = c.name
  AND c.id IS NOT NULL
  AND p.id IS DISTINCT
FROM c.id;

-- 5) Restore role assignments
INSERT INTO $tenantName_mod_roles_keycloak.policy_roles (policy_id, role_id, required)
SELECT p.id,
       b.role_id,
       b.required
FROM policy_roles_backup b
         JOIN $tenantName_mod_roles_keycloak."policy" p
              ON p.name = b.policy_name;

-- 6) Restore user assignments
INSERT INTO $tenantName_mod_roles_keycloak.policy_users (policy_id, user_id)
SELECT p.id,
       b.user_id
FROM policy_users_backup b
         JOIN $tenantName_mod_roles_keycloak."policy" p
              ON p.name = b.policy_name;

COMMIT;
```

Replace `$tenantName` with the correct tenant schema name.

### Step 4: Cleanup

After successful execution, remove the staging table:

```sql
DROP TABLE IF EXISTS names_csv_staging;
```

### Automated Script Usage

The `repair-policy-uuids.sh` script automates these steps if you have `psql` access to both databases.

**Usage:**

```bash
export KC_DB_URL="postgresql://user:pass@host:5432/keycloak"
export FOLIO_DB_URL="postgresql://user:pass@host:5432/folio"
export TENANT="diku"

./keycloak-scripts/repair-policy-uuids.sh
```

## Repair Corrupted Role and Policy UUIDs [repair-role-policy-uuids.sh](keycloak-scripts/repair-role-policy-uuids.sh)

`repair-policy-uuids.sh` (above) only fixes policy UUIDs. A same-cluster realm migration also hands roles brand-new Keycloak UUIDs, and `mod-roles-keycloak` stores that UUID as `role.id`. Every stored reference then points at the old id, so editing or deleting a role returns `404` from Keycloak. This script re-aligns roles **and** policies — both role policies and user policies. It writes twice, once per database: the Keycloak rewrite commits first, the FOLIO transaction second (see below).

**How it works.** Policies are matched between FOLIO and Keycloak by the **entity they reference**, never by policy name — a policy's name embeds the id of that entity, i.e. the very id that desyncs, so a name join is unreliable. The key is routed by name shape and resolved from the live reference (role *name* and folio *user id* are both stable across the migration, so the key matches even though the ids in the names do not):

| policy name shape | key | resolved from |
|---|---|---|
| `Policy for role: <uuid>` | `role:<role name>` | KC `policy_config['roles']` → `keycloak_role.name`; FOLIO `policy_roles` → `role.name` |
| `Policy for user: <uuid>` | `user:<folio user id>` | KC `policy_config['users']` → `user_entity` → `user_id` attribute; FOLIO `policy_users.user_id` |
| anything else | `name:<policy name>` | the literal name (admin-authored / TIME policies) |

The script:

1. Exports the current Keycloak roles, policies and folio user ids; classifies every matched policy and builds an old→new map.
2. Reports anything it cannot synchronise — before either database is written.
3. Rewrites stale role ids and folio user ids out of Keycloak's `resource_server_policy` names and descriptions (**policies and permissions**) and the role wiring in `policy_config`.
4. In a single FOLIO transaction, fixes `role.id` and `policy.id` and every row that points at them — `user_role`, `role_capability`, `role_capability_set`, `role_loadable`, `role_loadable_permission`, `policy_roles`, `policy_users` — then rewrites stale ids out of `policy.name` / `policy.description`.

**Keycloak is written before FOLIO, and that order matters.** The two databases share no transaction, so a run can die between the writes. Both id maps are derived from FOLIO's ids still differing from Keycloak's, and the Keycloak step only rewrites name strings — it never changes a Keycloak id. So a run interrupted between the two steps leaves everything the maps are built from intact, and simply running the script again finishes the job. Commit FOLIO first instead and that difference is gone, which is why the reverse order needs a saved map and a resume mode.

**Best effort, by design.** An anomaly in the *data* does not abort the run: everything that maps 1:1 is repaired, everything that does not is skipped and reported, and the script never deletes a role, policy or permission (it does delete and reinsert child rows inside its own transaction, because the foreign keys are not `ON UPDATE CASCADE` — that is a rewrite, not a removal).

It aborts (exit 1) when it cannot work at all — missing variable, realm or schema, or a query it depends on failing — or when a write fails. Each write is a single transaction, but there are two of them in two databases: an abort at or before the Keycloak rewrite leaves both untouched, while an abort in the FOLIO transaction rolls FOLIO back with the Keycloak rewrite already committed. Re-running finishes the job, but do not read exit 1 as "nothing changed".

The report groups the skips by what they ask of you:

| class | meaning | what to do |
|---|---|---|
| `ambiguous` | several policies resolve to the same entity, so no id can be assigned deterministically | delete the surplus policy in Keycloak, re-run — the pair then repairs itself |
| FOLIO-only policy | FOLIO holds a policy Keycloak does not; `mod-roles-keycloak` addresses Keycloak by the FOLIO policy id, so its next update hits a missing object | investigate — usually the realm snapshot predates the FOLIO schema |
| Keycloak-only policy | no FOLIO counterpart; still enforced, but unmanaged | clean up deliberately, outside this script |
| `multi` / `unresolved` | the policy references several entities, or none this script can resolve (e.g. a client role) | not repairable by id matching |
| duplicate Keycloak role names | role name is the only stable key, so the role and its children are left alone | resolve the duplicate name, re-run |
| roles in FOLIO but not Keycloak | no id to adopt | expected after a partial migration |
| unknown FOLIO policy type | a type outside `ROLE`/`USER`/`TIME`, which the script cannot key at all | a newer `mod-roles-keycloak` added a type — the script needs teaching |
| stale user link | `user_role.user_id` values Keycloak does not know as a `user_id` attribute | folio user ids were regenerated; repair user provisioning |
| collision-excluded map row | rewriting it would land two Keycloak policies on one name, so that id was dropped from the map | resolve the duplicate name in Keycloak; for a **role** id this must be done before the FOLIO commit, because afterwards the old→new mapping no longer exists anywhere |

`ambiguous` is the normal steady state on an environment running `mod-users-keycloak` 3.0.x, where a module system user gets its capabilities by direct user-capability assignment: each change of that user's folio id orphans its `Policy for user: <old id>` and the next assignment creates another one. On 4.x, where system users go through a default role, the class disappears. The report prints the per-key count on both sides — remove the surplus on the side that actually has more than one, since a key duplicated in FOLIO is not fixed by deleting anything in Keycloak.

A stale id that belongs to a policy reported above is expected and is not counted as leftover. Only a stale Keycloak name attributable to no reported skip raises the final `WARN` and exit 3 — which means "written, but not certified clean", not "failed". That check runs after the Keycloak rewrite, so a dry run never reaches it; the equivalent pre-run figure is logged as `unexplained stale KC names`.

With `DRY_RUN=true` (exactly that string — `1` or `yes` performs a **real run**) it skips the Keycloak rewrite, runs the FOLIO transaction and rolls it back, and prints what it would change. No tenant data is written to either database; the run still creates and drops its own staging tables in the FOLIO schema, and reads Keycloak. Re-run the script after a real run: a clean repair reports `Nothing to repair`.

### Running it

Back up the schema first, then dry-run before the real thing:

```bash
export KC_DB_URL="postgresql://user:pass@host:5432/keycloak"
export FOLIO_DB_URL="postgresql://user:pass@host:5432/folio"
export TENANT="diku"

pg_dump "$FOLIO_DB_URL" -n "${TENANT}_mod_roles_keycloak" > roles_backup.sql

DRY_RUN=true ./keycloak-scripts/repair-role-policy-uuids.sh   # report only, nothing committed
./keycloak-scripts/repair-role-policy-uuids.sh                # apply
```

| Variable       | Default                                 | Purpose                                                      |
|----------------|-----------------------------------------|--------------------------------------------------------------|
| `KC_DB_URL`    | *(required)*                            | Keycloak DB connection URL                                   |
| `FOLIO_DB_URL` | *(required)*                            | FOLIO DB connection URL                                      |
| `TENANT`       | *(required)*                            | Tenant / realm name                                          |
| `DRY_RUN`      | `false`                                 | Skip the Keycloak rewrite, run the FOLIO transaction and roll it back, print a report |
| `WORK_DIR`     | `/tmp/repair-role-policy-uuids-$TENANT` | Scratch space for the CSVs the run passes between the two database connections (`role_id_map.csv`, `user_id_map.csv`, `explained_ids.csv`, plus the Keycloak exports) |

### Good to know

- The FOLIO transaction takes `EXCLUSIVE` locks on the nine affected tables — readers are fine, concurrent writers wait — and a dry run takes them too. Between the Keycloak rewrite and the FOLIO commit, role management is briefly inconsistent.
- Child rows are copied with `SELECT *` and reinserted without a column list, so a column added or renamed by a newer `mod-roles-keycloak` flows through untouched. Only the handful of columns the script actually joins and rewrites on is checked, and only their absence aborts the run.
- A dry run still creates and drops its staging tables in the FOLIO schema (each `psql` call is a separate session, so they cannot be `TEMP`); it never touches the tenant's own tables and never writes to Keycloak at all.
- The CSVs left in `WORK_DIR` are the run's intermediate state, kept for diagnosis. They are not a recovery mechanism and nothing reads them on a later invocation — delete them whenever you like.
- Keycloak caches authorization data in memory, so after a real run either roll-restart the Keycloak nodes or call `POST /admin/realms/{tenant}/clear-realm-cache` (clears the authz cache cluster-wide). `mod-roles-keycloak` doesn't cache role ids, but its config caches have a 3600s TTL — restart it or wait out the TTL before managing the repaired roles.

### If a run fails part-way

Run it again. There is no recovery mode and no state to carry over: the write order means an interrupted run leaves the id maps re-derivable, so a plain re-run picks up wherever the last one stopped and reports `Nothing to repair` once everything is aligned.

If the FOLIO transaction itself looks wrong rather than merely interrupted, restore the schema from the `pg_dump` you took first — and then re-run, because a restore rolls back FOLIO only and Keycloak may already carry the rewritten names.
