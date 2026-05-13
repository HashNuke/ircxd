#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ircxd-services.XXXXXX")"
INSPIRCD_CONFIG="/etc/inspircd/ircxd-services-test.conf"
ATHEME_PID=""
INSPIRCD_PID=""

CLIENT_PORT="${IRCXD_SERVICES_PORT:-6670}"
LINK_PORT="${IRCXD_SERVICES_LINK_PORT:-7001}"
LINK_SEND_PASSWORD="atheme-to-ircd"
LINK_RECV_PASSWORD="ircd-to-atheme"

cleanup() {
  if [[ -n "${ATHEME_PID}" ]] && kill -0 "${ATHEME_PID}" 2>/dev/null; then
    kill "${ATHEME_PID}" 2>/dev/null || true
    wait "${ATHEME_PID}" 2>/dev/null || true
  fi

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

require_command atheme-services
require_command inspircd
require_command perl
require_command sudo

if [[ ! -r /usr/share/doc/atheme-services/examples/atheme.conf.example ]]; then
  echo "missing Atheme example config; install atheme-services" >&2
  exit 1
fi

cat >"${WORK_DIR}/inspircd.conf" <<EOF
<server name="irc.local"
        description="ircxd services integration"
        network="Localnet">

<admin name="ircxd"
       nick="ircxd"
       email="ircxd@localhost">

<module name="cap">
<module name="ircv3">
<module name="ircv3_servertime">
<module name="ircv3_msgid">
<module name="ircv3_echomessage">
<module name="ircv3_labeledresponse">
<module name="spanningtree">
<module name="services_account">
<module name="sasl">
<module name="ircv3_accounttag">

<bind address="127.0.0.1" port="${CLIENT_PORT}" type="clients">
<bind address="127.0.0.1" port="${LINK_PORT}" type="servers">

<link name="services.local"
      ipaddr="127.0.0.1"
      port="${LINK_PORT}"
      allowmask="127.0.0.0/8"
      sendpass="${LINK_RECV_PASSWORD}"
      recvpass="${LINK_SEND_PASSWORD}">

<uline server="services.local">
<sasl target="services.local">

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

<class name="Shutdown"
       commands="DIE RESTART REHASH LOADMODULE UNLOADMODULE RELOADMODULE">
<class name="ServerLink"
       commands="CONNECT SQUIT RCONNECT RSQUIT MKPASSWD">
<class name="BanControl"
       commands="KILL GLINE KLINE ZLINE QLINE ELINE">
<class name="OperChat"
       commands="WALLOPS GLOBOPS SETIDLE SPYLIST SPYNAMES">
<class name="HostCloak"
       commands="SETHOST SETIDENT CHGNAME CHGHOST CHGIDENT">

<type name="NetAdmin"
      classes="OperChat BanControl HostCloak Shutdown ServerLink"
      host="netadmin.example.test">

<oper name="root"
      password="12345"
      host="*@localhost"
      type="NetAdmin"
      maxchans="60">

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

<badnick nick="ChanServ" reason="Reserved For Services">
<badnick nick="NickServ" reason="Reserved For Services">
<badnick nick="OperServ" reason="Reserved For Services">
<badnick nick="MemoServ" reason="Reserved For Services">
<badnick nick="SaslServ" reason="Reserved For Services">
EOF

cp /usr/share/doc/atheme-services/examples/atheme.conf.example "${WORK_DIR}/atheme.conf"
perl -0pi -e '
  s/#loadmodule "modules\/protocol\/charybdis";/loadmodule "modules\/protocol\/inspircd";/;
  s/name = "services\.int";/name = "services.local";/;
  s/netname = "misconfigured network";/netname = "Localnet";/;
  s/adminname = "misconfigured admin";/adminname = "ircxd";/;
  s/adminemail = "misconfigured\@admin\.tld";/adminemail = "ircxd\@localhost";/;
  s/registeremail = "noreply\@admin\.tld";/registeremail = "noreply\@localhost";/;
  s/mta = "\/usr\/sbin\/sendmail";/#mta = "\/usr\/sbin\/sendmail";/;
  s/uplink "irc\.example\.net"/uplink "irc.local"/;
  s/send_password = "mypassword";/send_password = "'"${LINK_SEND_PASSWORD}"'";/;
  s/receive_password = "theirpassword";/receive_password = "'"${LINK_RECV_PASSWORD}"'";/;
  s/port = 6667;/port = '"${LINK_PORT}"';/;
' "${WORK_DIR}/atheme.conf"

mkdir -p "${WORK_DIR}/atheme-data" "${WORK_DIR}/atheme-log"

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

atheme-services \
  -n \
  -c "${WORK_DIR}/atheme.conf" \
  -D "${WORK_DIR}/atheme-data" \
  -l "${WORK_DIR}/atheme-log/atheme.log" \
  -p "${WORK_DIR}/atheme-data/atheme.pid" >"${WORK_DIR}/atheme.log" 2>&1 &
ATHEME_PID="$!"

for _ in {1..100}; do
  if grep -q "finished synching with uplink" "${WORK_DIR}/atheme.log" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if ! grep -q "finished synching with uplink" "${WORK_DIR}/atheme.log" 2>/dev/null; then
  echo "Atheme did not finish syncing with InspIRCd" >&2
  echo "--- InspIRCd log ---" >&2
  tail -100 "${WORK_DIR}/inspircd.log" >&2 || true
  echo "--- Atheme log ---" >&2
  tail -100 "${WORK_DIR}/atheme.log" >&2 || true
  exit 1
fi

cd "${ROOT_DIR}"
if command -v zsh >/dev/null 2>&1; then
  IRCXD_SERVICES_PORT="${CLIENT_PORT}" \
    zsh -lic 'mix test --include services_integration test/ircxd/client_services_integration_test.exs'
else
  require_command mix
  IRCXD_SERVICES_PORT="${CLIENT_PORT}" \
    mix test --include services_integration test/ircxd/client_services_integration_test.exs
fi
