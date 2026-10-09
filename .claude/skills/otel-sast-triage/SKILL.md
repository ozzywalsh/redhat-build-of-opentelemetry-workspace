---
name: otel-sast-triage
description: >
  Use when a Red Hat build of OpenTelemetry (RHOSDT) release has SAST reports
  to review — Snyk SARIF findings from the Konflux pipeline, a release-testing
  task that asks for SAST analysis, or a comparison of SAST findings between
  two releases.
argument-hint: "3.11.0 [--baseline 3.10.2] [--product otel|tempo]"
---

# SAST Triage

Reduce ~100 raw Snyk findings per release to the few that need human eyes.

All mechanical work — locating the report, deduplicating findings, classifying
noise, diffing against a baseline, collecting other scanners — is done by
`scripts/triage-sarif.sh`. Do not re-implement it with ad-hoc jq or grep: the
script's filter list is versioned so every run classifies the same way and
counts stay comparable across releases. Your job is the judgment on what
survives the filters.

## When to Use This Skill

- A new RHOSDT release has SAST reports to review
- A release-testing task includes a SAST analysis step
- SAST findings must be compared between two releases

## Usage

```
/otel-sast-triage 3.11.0
/otel-sast-triage 3.11.0 --baseline 3.10.2
/otel-sast-triage 3.11.0 --product tempo
```

## Arguments

- **Version** (positional, required) — release version to triage (e.g. `3.11.0`)
- **`--baseline`** — previous release version. If omitted, the script uses the
  most recent prior version for the same product.
- **`--product`** — `otel` (default) or `tempo`

## Prerequisites

SARIF reports must already exist in `konflux/sast-report/`. They are generated
by the `snapshot-security-analyzer` tool against a Konflux snapshot. If the
directory for the requested version doesn't exist, tell the user to run
`snapshot-security-analyzer` first.

## Workflow

### Step 1: Run the script

```bash
bash .claude/skills/otel-sast-triage/scripts/triage-sarif.sh VERSION \
  [--product otel|tempo] [--baseline VERSION] > /tmp/sast-triage.json
```

The script prints one JSON object: deduplicated findings, per-filter noise
counts, findings requiring review, the baseline diff, and the other scanners'
results (unicode, shellcheck, coverity, ClamAV).

If the script exits with an error, report it verbatim and stop. Do not work
around it by hand-parsing the SARIF.

### Step 2: Assess the surviving findings

For each finding in `snyk.require_review`:

1. **Read the source code** at `uri`:`line` to understand the context.
2. **Check severity** — `warning` and `error` levels are higher priority than `note`.
3. **Assess reachability** — is this code in a shipped binary? Is the flagged
   pattern exploitable in context?
4. **Write a one-paragraph assessment** — what the finding is, why it survived
   filtering, and your preliminary judgment: likely real, or likely noise with
   the explanation.

Also sanity-check the diff: if `new_since_baseline.total` jumps compared to the
previous release, look at `new_since_baseline.new_noise` to see which category
drove it — a new top-level source directory may need a new filter pattern in
the script (add it there, in a PR, not ad hoc).

### Step 3: Write the report

Write to `reports/sast/${VERSION}-${PRODUCT}-sast-triage.md` using
[report-template.md](report-template.md). Fill every field from the script's
JSON output and your Step 2 assessments.

### Step 4: Present results

```
SAST Triage Complete: RHOSDT ${PRODUCT} ${VERSION}

Total: N unique findings (N raw) → N require review (N new since ${BASELINE})
Recommendation: PASS / REVIEW / FLAG

Report: reports/sast/${VERSION}-${PRODUCT}-sast-triage.md

<if REVIEW or FLAG, list the specific findings that need attention>
```

## Classification Reference

The script's filters, in order (first match wins):

| Filter | Catches |
|--------|---------|
| Snyk test-flagged | ruleId ending in `/test]` — Snyk itself marked it test code |
| Test file paths | `_test.go`, `test*/`, `testdata/`, `e2e*`, `testenv/`, `mocks?/` as path segments |
| Vendored upstream | `.obi-src/` (otel) and `vendor/` (tempo) trees — upstream code, not ours to fix |
| jaeger-ui frontend | `jaeger-ui/` — frontend code (tempo only) |
| Examples/demo | `examples?/`, `demo`, `sample?/` paths |
| Build tooling | `scripts/`, `tools/`, tooling `cmd/` dirs, `ci-analysis/`, `snapshot-tool` |

Shipped `cmd/` directories (e.g. `cmd/operator-opamp-bridge`) are **not**
filtered — only the tooling ones enumerated in the script.

These categories were derived from reports for versions 3.6 through 3.11. The
noise profile is stable: the same categories recur each release.

**Patterns to watch for drift:**
- New top-level directories in the source tree that match no filter — add a
  pattern to the script and mention it in the PR
- Coverity findings outside of test YAML — historically 100% test noise, but
  Coverity has higher precision; any non-test finding is likely real
- Warning-level findings anywhere — they deserve the benefit of the doubt

**Known stable noise (appears every release):**
- `scripts/snapshot-tool.py` — reDOS in a Python regex (build script, not shipped)
- `opentelemetry-operator/internal/testenv/testenv.go` — TLS skip in a test
  helper; caught by the `testenv/` path filter
