#!/usr/bin/env bash
# Deterministic triage of Konflux SAST reports for RHOSDT releases.
#
# Resolves the report directory for a release, deduplicates Snyk findings by
# csdiff/v0 fingerprint, classifies noise with anchored path/rule filters,
# diffs fingerprints against a baseline release, and collects the other
# scanners' results (unicode check, shellcheck, coverity, ClamAV). Prints one
# JSON object to stdout.
#
# Usage:
#   triage-sarif.sh VERSION [--product otel|tempo] [--baseline VERSION] [--root DIR]
#
#   VERSION          release version to triage (e.g. 3.11.0)
#   --product        otel (default) or tempo
#   --baseline       baseline version for the cross-release diff; if omitted,
#                    the most recent prior version for the same product is used
#   --root           report root (default: konflux/sast-report)
#
# Exit codes: 0 success, 2 usage or report-resolution errors.
#
# The filter list is versioned in this script on purpose: every run
# classifies with the same rules, so counts are comparable across releases.
# When a new noise category appears, add a pattern here and mention it in the
# PR — do not improvise filters ad hoc per run.

set -euo pipefail

for tool in jq find grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: '$tool' is required but not found in PATH" >&2; exit 2; }
done

VERSION=""
PRODUCT="otel"
BASELINE=""
ROOT="konflux/sast-report"

usage() {
  sed -n '/^# Usage:/,/^# *$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product)  [[ $# -ge 2 ]] || usage; PRODUCT="$2"; shift 2 ;;
    --baseline) [[ $# -ge 2 ]] || usage; BASELINE="$2"; shift 2 ;;
    --root)     [[ $# -ge 2 ]] || usage; ROOT="$2"; shift 2 ;;
    -h|--help)  usage ;;
    -*)         echo "FAIL: unknown option: $1" >&2; usage ;;
    *)
      [[ -z "$VERSION" ]] || { echo "FAIL: unexpected argument: $1" >&2; usage; }
      VERSION="$1"; shift ;;
  esac
done
[[ -n "$VERSION" ]] || usage
[[ -d "$ROOT" ]] || { echo "FAIL: report root not found: $ROOT" >&2; exit 2; }

# Resolve "<version>-<product>-main*" to exactly one report directory.
# The trailing ($|-) keeps versions distinct: "3.6" will not match "3.6.1-...".
resolve_dir() {
  local v="$1" matches
  matches=$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | grep -E "^${v}-${PRODUCT}-main(\$|-)" | sort || true)
  if [[ -z "$matches" ]]; then
    echo "FAIL: no report directory for ${PRODUCT} ${v} under ${ROOT} (expected <version>-${PRODUCT}-main*)" >&2
    exit 2
  fi
  if [[ "$(wc -l <<<"$matches")" -ne 1 ]]; then
    echo "FAIL: ambiguous report directories for ${PRODUCT} ${v}:" >&2
    sed 's/^/  /' <<<"$matches" >&2
    exit 2
  fi
  echo "${ROOT}/$(head -1 <<<"$matches")"
}

# Highest version for this product strictly below $VERSION, empty if none.
# sort -V orders 3.9.0 < 3.10.0 < 3.10.2 correctly where a plain sort would not.
detect_baseline() {
  local c best="" top
  for c in $(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | grep -E "^[0-9][0-9.]*-${PRODUCT}-main(\$|-)" \
    | grep -oE '^[0-9][0-9.]*' | sort -Vu); do
    [[ "$c" == "$VERSION" ]] && continue
    top=$(printf '%s\n%s\n' "$c" "$VERSION" | sort -V | tail -1)
    [[ "$top" == "$VERSION" ]] && best="$c"
  done
  echo "$best"
}

REPORT_DIR=$(resolve_dir "$VERSION")

BASELINE_VERSION="$BASELINE"
[[ -n "$BASELINE_VERSION" ]] || BASELINE_VERSION=$(detect_baseline)
BASELINE_DIR=""
if [[ -n "$BASELINE_VERSION" ]]; then
  BASELINE_DIR=$(resolve_dir "$BASELINE_VERSION")
fi

# Pick one component's Snyk SARIF. All components in a report scan the same
# source repo and produce identical findings; sorting makes the pick stable.
mapfile -t SARIFS < <(ls "$REPORT_DIR"/attachments/*/sast_snyk_check_out.sarif 2>/dev/null | sort)
[[ ${#SARIFS[@]} -gt 0 ]] || { echo "FAIL: no sast_snyk_check_out.sarif under $REPORT_DIR/attachments/" >&2; exit 2; }
SARIF="${SARIFS[0]}"
COMPONENT_DIR=$(dirname "$SARIF")
COMPONENT=$(basename "$COMPONENT_DIR" | sed -E 's/^quay\.io_redhat-user-workloads_//; s/_sha256_[0-9a-f]+$//; s/_/\//g')
COMPONENT_COUNT=$(find "$REPORT_DIR/attachments" -mindepth 1 -maxdepth 1 -type d | wc -l)

# Fingerprint for dedup and diffing. csdiff/v0 is the stable identifier; the
# rule+uri+line composite only backs up findings that carry no fingerprint.
read -r -d '' FINGERPRINT_JQ <<'JQ' || true
def fp:
  .fingerprints["csdiff/v0"]
  // ((.ruleId // "") + "|" + (.locations[0].physicalLocation.artifactLocation.uri // "")
      + "|" + ((.locations[0].physicalLocation.region.startLine // 0) | tostring));
JQ

BASELINE_FPS="[]"
BASELINE_UNIQUE=0
if [[ -n "$BASELINE_DIR" ]]; then
  BASELINE_SARIF=$(ls "$BASELINE_DIR"/attachments/*/sast_snyk_check_out.sarif 2>/dev/null | sort | head -1)
  [[ -n "$BASELINE_SARIF" ]] || { echo "FAIL: no Snyk SARIF under baseline dir $BASELINE_DIR" >&2; exit 2; }
  BASELINE_FPS=$(jq -s "${FINGERPRINT_JQ} [.[0].runs[0].results[] | fp] | unique" "$BASELINE_SARIF")
  BASELINE_UNIQUE=$(jq 'length' <<<"$BASELINE_FPS")
fi

# Main classification. Filters apply in order; the first match wins and is
# recorded, so the per-filter counts are disjoint. Anchors matter: (^|/)foo/
# matches only path segments, never substrings inside a file or directory
# name, and _test\.go$ only a file name suffix.
read -r -d '' CLASSIFY_JQ <<'JQ' || true
def norm:
  { ruleId, level,
    uri: (.locations[0].physicalLocation.artifactLocation.uri // ""),
    line: .locations[0].physicalLocation.region.startLine,
    message: .message.text };
def classify:
    if (.ruleId // "") | test("/test\\]$") then "snyk_test_flagged"
    elif (.uri // "") | test("(_test\\.go$|(^|/)tests?/|(^|/)testdata/|(^|/)testutil/|(^|/)testing/|(^|/)e2e/|(^|/)e2e-[^/]|(^|/)testenv/|(^|/)mocks?/|(^|/)mock[-_.])") then "test_paths"
    elif (.uri // "") | test("\\.obi-src/|(^|/)vendor/") then "vendored_upstream"
    elif (.uri // "") | test("(^|/)jaeger-ui/") then "jaeger_ui_frontend"
    elif (.uri // "") | test("(^|/)examples?/|(^|/)demo|store-demo|(^|/)samples?/") then "examples_demo"
    elif (.uri // "") | test("(^|/)scripts/|(^|/)tools/|(^|/)cmd/(check-|config-docs|obi|generate-|k8s-cache)|ci-analysis/|snapshot-tool") then "build_tooling"
    else null end;
[ .runs[0].results[] | norm + {fingerprint: fp} ]
| unique_by(.fingerprint)
| map(. + {filter: classify})
| group_by(.filter)
| map({key: (.[0].filter // "require_review"), value: .})
| from_entries
JQ

UNIQUE_JSON=$(jq "${FINGERPRINT_JQ} ${CLASSIFY_JQ}" "$SARIF")
UNIQUE_TOTAL=$(jq '[.[] | length] | add // 0' <<<"$UNIQUE_JSON")
RAW_TOTAL=$(jq '.runs[0].results | length' "$SARIF")

# Cross-release diff on fingerprints.
NEW_NOISE=""
REVIEW_JSON=$(jq '.require_review // []' <<<"$UNIQUE_JSON")
if [[ -n "$BASELINE_DIR" ]]; then
  EXISTING=$(jq --argjson base "$BASELINE_FPS" \
    '[.[][] | select((.fingerprint as $f | $base | index($f)) != null)] | length' <<<"$UNIQUE_JSON")
  REVIEW_JSON=$(jq --argjson base "$BASELINE_FPS" \
    'map(. + {new_since_baseline: ((.fingerprint as $f | $base | index($f)) == null)})' <<<"$REVIEW_JSON")
  NEW_TOTAL=$(jq --argjson base "$BASELINE_FPS" \
    '[.[][] | select((.fingerprint as $f | $base | index($f)) == null)] | length' <<<"$UNIQUE_JSON")
  NEW_NOISE=$(jq -r --argjson base "$BASELINE_FPS" '
    [ .[][] | select((.fingerprint as $f | $base | index($f)) == null)
      | select(.filter != null) ]
    | sort_by(.filter, .uri)
    | map(.filter + ": " + .uri + " (" + .ruleId + ")") | .[]' <<<"$UNIQUE_JSON")
else
  EXISTING=0
  NEW_TOTAL=""
fi

# Other scanners from the same component directory.
scanner_json() { # $1 = file glob name, $2 = jq filter for a summary object
  local f
  f=$(ls "$COMPONENT_DIR"/$1 2>/dev/null | sort | head -1)
  [[ -n "$f" ]] || { echo "null"; return; }
  jq "$2" "$f"
}

UNICODE=$(scanner_json "sast_unicode_check_out.sarif" '{findings: ([.runs[0].results[]?] | length)}')
SHELLCHECK=$(scanner_json "shellcheck-results.sarif" '
  [.runs[0].results[]?] | {findings: length,
    rules: (sort_by(.ruleId) | group_by(.ruleId) | map({(.[0].ruleId // "unknown"): length}) | add // {})}')
COVERITY=$(scanner_json "coverity-results.sarif" '
  [.runs[0].results[]?] as $r
  | {present: true, findings: ($r | length),
     test_yaml_noise: ([$r[] | select((.locations[0].physicalLocation.artifactLocation.uri // "" | test("tests?/e2e")) and ((.ruleId // "") | test("SIGMA")))] | length),
     require_review: [$r[] | select(((.locations[0].physicalLocation.artifactLocation.uri // "" | test("tests?/e2e")) and ((.ruleId // "") | test("SIGMA"))) | not)
       | {ruleId, level, uri: (.locations[0].physicalLocation.artifactLocation.uri // ""), line: .locations[0].physicalLocation.region.startLine, message: .message.text}]}')

# ClamAV: summarize every clamscan-*.json in the component directory.
CLAMAV=$(ls "$COMPONENT_DIR"/clamscan-*.json 2>/dev/null | sort | xargs -r jq -s '
  {scans: length,
   clean: ([.[] | select(.result == "SUCCESS" and ((.failures // 0) == 0) and ((.warnings // 0) == 0))] | length),
   problems: [.[] | select(.result != "SUCCESS" or ((.failures // 0) > 0) or ((.warnings // 0) > 0))
                | {timestamp, result, failures, warnings}]}' \
  || echo null)

jq -n \
  --arg version "$VERSION" --arg product "$PRODUCT" \
  --arg report_dir "$REPORT_DIR" --arg component "$COMPONENT" --argjson component_count "$COMPONENT_COUNT" \
  --argjson raw_total "$RAW_TOTAL" --argjson unique_total "$UNIQUE_TOTAL" \
  --argjson classified "$UNIQUE_JSON" --argjson review "$REVIEW_JSON" \
  --arg baseline_version "$BASELINE_VERSION" --arg baseline_dir "$BASELINE_DIR" \
  --argjson baseline_unique "$BASELINE_UNIQUE" --argjson existing "$EXISTING" --argjson new_total "${NEW_TOTAL:-null}" \
  --argjson unicode "${UNICODE:-null}" --argjson shellcheck "${SHELLCHECK:-null}" \
  --argjson coverity "${COVERITY:-null}" --argjson clamav "${CLAMAV:-null}" \
  --arg new_noise "$NEW_NOISE" '
  { version: $version, product: $product,
    report_dir: $report_dir,
    component_analyzed: $component,
    component_count: $component_count,
    note: ("All component images scan the same source repo and produce identical findings; one was processed."),
    baseline: (if $baseline_version == "" then null
               else {version: $baseline_version, dir: $baseline_dir, unique_findings: $baseline_unique} end),
    snyk: { raw_results: $raw_total, unique_findings: $unique_total,
            filter_counts: ($classified | to_entries | map(select(.key != "require_review") | .value = (.value | length)) | from_entries),
            require_review: $review },
    new_since_baseline: (if $new_total == null then null
                         else { total: $new_total,
                                still_present_from_baseline: $existing,
                                new_noise: ($new_noise | split("\n") | map(select(length > 0))) } end),
    other_scanners: { unicode: $unicode, shellcheck: $shellcheck,
                      coverity: $coverity, clamav: $clamav } }'
