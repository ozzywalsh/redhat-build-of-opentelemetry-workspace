# Release

ART auto-releases component images to stage registry (not FBC fragments).
However, the production release process runs the stage release again to ensure all Konflux checks still pass.

The release is documented in https://art-docs.engineering.redhat.com/konflux/self-service-fbc-release/
and requires running Tekton pipelines: `release-from-fbc` and `trigger-prod-release`.

The pipelines can be run from:
* [ARC OpenShift](https://console-openshift-console.apps.artc2023.pc3z.p1.openshiftapps.com/k8s/ns/art-rhosdt-tenant/tekton.dev~v1~Pipeline)
* [ART pipelines](https://art-pipelines-ui-art-pipelines-ui.apps.artc2023.pc3z.p1.openshiftapps.com/#/pipelines). This UI allows customizing parameters for rerun.


## Automated release

The recommended way of releasing is via our Gitlab automation in [art-opentelemetry](https://gitlab.cee.redhat.com/distributed-tracing/art-opentelemetry).
The repository contains a Gitlab pipeline which performs all the release steps below.

The release pipeline runs weekly, but it can be executed on-demand when needed.

## Manual release

### Release checks

#### Patch and CVE fix release (same `rhosdt-<version>` branch)

The Konflux integration tests must pass on the FBC builds to release. They run in the application `fbc-rhosdt-<art version with dashes>` of `art-rhosdt-tenant` (scenarios in `konflux-release-data`, pipelines in `distributed-tracing-qe`).

```bash
./get-fbc-images.sh 0.158 > fbc-images.yaml
./check-its.sh "$(sed -n "s/^pullspecs: *'\(.*\)'$/\1/p" fbc-images.yaml)" > its.yaml
```

By default this lists the latest FBC builds. To get FBCs of a specific commit, pass the upstream source commit SHA from `openshift/open-telemetry-opentelemetry-operator` as the second argument:

```bash
./get-fbc-images.sh 0.158 <commit-sha> > fbc-images.yaml
```

To run a scenario again, label its Snapshot: `oc label --overwrite -n art-rhosdt-tenant snapshot <name> test.appstudio.openshift.io/run=<scenario>`. How to read a failed run: "Operating the scenarios" in `/otel-qe-prepare-ci` (`references/konflux-its.md`).

The critical e2e tests (the `e2e-pre-merge` job) already ran on every pull request to the branch. CVE and bug fixes are verified on their issues with `/otel-qe-verify-fixes` when asked.

#### Major or minor release (a new `rhosdt-<version>` branch and ART group)

The checks of a patch release, and the checklist of `/otel-qe-release-testing` with the version (e.g. `0.159`).

### Run `release-from-fbc` pipeline
Create the [pipeline CR](./release-from-fbc.yaml) or via [UI](https://console-openshift-console.apps.artc2023.pc3z.p1.openshiftapps.com/k8s/ns/art-rhosdt-tenant/tekton.dev~v1~Pipeline/release-from-fbc), replacing:
* `<GROUP>` — e.g. `rhosdt-0.158` (the ocp-build-data group branch)
* `<ASSEMBLY_VERSION>` — e.g. `0.158.0`
* `<FBC_PULLSPECS>` — comma-separated FBC pullspecs from [get-fbc-images.sh](./get-fbc-images.sh)
* `jira-bugs` — comma-separated list of JIRA issue IDs to include in the advisory. CVE trackers need correct component label e.g. `pscomponent:rhosdt/opentelemetry-rhel9-operator`
* `force` — the template sets `false`. Set to `true` to override the existing shipment merge request.
* `dry-run` — the template sets `true`. Set to `false` to actually create the shipment MR.

The pipeline creates a shipment merge request in [hybrid-platforms/art/ocp-shipment-data](https://gitlab.cee.redhat.com/hybrid-platforms/art/ocp-shipment-data/) (e.g. https://gitlab.cee.redhat.com/hybrid-platforms/art/ocp-shipment-data/-/merge_requests/973), and triggers a GitLab CI pipeline on the MR. The pipeline releases the images to stage again to make sure Conforma checks pass.

Review the MR (e.g. the release notes), approve it and wait until the Gitlab `release-stage` pipeline completes. Restart the individual jobs in case of failure.

### Run `trigger-prod-release` pipeline
Once the shipment merge request has label `stage-release-succes`. The release to production registry can be triggered.

Run `trigger-prod-release` pipeline to continue the release to production registry.
The pipeline takes argument the merge request from the previous step to [hybrid-platforms/art/ocp-shipment-data](https://gitlab.cee.redhat.com/hybrid-platforms/art/ocp-shipment-data/).

Create the [pipeline CR](./trigger-prod-release.yaml), replacing:
* `<MR_IID>` — the merge request ID from the previous step (e.g. `742`)
* `dry-run` — `true` (default). Set to `false` to actually trigger the prod release.

The pipeline enables release to production registry on Gitlab MR pipeline. If the Gitlab MR pipeline fails (or partly fails) just rerun the `trigger-prod-release`
and the unreleased FBCs will rerun.

## Prepare for next release

### Patch release
No changes in the bundle/`CSV` or ART configuration files are required.

### Major or minor version (a new `rhosdt-<version>` branch)
Every new major or minor operator version gets a new `rhosdt-<version>` branch and a new ART group; patch and CVE fix releases stay on the branch.

1. Request new branches in `ocp-build-data` from the ART team by posting in slack channel #forum-ocp-art. Once the new rhosdt-<version> branch exists, the art-side bootstrapping can then be handled by chai-bot. Start a thread in #forum-ocp-art mentioning chai-bot like this:

   ```
   @chai-bot We need to bootstrap rhosdt-<version>. We already have rhosdt-<version> branch in ocp-build-data and the OTEL team is working on submitting necessary changes there. What all needs to be done (and in what order) to complete the full bootstrap process for rhosdt-<version>?
   ```

   An example of a previous thread: https://redhat-internal.slack.com/archives/CB95J6R4N/p1794327377470239

2. Update version in `ocp-build-data` in `group.yml` on the `rhosdt-<version>` branch (only for a new major or minor version).

3. Create downstream branches — see detailed instructions per repository below.

4. Update versions in the ART configuration files: `bundle/opentelemetry-product.package.yaml` and `bundle/art.yaml`.

5. Update the CI with the `/otel-qe-prepare-ci` skill: move or copy the pre-merge CI config of the operator and of the collector in `release` to the new branch (copy while the previous version still has CVE or patch releases), carry over the changes of the upstream CI jobs, and move or copy the Konflux integration test scenarios to the new ART group. A patch or CVE fix release needs no change in either place.

6. Configure mintmaker on new branches in `konflux-release-data`.

#### Creating downstream branches

Each downstream source repository (`open-telemetry-opentelemetry-operator` and `redhat-opentelemetry-collector`) gets a `rhosdt-<version>` branch. The two repos follow different workflows because they have different relationships with upstream.

##### Operator (`open-telemetry-opentelemetry-operator`)

The downstream `main` is continuously synced with upstream `main` by a rebase bot. This means `main` usually contains commits *past* the upstream release tag. **Do not branch from downstream `main`** — that would include post-release upstream code belonging to the next version.

Instead, branch from the **upstream release tag** and add the downstream-only files on top:

```bash
# In the open-telemetry-opentelemetry-operator clone
git fetch upstream v0.<version>.0 --tags
git checkout -b rhosdt-0.<version> v0.<version>.0
```

Then copy the following files from the previous `rhosdt-*` branch. These files do not exist upstream.

**Productization files** (must be present for ART to build):

| File | Purpose | Version-sensitive fields to update |
|------|---------|-----------------------------------|
| `Dockerfile.art` | Operator image build | `FROM` lines (ART rewrites these, but count and order must match `ocp-build-data` image config) |
| `Dockerfile.ta.art` | Target Allocator image build | Same as above |
| `bundle/art.yaml` | Downstream CSV and annotation edits | `currentCSV` version, `olm.skipRange` |
| `bundle/image-references` | Images whose pullspecs ART replaces in the CSV | Usually unchanged |
| `bundle/opentelemetry-product.package.yaml` | Package name, channel, current CSV | `currentCSV` version |
| `fips-allowlist.yaml` | Reviewed non-FIPS crypto import chains | Review and update — new dependencies may introduce new chains |
| `OWNERS` | Downstream repo approvers | Usually unchanged |
| `renovate.json` | Downstream Renovate preset (security-only updates) | Usually unchanged |

**Downstream-only content** (review each release):

| File(s) | Purpose | Action each release |
|---------|---------|-------------------|
| `bundle/openshift/manifests/opentelemetry-operator-alerts_*_prometheusrule.yaml` | Downstream-only deprecation/operational alerts | Review: update or remove alerts for components being deprecated or removed in this version |
| `.gitignore` additions | Ignore patterns for downstream test artifacts (e.g. Playwright) | Carry forward from previous branch |

**Test preparation** — use the `/otel-qe-prepare-operator-tests` skill:

Tests are copied from `distributed-tracing-qe` `main`, **not** from the previous `rhosdt-*` branch. The QE repo is the authoritative source and contains tests for new components that the previous branch does not have. The skill copies `tests/e2e-otel/` and `tests/e2e-otel-ui/`, removes hardcoded community collector images so the operator injects its product image, and removes `ingress-ready` nodeAffinity from target allocator tests. Run the skill's verification checks before pushing.

**Cherry-picked upstream fixes** (check each release — they may already be in the new tag):

Previous branches may contain cherry-picks of upstream bug fixes that landed after the previous release tag. Before carrying them forward, check whether the fix is already in the new upstream tag:

```bash
# In the upstream opentelemetry-operator clone
git merge-base --is-ancestor <cherry-pick-commit> v0.<version>.0 && echo "already included"
```

If the fix is already in the new tag, do not carry it forward. If it is not, cherry-pick it onto the new branch.

##### Collector (`redhat-opentelemetry-collector`)

The collector repo is not synced by a rebase bot. Upstream collector versions are bumped manually on `main` via `manifest.yaml` and `Makefile`. The workflow is:

1. Bump the collector version on `main` first (update `manifest.yaml`, `Makefile`, rebuild).
2. Branch `rhosdt-0.<version>` from `main` after the bump commit.

The productization files (`Dockerfile.art`, `fips-allowlist.yaml`, `renovate.json`) are already on `main`. See the collector's `AGENTS.md` for the version bump procedure.
