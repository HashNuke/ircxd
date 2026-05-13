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
