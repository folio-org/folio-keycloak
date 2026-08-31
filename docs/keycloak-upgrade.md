# Keycloak Upgrade Process

## Overview

Dependabot creates a pull request when the Keycloak base image changes. The upgrade keeps the
plugin release and environment validation as deliberate manual steps, while candidate-image creation
and dependent-module verification run as one workflow from `folio-keycloak`.

The expected order is:

1. Review the Keycloak release notes.
2. Update, test, and release `folio-keycloak-plugins`.
3. Update the upgrade PR to use the released plugin version.
4. Run `Verify Keycloak Upgrade Candidate` on the upgrade branch.
5. Deploy the reported candidate image manually and validate the environment.
6. Prepare the compatibility and release documentation.
7. Add `keycloak-verified` and merge.

Do not merge or release `folio-keycloak` before this process is complete.

## Automation

### Dependabot and upgrade instructions

Dependabot monitors `quay.io/keycloak/keycloak` weekly, updates `Dockerfile` and
`Dockerfile-fips`, and adds the `keycloak-upgrade` label. The
`keycloak-upgrade-instructions` workflow creates the checklist comment on the pull request. Later
PR updates do not replace it, so checked items stay checked.

### Candidate build and dependent-module verification

The `Verify Keycloak Upgrade Candidate` workflow is dispatched manually on the upgrade branch and:

- finds the open pull request for that branch, and fails when there is none;
- validates that `Dockerfile` and `Dockerfile-fips` agree on one Keycloak version and one released
  plugin version;
- builds `Dockerfile-fips` without publishing it, so a broken FIPS build fails before anything is
  pushed;
- pushes the standard image as `folioci/folio-keycloak:X.Y.Z-SNAPSHOT.pr<number>.<short sha>`,
  never `latest`, and records its immutable digest;
- uses the `folio-keycloak-upgrade-bot` GitHub App to start `verify-dependent-modules.yml` in
  `applications-poc-tools` with that digest;
- updates a latest-attempt comment with the overall result and workflow links;
- after success, updates a separate successful-candidate comment with the immutable image reference.

The candidate tag is derived from the pull request number and the built commit. A rerun for the same
commit finds the published image, skips the build, and repeats only the dependent-module
verification, so the image an engineer tested manually stays identical to the image the verification
passed on. A new commit always produces a new candidate.

### Merge gate

The `keycloak-upgrade-gate` workflow prevents a Keycloak upgrade PR from merging until the current
PR commit has a successful candidate verification and the PR has the `keycloak-verified` label.
The label is the final human approval; automation must not add it. A new image-affecting commit
invalidates the previous verification. Later changes limited to `README.md`, `NEWS.md`, or `docs/`
keep the verified candidate valid and do not trigger an unnecessary rebuild.
Any new commit removes an existing `keycloak-verified` label, so the final human approval always
applies to the final PR state.

## Upgrade Runbook

### Step 1: Review the Keycloak release

Read the [Keycloak upgrading guide](https://www.keycloak.org/docs/latest/upgrading/) and
[release notes](https://www.keycloak.org/docs/latest/release_notes/) for the target version. Record
relevant breaking changes, migration requirements, and manual checks on the upgrade PR.

### Step 2: Update and release folio-keycloak-plugins

The candidate image deliberately uses a released plugin artifact. Complete this step before
building the candidate:

1. In [`folio-keycloak-plugins`](https://github.com/folio-org/folio-keycloak-plugins), set
   `keycloak.version` to the Maven artifact version corresponding to the target Keycloak server.
   The container tag may contain a packaging suffix, while the Maven version may not; verify the
   published Keycloak artifacts instead of copying the container tag blindly.
2. Run the plugin build and tests:

   ```bash
   mvn clean verify
   ```

3. Fix any compilation or test failures before release.
4. Merge and release the plugin through its normal release process.
5. Confirm that both plugin JARs are available from the FOLIO Maven release repository.
6. In the Keycloak upgrade PR, update `FOLIO_KEYCLOAK_PLUGIN_VERSION` in both `Dockerfile` and
   `Dockerfile-fips` to that released version.

If later candidate verification finds a plugin defect, fix it, release a new plugin version, and
update the Keycloak PR. The new commit produces a new candidate image; the previous candidate stays
untouched in the registry.

### Step 3: Build and verify the candidate

After the released plugin version is committed to the upgrade PR:

1. Open **Actions** in `folio-org/folio-keycloak`.
2. Select **Verify Keycloak Upgrade Candidate**.
3. Choose **Run workflow**, select the upgrade PR branch in **Use workflow from**, and run it.
4. Wait for the workflow to build the image and complete the dependent-module workflow.
5. Read the **Keycloak Upgrade Candidate Verification** comment on the upgrade PR.
6. Check whether a newer `keycloak-admin-client` release exists for this Keycloak major version on
   [Maven Central](https://mvnrepository.com/artifact/org.keycloak/keycloak-admin-client), and
   update `applications-poc-tools` to it if so.

The workflow builds the branch it was dispatched on and finds the open pull request for that branch
itself. A branch created before this workflow reached the default branch does not carry the workflow
file yet; comment `@dependabot rebase` on the PR to refresh it.

All dependent-module jobs must pass. The successful-candidate comment is the source of truth for the
immutable image reference to use in later manual testing. Do not substitute `latest` or rebuild the
image through `do-docker.yml`.

Rerun the workflow after any image-affecting PR commit. The candidate tag is derived from the PR
number and the commit, so a new commit always produces a new candidate image, while a rerun for the
same commit reuses the published one and only repeats the dependent-module verification. That keeps
the image an engineer tested manually identical to the image the verification passed on. If a
genuinely fresh build of the same commit is needed, delete the candidate tag from Docker Hub and
rerun. Documentation-only changes in `README.md`, `NEWS.md`, or `docs/` do not require another run.
A failed run does not replace the last successful candidate comment, so the PR never presents a
failed image as the verified candidate; its latest-attempt comment records the failure.

### Step 4: Test the candidate environment manually

Use the exact immutable candidate reference (`repository@sha256:...`) from the PR comment to recreate the
test environment. Follow
[How to deploy and test folio-kong and folio-keycloak from branch](https://folio-org.atlassian.net/wiki/spaces/FOLIJET/pages/1351254113/How+to+deploy+and+test+folio-kong+and+folio-keycloak+from+branch),
substituting the candidate image where the process accepts an image reference.

Validate the behavior required for the release, including applicable login, SSO, token, tenant,
realm, client, and module-authentication flows. Check Keycloak logs for errors and relevant
deprecation warnings. Record the environment and evidence on the upgrade PR.

Environment deployment and these checks are intentionally not performed by the candidate workflow.

### Step 5: Update documentation

After manual validation, with the tested Keycloak and plugin versions confirmed:

1. Update `NEWS.md` with the Keycloak and plugin versions and any relevant behavior changes.
2. Update the compatibility table in `README.md` when the supported FOLIO release range changes.
3. Record any discovered incompatibilities rather than leaving the compatibility cell ambiguous.

These commits change no image content, so they do not require another candidate run. Commit them
before adding `keycloak-verified`: every new commit removes that label.

### Step 6: Approve and merge

When the released plugin, candidate verification, dependent modules, manual environment validation,
and documentation are complete:

1. Add the `keycloak-verified` label.
2. Confirm that `keycloak-upgrade-gate` passes.
3. Review the final diff and merge the upgrade PR.

The normal tag-based Docker release remains separate from candidate verification.

## Troubleshooting

### Candidate workflow is not visible

`workflow_dispatch` workflows must exist on the default branch, and the branch selected in **Use
workflow from** must carry the workflow file as well. Merge the workflow change first. If the
upgrade branch was created before that merge, comment `@dependabot rebase` on the pull request so
the branch picks the workflow up.

### Candidate build cannot download plugins

Confirm that `FOLIO_KEYCLOAK_PLUGIN_VERSION` is identical in both Dockerfiles and that both plugin
JARs exist in the FOLIO Maven release repository. The workflow does not consume locally built or
SNAPSHOT plugin JARs.

### Dependent-module verification fails

Open the dependent-module workflow link in the verification comment, then use its module job links.
Fix the owning module or plugin as appropriate. After changing an image input, release the required
plugin version, update the Keycloak PR, and run a new candidate verification. If another run in
`applications-poc-tools` cancels this verification, rerun it for the same PR commit; the published
candidate digest will be reused.

### Gate fails after verification

Check that the successful candidate run used the current PR commit, or that later changes are limited
to `README.md`, `NEWS.md`, or `docs/`. Any other later commit requires a new candidate run. If the
latest attempt failed, rerun it successfully; the previous image comment remains visible but its
failure status blocks the gate. Candidate verification does not add `keycloak-verified`; add it only
after manual environment validation and the remaining runbook steps are complete.

## Rollback

If a problem is discovered after merge, revert the Keycloak upgrade and restore the last released
Keycloak and plugin versions. Candidate images are verification artifacts and must not be treated as
release tags.

## Related Documentation

- [FOLIO Keycloak Plugins](https://github.com/folio-org/folio-keycloak-plugins)
- [applications-poc-tools](https://github.com/folio-org/applications-poc-tools)
- [Repository README](../README.md)
