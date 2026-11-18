#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RELEASE_DIR="${WORKSPACE_ROOT}/release"

usage() {
    cat <<EOF
Generate ci-operator config files for a new rhosdt release branch.

Usage: $(basename "$0") [--force] <version> [tag]

  version   rhosdt version, e.g. 0.168
  tag       image tag (default: rhosdt-<version>)
  --force   overwrite existing config files

Output files are written to the release repo under ci-operator/config/.

Examples:
  $(basename "$0") 0.168
  $(basename "$0") 0.168 my-custom-tag
  $(basename "$0") --force 0.168
EOF
    exit 1
}

FORCE=false
POSITIONAL=()
for arg in "$@"; do
    case "${arg}" in
        --force) FORCE=true ;;
        --help|-h) usage ;;
        *) POSITIONAL+=("${arg}") ;;
    esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && usage

if ! command -v envsubst &>/dev/null; then
    echo "ERROR: envsubst not found. Install gettext: sudo dnf install gettext" >&2
    exit 1
fi

RHOSDT_VERSION="${POSITIONAL[0]}"

if [[ ! "${RHOSDT_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must be in format N.NNN, e.g. 0.168 (got '${RHOSDT_VERSION}')" >&2
    exit 1
fi

RHOSDT_TAG="${POSITIONAL[1]:-rhosdt-${RHOSDT_VERSION}}"

export RHOSDT_VERSION RHOSDT_TAG

OPERATOR_DIR="${RELEASE_DIR}/ci-operator/config/openshift/open-telemetry-opentelemetry-operator"
COLLECTOR_DIR="${RELEASE_DIR}/ci-operator/config/openshift/redhat-opentelemetry-collector"

OPERATOR_OUT="${OPERATOR_DIR}/openshift-open-telemetry-opentelemetry-operator-rhosdt-${RHOSDT_VERSION}__art-build.yaml"
COLLECTOR_OUT="${COLLECTOR_DIR}/openshift-redhat-opentelemetry-collector-rhosdt-${RHOSDT_VERSION}.yaml"

for dir in "${OPERATOR_DIR}" "${COLLECTOR_DIR}"; do
    if [[ ! -d "${dir}" ]]; then
        echo "ERROR: directory not found: ${dir}" >&2
        echo "Is the release repo cloned at ${RELEASE_DIR}?" >&2
        exit 1
    fi
done

if [[ "${FORCE}" != true ]]; then
    for out in "${OPERATOR_OUT}" "${COLLECTOR_OUT}"; do
        if [[ -f "${out}" ]]; then
            echo "ERROR: ${out} already exists. Use --force to overwrite." >&2
            exit 1
        fi
    done
fi

envsubst '${RHOSDT_VERSION} ${RHOSDT_TAG}' < "${SCRIPT_DIR}/operator-art-build.yaml.tmpl" > "${OPERATOR_OUT}"
envsubst '${RHOSDT_VERSION} ${RHOSDT_TAG}' < "${SCRIPT_DIR}/collector.yaml.tmpl" > "${COLLECTOR_OUT}"

echo "Generated:"
echo "  ${OPERATOR_OUT}"
echo "  ${COLLECTOR_OUT}"
