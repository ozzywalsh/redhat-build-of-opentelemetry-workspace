# SAST Triage Report: RHOSDT ${PRODUCT} ${VERSION}

**Date:** YYYY-MM-DD
**Baseline:** ${BASELINE_VERSION} (or "none")
**Scanner:** Snyk Code via Konflux sast-snyk-check
**Component analyzed:** ${component_analyzed}
**Note:** All ${component_count} component images scan the same source repo and produce identical findings; one was processed. Counts below are deduplicated findings (raw SARIF results: ${raw_results}).

## Summary

| Category | Count |
|----------|-------|
| Unique findings (raw SARIF results) | N (N) |
| Snyk test-flagged | N |
| Test file paths | N |
| Vendored upstream (`.obi-src`, `vendor/`) | N |
| jaeger-ui frontend (tempo only) | N |
| Examples/demo | N |
| Build tooling | N |
| **Require human review** | **N** |
| New since ${BASELINE} | N |

## Findings Requiring Human Review

### [WARNING] <ruleId> — <uri>:<line>

**Status:** New / Existing since <version>
**Snyk rule:** <message>
**Source:** <uri>:<line>

<one-paragraph assessment: what the finding is, why it survived filtering, and your preliminary judgment (likely real / likely noise with explanation)>

---

### [NOTE] <ruleId> — <uri>:<line>
...

Group warnings first, then notes.

## New Findings Since ${BASELINE}

<List findings with new fingerprints, even if filtered as noise — gives the
reviewer visibility into what changed. The script output lists them in
`new_since_baseline.new_noise` as "filter: uri (ruleId)"; summarize by
category and call out anything unusual.>

## Noise Summary

| Filter | Findings caught |
|--------|----------------|
| Snyk test-flagged | N |
| Test file paths | N |
| Vendored upstream | N |
| jaeger-ui frontend | N |
| Examples/demo | N |
| Build tooling | N |

## Other Scanners

- **Unicode check:** N findings
- **ShellCheck:** N findings (<rules and summary>)
- **Coverity:** N findings — N test-YAML noise, N require review / not present
- **ClamAV:** N scans, all clean / <problems from the script output>

## Recommendation

<One of:>
- **PASS** — no findings require action. All N findings are noise.
- **REVIEW** — N finding(s) require human judgment. See "Findings Requiring Human Review" above.
- **FLAG** — N finding(s) appear to be real issues that need remediation before release.
