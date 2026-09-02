# Keycloak Upgrade Process

## Overview

Dependabot opens a pull request when a new Keycloak base image is released. Automation builds the
candidate image and verifies it against the dependent modules. A human releases the plugin,
validates a real environment, and gives the final approval.

The expected order is:

1. Review the Keycloak release notes.
2. Update, test, and release `folio-keycloak-plugins`.
3. Update the upgrade pull request to use the released plugin version.
4. Run `Verify Keycloak Upgrade Candidate` on the upgrade branch.
5. Deploy the reported candidate image manually and validate the environment.
6. Prepare the compatibility and release documentation.
7. Add `keycloak-verified` and merge.

Do not merge or release `folio-keycloak` before this process is complete.

## How the automation works

Four workflows take part. All of them live in `.github/workflows/`.

| Workflow | Runs when | What it does |
| --- | --- | --- |
| `keycloak-upgrade-instructions.yml` | Dependabot opens or updates a pull request that touches `Dockerfile` or `Dockerfile-fips` | Posts the runbook checklist comment. The comment is written once, so later pull request updates keep the boxes you have ticked. |
| `verify-keycloak-upgrade.yml` | A person starts it by hand on the upgrade branch | Builds and publishes the candidate image, then verifies the dependent modules against it. Reports the result in one comment and in a `keycloak-upgrade-verification` commit status. |
| `keycloak-upgrade-gate.yml` | Every pull request event, including label changes | Blocks the merge of a Keycloak upgrade until the current commit is verified and the pull request carries `keycloak-verified`. |
| `keycloak-upgrade-reset-approval.yml` | A new commit arrives on a pull request that carries `keycloak-verified` | Removes that label. The final approval therefore always applies to the final state of the pull request. |

### What the candidate workflow does

- It finds the open pull request for the branch it runs on. It fails when there is none.
- It checks that `Dockerfile` and `Dockerfile-fips` agree on one Keycloak version and one released
  plugin version.
- It builds `Dockerfile-fips` but never publishes it. A broken FIPS build therefore fails before
  anything is pushed. Only the standard image is published.
- It publishes the standard image as
  `folioci/folio-keycloak:<major>.<minor + 1>.0-SNAPSHOT.pr<number>.<short sha>`, never as `latest`,
  and records its immutable digest.
- It starts `verify-dependent-modules.yml` in `applications-poc-tools` with that digest, using the
  `folio-keycloak-upgrade-bot` GitHub App, and waits for the result.
- It writes one **Keycloak Upgrade Candidate** comment on the pull request, and a
  `keycloak-upgrade-verification` commit status on the commit it built.

The candidate tag contains the pull request number and the commit. A rerun for the same commit finds
the published image, skips the build, and repeats only the dependent-module verification. The image
you test by hand is therefore the same image the verification passed on. A new commit always
produces a new candidate image.

The comment always shows the latest attempt, so a later failed run replaces a successful report.
The tag of a successful run stays in the job summary of that run.

### Who can run it, and what limits apply

- You need write access to this repository. Without it, GitHub does not show the **Run workflow**
  button at all.
- Only one candidate verification runs at a time, because `applications-poc-tools` also accepts one
  dispatched run at a time. A second run waits for the first one. This looks like a hang, but it is
  not.
- The job stops after 90 minutes. The wait for the dependent modules stops after 45 minutes.
- Candidate tags are never deleted automatically. They stay in `folioci/folio-keycloak`.

### What stays manual, and why

- **The plugin release.** The candidate image installs a released plugin artifact, never a local or
  SNAPSHOT build.
- **Environment validation.** No CI job covers login, SSO, token, realm, or module authentication
  flows against a real deployment.
- **The `keycloak-verified` label.** It is the final human approval. Automation must never add it.

## Upgrade Runbook

### Step 1: Review the Keycloak release

Read the [Keycloak upgrading guide](https://www.keycloak.org/docs/latest/upgrading/) and
[release notes](https://www.keycloak.org/docs/latest/release_notes/) for the target version. Record
relevant breaking changes, migration requirements, and manual checks on the upgrade pull request.

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
6. In the Keycloak upgrade pull request, update `FOLIO_KEYCLOAK_PLUGIN_VERSION` in both `Dockerfile`
   and `Dockerfile-fips` to that released version.

If later candidate verification finds a plugin defect, fix it, release a new plugin version, and
update the Keycloak pull request. The new commit produces a new candidate image; the previous
candidate stays untouched in the registry.

### Step 3: Build and verify the candidate

Start this step only after the released plugin version is committed to the upgrade pull request.

Open the **Actions** tab, select **Verify Keycloak Upgrade Candidate**, press **Run workflow**, and
choose the upgrade pull request branch. The checklist comment on the pull request carries the same
instructions.

When the run finishes:

- All dependent-module jobs must pass.
- Read the **Keycloak Upgrade Candidate** comment. The tag it reports is the reference to use for
  manual testing. Do not substitute `latest`, and do not rebuild the image through `do-docker.yml`.
- Check whether a newer `keycloak-admin-client` release exists for this Keycloak major version on
  [Maven Central](https://mvnrepository.com/artifact/org.keycloak/keycloak-admin-client), and
  update `applications-poc-tools` to it if so.

Run the workflow again after any commit that affects the image. Changes limited to `README.md`,
`NEWS.md`, or `docs/` do not need another run. If you need a genuinely fresh build of the same
commit, delete the candidate tag from Docker Hub and rerun. The job summary of the run that built
the image prints that tag.

### Step 4: Test the candidate environment manually

Use the exact candidate tag from the pull request comment to recreate the test environment. Follow
[How to deploy and test folio-kong and folio-keycloak from branch](https://folio-org.atlassian.net/wiki/spaces/FOLIJET/pages/1351254113/How+to+deploy+and+test+folio-kong+and+folio-keycloak+from+branch),
substituting the candidate image where the process accepts an image reference.

Validate the behavior required for the release, including applicable login, SSO, token, tenant,
realm, client, and module-authentication flows. Check Keycloak logs for errors and relevant
deprecation warnings. Record the environment and evidence on the upgrade pull request.

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
3. Review the final diff and merge the upgrade pull request.

The normal tag-based Docker release remains separate from candidate verification.

## Troubleshooting

### Candidate workflow is not visible

`workflow_dispatch` workflows must exist on the default branch, and the branch selected in **Use
workflow from** must carry the workflow file as well. Merge the workflow change first. If the
upgrade branch was created before that merge, comment `@dependabot recreate` on the pull request so
the branch picks the workflow up. Note that `@dependabot rebase` is refused once a pull request
carries manual commits, and that `recreate` discards manual edits, so redo the plugin version commit
afterwards.

### Candidate build cannot download plugins

Confirm that `FOLIO_KEYCLOAK_PLUGIN_VERSION` is identical in both Dockerfiles and that both plugin
JARs exist in the FOLIO Maven release repository. The workflow does not consume locally built or
SNAPSHOT plugin JARs.

### Dependent-module verification fails

Open the dependent-module run linked in the **Keycloak Upgrade Candidate** comment, then use its
module job links. Fix the owning module or plugin as appropriate. After changing an image input,
release the required plugin version, update the Keycloak pull request, and run a new candidate
verification. If another run in `applications-poc-tools` cancels this verification, rerun it for the
same pull request commit; the published candidate image will be reused.

### Gate fails after verification

Check that the successful candidate run used the current pull request commit, or that later changes
are limited to `README.md`, `NEWS.md`, or `docs/`. Any other later commit requires a new candidate
run. Two further cases produce a red gate that the comment alone does not explain:

- The gate does not re-run when a commit status arrives. It runs on pull request events only. If you
  verified the candidate after the label was already added, re-run the gate check or toggle the
  label.
- After a `@dependabot recreate` force-push, the verified commit is no longer an ancestor of the
  branch, so the documentation-only exception cannot apply. Run a new candidate verification.

Candidate verification never adds `keycloak-verified`. Add it only after manual environment
validation and the remaining runbook steps are complete.

## Rollback

If a problem is discovered after merge, revert the Keycloak upgrade and restore the last released
Keycloak and plugin versions. Candidate images are verification artifacts and must not be treated as
release tags.

## Related Documentation

- [FOLIO Keycloak Plugins](https://github.com/folio-org/folio-keycloak-plugins)
- [applications-poc-tools](https://github.com/folio-org/applications-poc-tools)
- [Repository README](../README.md)
