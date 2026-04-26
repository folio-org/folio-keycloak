# folio-keycloak

## Introduction

A docker image for keycloak installation

## Version Compatibility

This table documents tested compatibility between folio-keycloak and FOLIO releases. Not all combinations have been
tested. Combinations not explicitly stated may work, but are not guaranteed.

> **Note:**  
> If you are a product or have tested a FOLIO Keycloak version with a specific FOLIO release, please contribute your findings. If you can confirm compatibility or incompatibility, create a PR in this project to update the documentation. Include evidence or explanations for your results to help keep the compatibility table current.  
> _We appreciate your contributions!_

| folio-keycloak | Compatible With             | Not Compatible With         |
|----------------|-----------------------------|-----------------------------|
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


### Additional variables for container

| METHOD                           | REQUIRED | DEFAULT VALUE                                                   | DESCRIPTION                 |
|:---------------------------------|:--------:|:----------------------------------------------------------------|:----------------------------|
| KC_FOLIO_BE_ADMIN_CLIENT_ID      |  false   | folio-backend-admin-client                                      | Folio backend client id     |
| KC_FOLIO_BE_ADMIN_CLIENT_SECRET  |   true   | -                                                               | Folio backend client secret |
| KC_HTTPS_KEY_STORE_TYPE          |  false   | BCFKS                                                           | Keystore type               |
| KC_HTTPS_KEY_STORE               |  false   | /opt/keycloak/conf/test.server.keystore                         | Keystore file               |
| KC_HTTPS_KEY_STORE_PASSWORD      |   true   | SecretPassword                                                  | Keystore password           |
| KCADM_HTTPS_TRUST_STORE_TYPE     |  false   | BCFKS                                                           | Truststore type             |
| KCADM_HTTPS_TRUST_STORE          |  false   | /opt/keycloak/conf/test.server.truststore                       | Truststore file             |
| KCADM_HTTPS_TRUST_STORE_PASSWORD |   true   | SecretPassword                                                  | Truststore password         |
| KC_LOG_LEVEL                     |  false   | INFO,org.keycloak.common.crypto:TRACE,org.keycloak.crypto:TRACE | Keycloak log level          |

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
- **Identifies Dead Permissions:** Finds 'scope' or 'resource' permissions that exclusively use the identified dead policies.
- **Streaming & Resumable:** Streams each page of policies/permissions and deletes orphans immediately, never holding the full ID set in memory. Persists progress in a state directory so a crash or restart can resume from the last committed offset.
- **High Performance:** Pre-loads all realm role IDs into an in-memory hash, drastically speeding up lookups (often 50-200x on large realms), and uses single-pass `jq` filters per page.
- **Parallel Deletions:** Deletes in configurable batches with bounded parallelism (`xargs -P`) and optional throttling between batches.
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

The script saves its execution state to a `.kc-cleanup-state/` directory by default. This allows the script to safely resume where it left off in the event of a crash, Keycloak restart, or early termination (SIGTERM). 

The state layout includes:
- `run.log`: A structured append-only log.
- `realms.done`: Tracks fully processed realms.
- `clients.done`: Tracks fully processed clients within a realm.
- `<client_uuid>.cursor`: Tracks the exact phase and offset for in-progress clients.

A re-run with the same `STATE_DIR` skips everything already marked as "done" and continues the in-progress client from its last cursor. To start completely fresh, use `RESET_STATE=true`.
