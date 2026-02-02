# Release Notes

## Version `v26.5.0` (in progress)
* Update compatibility documentation in README.md and NEWS.md (KEYCLOAK-96)
* Update to Keycloak 26.5.2 (KEYCLOAK-95)

## Version `v26.4.3` (22.12.2025)
* Include ECS authentication plugin into the FIPS Dockerfile (KEYCLOAK-93)

## Version `v26.4.2` (12.12.2025)
* Updated Bouncy Castle FIPS versions in Dockerfile-fips (KEYCLOAK-85)

## Version `v26.4.1` (10.12.2025)
* Lowercase the username (EUREKA-650)

## Version `v26.4.0` (02.12.2025)
* Updated to Keycloak 26.4.6
* Enable lightweight access token (KEYCLOAK-54)
* Changed default keystore from BCFKS to JKS (KEYCLOAK-69)
* Add keycloak upgrade workflow (KEYCLOAK-71)

## Version `v26.3.4` (21.10.2025)
* Updated to Keycloak 26.3.4
* Fixed password reset link issue with lightweight tokens (MODUSERBL-232)
* Added script to turn off lightweight token usage (KEYCLOAK-75)
* Upgrade Bouncy Castle FIPS fixing vulns (KEYCLOAK-71)

## Version `v26.3.1` (22.09.2025)
* Added env.KC_DB_URL_PORT to JDBC_PING2 (KEYCLOAK-69)

## Version `v26.3.0` (09.09.2025)
* Updated to Keycloak 26.3.3
* Updated FOLIO Keycloak plugin to 26.3.0
* Implement migration script for enabling lightweight access tokens (KEYCLOAK-66)
* Changed JDBC_PING to v2

## Version `v26.2.2` (03.09.2025)
* Changed JDBC_PING to v2

## Version `v26.2.1` (10.06.2025)
* Downgrade admin-fine-grained-authz from v2 to v1 (KEYCLOAK-60)

## Version `v26.2.0` (05.06.2025)
* Updated to Keycloak 26.2.5 (KEYCLOAK-58)
* Use KC_BOOTSTRAP_ADMIN_PASSWORD, not KEYCLOAK_ADMIN_PASSWORD (KEYCLOAK-53)

## Version `v26.1.3` (14.04.2025)
* Upgraded FOLIO Keycloak plugins fixing Netty CVE-2025-24970 (KEYCLOAK-49)

## Version `v26.1.2` (19.03.2025)
* Updated to Keycloak 26.1.4 fixing Netty CVE (KEYCLOAK-48)

## Version `v26.1.1` (14.03.2025)
* Implement POC to automate deploying custom authentication provider (EUREKA-650)
* Use Java 21 Jenkins build node (KEYCLOAK-46)

## Version `v26.1.0` (31.01.2025)
* Updated to Keycloak 26.1.0 (KEYCLOAK-25)
* Fix issues with keycloak v26.1.0 startup (EUREKA-653)
* Updated FOLIO Keycloak plugin version

## Version `v25.0.13` (07.01.2025)
* Increased cache size for authorization (MODSIDECAR-79)

## Version `v25.0.12` (27.11.2024)
* Username, password fields are required (KEYCLOAK-29)
