# Keycloak Upgrade Process

## Overview

Dependabot creates PRs when the Keycloak base image tag changes. These upgrades need coordination with plugins and downstream modules plus manual testing. This guide summarizes what the automation does and what you need to verify before merging.

## Automated Components

### 1. Dependabot Configuration

Dependabot is configured (`.github/dependabot.yml`) to:
- Monitor the Keycloak base image (`quay.io/keycloak/keycloak`) weekly
- Create PRs that update the Keycloak base image tag in `Dockerfile` and `Dockerfile-fips`
- Automatically label PRs with `dependencies`, `docker`, and `keycloak-upgrade`

### 2. Automatic Runbook Comment

When Dependabot creates a Keycloak upgrade PR, the `keycloak-upgrade-instructions` workflow posts a runbook comment with the verification steps (`.github/workflows/keycloak-upgrade-instructions.yml`).

### 3. Merge Gate

The `keycloak-upgrade-gate` workflow (`.github/workflows/keycloak-upgrade-gate.yml`) enforces that:
- Keycloak upgrade PRs **cannot be merged** until they have the `keycloak-verified` label
- The workflow runs on PR open/update/label changes
- The job name is stable (`keycloak-upgrade-gate`) for use in branch protection

## Manual Verification Process

When a Keycloak upgrade PR is created, follow these steps:

- Review the [Keycloak Upgrade Guide](https://www.keycloak.org/docs/latest/upgrading/) for this release and note potential breaking changes.

### Step 1: Update folio-keycloak-plugins

The Keycloak plugins must be compatible with the new Keycloak version:

1. Check if [`folio-keycloak-plugins`](https://github.com/folio-org/folio-keycloak-plugins) has already been updated for this version.
2. If not, create and merge a PR in `folio-keycloak-plugins`.
3. Ensure the new plugin version is released to the FOLIO Maven repository.
4. Update this PR to use the released plugin build so the Keycloak version inside the plugin matches the base image tag.
5. Update `Dockerfile` if needed to reference the new plugin version.

### Step 2: Verify Dependent Modules

The Keycloak upgrade affects multiple FOLIO modules. Test them through `applications-poc-tools`:

1. In [`applications-poc-tools`](https://github.com/folio-org/applications-poc-tools), create a PR that:
   - Bumps the Keycloak testcontainers version to match this upgrade
   - Updates the Keycloak admin client library to the version compatible with this Keycloak release (use the admin client artifact published for this server version)

   Practical guidance:
   - Use the latest published admin client for this major line (for 26.x, use 26.0.7 as of now)
   - Watch Keycloak release notes for admin client breaking changes
   - Admin client artifacts on Maven Central: [keycloak-admin-client](https://repo1.maven.org/maven2/org/keycloak/keycloak-admin-client/)

2. Wait for the `verify-dependent-modules` workflow to complete successfully
   - This workflow tests all FOLIO modules that depend on Keycloak
   - If the workflow fails, **investigate and fix** the failures before proceeding
   - All tests must pass before proceeding

3. Merge the `applications-poc-tools` PR once verification passes

### Step 3: Environment Testing

Deploy and test the new Keycloak version in a test environment:

1. Build the Docker image from the upgrade PR branch and recreate the Keycloak environment following the FOLIO how-to: [How to deploy and test folio-kong and folio-keycloak from branch](https://folio-org.atlassian.net/wiki/spaces/FOLIJET/pages/1351254113/How+to+deploy+and+test+folio-kong+and+folio-keycloak+from+branch)
2. Deploy to a test environment (or recreate locally).
3. Run smoke tests covering:
   - Login flows: Username/password authentication and SSO
   - Token operations: Token exchange, impersonation, and refresh
   - Multi-tenancy: Create/update/delete realms and clients
   - Lightweight tokens: Verify token generation and size
   - Module authentication: Module-to-module service account flows
   - Admin operations: Realm configuration via admin API
4. Check logs for errors or deprecation warnings.
5. Verify performance and resource usage.

### Step 4: Approve and Merge

Once all verification steps are complete:

1. Add the label `keycloak-verified` to the PR
   - The `keycloak-upgrade-gate` workflow will automatically pass
2. Review the PR one final time
3. Merge the PR

## Branch Protection Setup (Maintainers)

To enforce the merge gate, repository maintainers must configure branch protection:

1. Go to repository **Settings** -> **Branches**
2. Edit the branch protection rule for `master` (or `main`)
3. Under **Require status checks to pass before merging**:
   - Enable **Require status checks to pass**
   - Add `keycloak-upgrade-gate` to the list of required status checks
4. Save the changes

This ensures that Keycloak Dependabot PRs **cannot be merged** without:
- Completing the verification runbook
- Adding the `keycloak-verified` label

## Troubleshooting

### Dependabot PR doesn't trigger the workflows

- Check that the PR modifies `Dockerfile` or `Dockerfile-fips`
- Verify that the change updates the Keycloak base image tag (`quay.io/keycloak/keycloak`)
- Ensure the PR author is `dependabot[bot]`

### Gate workflow fails even with label

- Verify the label name is exactly `keycloak-verified` (no typos)
- Check workflow logs for errors
- Re-trigger the workflow by removing and re-adding the label

### Plugin compatibility issues

- Check Keycloak release notes for breaking changes
- Review `folio-keycloak-plugins` for necessary updates
- Consider pinning to a specific plugin version temporarily

### Test failures in applications-poc-tools

- Review failed module logs for specific errors
- Check if modules need updates for Keycloak API changes
- Coordinate with module maintainers if updates are needed

## Rollback

If issues are discovered after merging:

1. Revert the Keycloak upgrade PR
2. Revert the corresponding `applications-poc-tools` PR
3. Investigate and fix the issue
4. Retry the upgrade process

## Related Documentation

- [Keycloak Release Notes](https://www.keycloak.org/docs/latest/release_notes/)
- [FOLIO Keycloak Plugins Repository](https://github.com/folio-org/folio-keycloak-plugins)
- [Main README](../README.md) - General repository information
