#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ircxd-standard-replies.XXXXXX")"
INSPIRCD_CONFIG="/etc/inspircd/ircxd-standard-replies-test.conf"
INSPIRCD_PID=""

CLIENT_PORT="${IRCXD_STANDARD_REPLIES_PORT:-6672}"

cleanup() {
  if [[ -n "${INSPIRCD_PID}" ]]; then
    sudo kill "${INSPIRCD_PID}" 2>/dev/null || true
  fi

  sudo pkill -f "inspircd --config ${INSPIRCD_CONFIG}" 2>/dev/null || true
  for _ in {1..50}; do
    if ! pgrep -f "inspircd --config ${INSPIRCD_CONFIG}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  sudo rm -f "${INSPIRCD_CONFIG}" 2>/dev/null || true
  rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_command inspircd
require_command sudo

cat >"${WORK_DIR}/inspircd.conf" <<EOF
<server name="irc.local"
        description="ircxd standard replies integration"
        network="Localnet">

<admin name="ircxd"
       nick="ircxd"
       email="ircxd@localhost">

<module name="cap">
<module name="ircv3">
<module name="setname">

<bind address="127.0.0.1" port="${CLIENT_PORT}" type="clients">

<connect allow="*"
         timeout="60"
         threshold="20"
         pingfreq="120"
         hardsendq="262144"
         softsendq="8192"
         recvq="8192"
         localmax="20"
         globalmax="20"
         maxchans="20">

<files motd="/etc/inspircd/inspircd.motd">
<dns server="127.0.0.1" timeout="5">

<options syntaxhints="no"
         announcets="yes"
         hostintopic="yes"
         pingwarning="15"
         splitwhois="no"
         exemptchanops="">

<security hideserver=""
          userstats="Pu"
          customversion=""
          flatlinks="no"
          hidesplits="no"
          hideulines="no"
          hidebans="no"
          maxtargets="20">

<performance quietbursts="yes"
             softlimit="1024"
             somaxconn="128"
             netbuffersize="10240">

<whowas groupsize="10"
        maxgroups="100000"
        maxkeep="3d">
EOF

sudo cp "${WORK_DIR}/inspircd.conf" "${INSPIRCD_CONFIG}"
sudo chown irc:irc "${INSPIRCD_CONFIG}"

sudo -u irc inspircd --config "${INSPIRCD_CONFIG}" --debug --nolog --nopid >"${WORK_DIR}/inspircd.log" 2>&1 &
INSPIRCD_PID="$!"

for _ in {1..50}; do
  if (echo >"/dev/tcp/127.0.0.1/${CLIENT_PORT}") >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! (echo >"/dev/tcp/127.0.0.1/${CLIENT_PORT}") >/dev/null 2>&1; then
  echo "InspIRCd did not start on 127.0.0.1:${CLIENT_PORT}" >&2
  echo "--- InspIRCd log ---" >&2
  tail -100 "${WORK_DIR}/inspircd.log" >&2 || true
  exit 1
fi

cd "${ROOT_DIR}"
if command -v zsh >/dev/null 2>&1; then
  IRCXD_STANDARD_REPLIES_PORT="${CLIENT_PORT}" \
    zsh -lic 'mix test --include standard_replies_integration test/ircxd/client_standard_replies_integration_test.exs'
else
  require_command mix
  IRCXD_STANDARD_REPLIES_PORT="${CLIENT_PORT}" \
    mix test --include standard_replies_integration test/ircxd/client_standard_replies_integration_test.exs
fi
