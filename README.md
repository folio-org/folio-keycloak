# folio-keycloak

## Introduction

A docker image for keycloak installation

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
| KC_HTTPS_KEY_STORE_PASSWORD      |   true   | -                                                               | BCFSK Keystore password     |
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


## Migrate exist Realms into Lightweight Token  [migrate-tenants-to-lightweight-tokens.sh](keycloak-scripts/migrate-tenants-to-lightweight-tokens.sh)
Script to migrate existing cluster realms to lightweight tokens, reducing token footprint and preventing issues caused by oversized request headers.
For each realm, the following clients will be updated: ImpersonationClient, LoginClient, PasswordResetClient, and Module 2 Module Client.

### Requirements
Keycloak Admin REST API access
Keycloak admin username and password
Bash shell
Required tools:
  curl
  jq (for JSON processing)

###  Usage
Set up environment variables for client names:
  Set the environment variables KC_LOGIN_CLIENT_SUFFIX, KC_SERVICE_CLIENT_ID, KC_PASSWORD_RESET_CLIENT_ID, KC_IMPERSONATION_CLIENT to specify four target clients to modify across realms.
  Set the environment variable KEYCLOAK_URL

#### Example:

export KC_LOGIN_CLIENT_SUFFIX="-login-application"
export KC_SERVICE_CLIENT_ID="sidecar-module-access-client"
export KC_PASSWORD_RESET_CLIENT_ID="password-reset-client"
export KC_IMPERSONATION_CLIENT="impersonation-client"
export KEYCLOAK_URL="http://your-keycloak-host:8080"
#### Run the script

Pass your Keycloak admin username and password as parameters:
  migrate-tenants-to-lightweight-tokens.sh <admin_username> <admin_password>
   

### What the Script Does
Fetches all realms (except 'master')
For each specified client in each realm:
  Adds or patches the "sub" and "user_id mapper" protocol mappers to ensure lightweight claim configuration.
Enables "client.use.lightweight.access.token.enabled" for the clients.
Ensures the lightweight.claim="true" on the "user_id mapper".
Patches all role policies so fetchRoles is enabled.

If any operation fails (client not found, API error, etc.), outputs a warning or error instead of stopping execution.

### Notes
The script is safe for reruns: existing mappers and policies are updated, not duplicated.
Make sure your Keycloak admin user has sufficient permissions for the admin API.
Always test in staging before run on production.


## Migrate exist Realms into Regular Token  [migrate-tenants-to-regular-tokens.sh](keycloak-scripts/migrate-tenants-to-regular-tokens.sh)
Script to migrate existing cluster realms back to regular tokens, reverting the changes made by the lightweight token migration script.
For each realm, the following clients will be updated: ImpersonationClient, LoginClient, PasswordResetClient, and Module-to-Module Client.

### Requirements
Keycloak Admin REST API access
Keycloak admin username and password
Bash shell
Required tools:
curl
jq (for JSON processing)

###  Usage
Set up environment variables for client names:
Set the environment variables KC_LOGIN_CLIENT_SUFFIX, KC_SERVICE_CLIENT_ID, KC_PASSWORD_RESET_CLIENT_ID, KC_IMPERSONATION_CLIENT to specify four target clients to modify across realms.
Set the environment variable KEYCLOAK_URL

#### Example:

export KC_LOGIN_CLIENT_SUFFIX="-login-application"
export KC_SERVICE_CLIENT_ID="sidecar-module-access-client"
export KC_PASSWORD_RESET_CLIENT_ID="password-reset-client"
export KC_IMPERSONATION_CLIENT="impersonation-client"
export KEYCLOAK_URL="http://your-keycloak-host:8080"
#### Run the script

Pass your Keycloak admin username and password as parameters:
migrate-tenants-to-regular-tokens.sh <admin_username> <admin_password>


### What the Script Does
Fetches all realms (except 'master')
For each specified client in each realm:
Adds or patches the "sub" and "user_id mapper" protocol mappers to ensure regular claim configuration.
Disable "client.use.lightweight.access.token.enabled" for the clients.
Patches all role policies so fetchRoles is disabled.

If any operation fails (client not found, API error, etc.), outputs a warning or error instead of stopping execution.

### Notes
The script is safe for reruns: existing mappers and policies are updated, not duplicated.
Make sure your Keycloak admin user has sufficient permissions for the admin API.
Always test in staging before run on production.
