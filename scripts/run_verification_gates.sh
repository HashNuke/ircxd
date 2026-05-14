#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/ircxd-0.1.0"

run_mix() {
  if command -v zsh >/dev/null 2>&1; then
    zsh -lic "$*"
  else
    "$@"
  fi
}

require_package_artifact() {
  local artifact="$1"
  local path="${PACKAGE_DIR}/${artifact}"

  if [[ ! -e "${path}" ]]; then
    echo "missing package artifact: ${artifact}" >&2
    exit 1
  fi
}

require_executable_package_artifact() {
  local artifact="$1"
  require_package_artifact "${artifact}"

  if [[ ! -x "${PACKAGE_DIR}/${artifact}" ]]; then
    echo "package artifact is not executable: ${artifact}" >&2
    exit 1
  fi
}

cd "${ROOT_DIR}"

echo "==> format check"
run_mix "mix format --check-formatted"

echo "==> compile warnings"
run_mix "mix compile --warnings-as-errors"

echo "==> default suite"
run_mix "mix test"

echo "==> generated docs"
run_mix "mix docs"

echo "==> package metadata"
rm -rf "${PACKAGE_DIR}"
run_mix "mix hex.build --unpack"
require_package_artifact "docs/conformance_workflow.md"
require_package_artifact "docs/completion_audit.md"
require_executable_package_artifact "scripts/run_verification_gates.sh"
require_executable_package_artifact "scripts/run_services_integration.sh"
require_executable_package_artifact "scripts/run_standard_replies_integration.sh"
require_executable_package_artifact "scripts/run_irssi_manual_check.sh"
rm -rf "${PACKAGE_DIR}"

echo "==> real standard-replies integration"
scripts/run_standard_replies_integration.sh

echo "==> services-backed IRCv3 integration"
scripts/run_services_integration.sh

if [[ "${IRCXD_INCLUDE_IRSSI:-0}" == "1" ]]; then
  echo "==> irssi cross-client check"
  scripts/run_irssi_manual_check.sh
else
  echo "==> irssi cross-client check skipped (set IRCXD_INCLUDE_IRSSI=1 to run)"
fi

echo "==> all verification gates passed"
