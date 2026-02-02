# folio-keycloak

## Introduction

A docker image for keycloak installation

## Version Compatibility

This table documents tested compatibility between folio-keycloak and FOLIO releases.  Not all combinations have been tested.  Combinations not explicitly stated may work, but are not guaranteed.

| folio-keycloak | Compatible With                      | Not Compatible With         |
|----------------|--------------------------------------|-----------------------------|
| v26.4.x        | Sunflower CSP4+                      | Sunflower CSP0-3 (TLS mode) |
| v26.3.x        | Sunflower CSP2-3                     |                             |
| v26.2.x        | Sunflower CSP1                       |                             |
| v26.1.x        | Sunflower GA, Ramsons CSP2+          |                             |

### Notes

**v26.4.x**
- Does not work with Sunflower CSP0-3 in TLS mode due to missing JacksonProvider fix (KEYCLOAK-90). Use CSP4 or later.

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
| KC_HTTPS_KEY_STORE_PASSWORD      |   true   | -                                                               | Keystore password           |
| KCADM_HTTPS_TRUST_STORE_TYPE     |  false   | BCFKS                                                           | Truststore type             |
| KCADM_HTTPS_TRUST_STORE          |  false   | /opt/keycloak/conf/test.server.truststore                       | Truststore file             |
| KCADM_HTTPS_TRUST_STORE_PASSWORD |  false   | SecretPassword                                                  | Truststore password         |
| KC_LOG_LEVEL                     |  false   | INFO,org.keycloak.common.crypto:TRACE,org.keycloak.crypto:TRACE | Keycloak log level          |


## Setup Admin Client [setup-admin-client.sh](folio/setup-admin-client.sh)
Script to create or update Keycloak admin client with lightweight token support. Executed automatically during container initialization.

### What the Script Does
- Creates a new admin client if it doesn't exist with service accounts and proper credentials
- Enables lightweight access tokens for the client
- Configures realm roles protocol mapper with lightweight claim support
- Assigns admin and create-realm roles to the service account
- For existing clients: enables lightweight tokens and adds missing mappers if needed
- Idempotent - safe to run multiple times without side effects


## Migrate Existing Realms to Lightweight Tokens

**Script:** [migrate-tenants-to-lightweight-tokens.sh](keycloak-scripts/migrate-tenants-to-lightweight-tokens.sh)

Migrates existing cluster realms to lightweight tokens, reducing token footprint and preventing issues caused by oversized request headers.

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
