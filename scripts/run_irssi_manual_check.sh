#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ircxd-irssi.XXXXXX")"

HOST="${IRCXD_IRSSI_HOST:-127.0.0.1}"
PORT="${IRCXD_IRSSI_PORT:-6667}"
CHANNEL="${IRCXD_IRSSI_CHANNEL:-#ircxd-manual-${RANDOM}}"
SESSION="ircxd-irssi-${RANDOM}"
PANE="${SESSION}:0.0"
IRSSI_NICK="irssi${RANDOM}"
IRCXD_NICK="ircxdmanual${RANDOM}"
MESSAGE="ircxd-manual-${RANDOM}"

cleanup() {
  tmux kill-session -t "${SESSION}" 2>/dev/null || true
  rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

wait_for_pane() {
  local pattern="$1"
  local timeout="$2"
  local deadline=$((SECONDS + timeout))

  while ((SECONDS < deadline)); do
    if tmux capture-pane -pt "${PANE}" -S -200 | grep -Fq "${pattern}"; then
      return 0
    fi
    sleep 0.5
  done

  echo "timed out waiting for irssi pane pattern: ${pattern}" >&2
  tmux capture-pane -pt "${PANE}" -S -200 >&2 || true
  return 1
}

require_command irssi
require_command tmux

if ! (echo >"/dev/tcp/${HOST}/${PORT}") >/dev/null 2>&1; then
  echo "InspIRCd is not reachable at ${HOST}:${PORT}" >&2
  exit 1
fi

tmux new-session -d -s "${SESSION}" "irssi --home=${WORK_DIR} --connect=${HOST} --port=${PORT} --nick=${IRSSI_NICK}"
wait_for_pane "End of message of the day" 20
tmux send-keys -t "${PANE}" -l "/join ${CHANNEL}"
tmux send-keys -t "${PANE}" C-m
wait_for_pane "Join to ${CHANNEL} was synced" 20

cd "${ROOT_DIR}"

if command -v zsh >/dev/null 2>&1; then
  zsh -lic "IRCXD_IRSSI_HOST='${HOST}' IRCXD_IRSSI_PORT='${PORT}' IRCXD_IRSSI_CHANNEL='${CHANNEL}' IRCXD_IRSSI_NICK='${IRCXD_NICK}' IRCXD_IRSSI_MESSAGE='${MESSAGE}' mix run -e '
host = System.fetch_env!(\"IRCXD_IRSSI_HOST\")
port = String.to_integer(System.fetch_env!(\"IRCXD_IRSSI_PORT\"))
channel = System.fetch_env!(\"IRCXD_IRSSI_CHANNEL\")
nick = System.fetch_env!(\"IRCXD_IRSSI_NICK\")
message = System.fetch_env!(\"IRCXD_IRSSI_MESSAGE\")
{:ok, pid} = Ircxd.start_link(host: host, port: port, tls: false, nick: nick, username: nick, realname: \"ircxd manual\", caps: [\"server-time\", \"echo-message\"], notify: self())
receive do
  {:ircxd, :registered} -> :ok
after
  15_000 -> exit(:registration_timeout)
end
:ok = Ircxd.Client.join(pid, channel)
Process.sleep(500)
:ok = Ircxd.Client.privmsg(pid, channel, message)
Process.sleep(1_000)
'"
else
  IRCXD_IRSSI_HOST="${HOST}" \
    IRCXD_IRSSI_PORT="${PORT}" \
    IRCXD_IRSSI_CHANNEL="${CHANNEL}" \
    IRCXD_IRSSI_NICK="${IRCXD_NICK}" \
    IRCXD_IRSSI_MESSAGE="${MESSAGE}" \
    mix run -e '
host = System.fetch_env!("IRCXD_IRSSI_HOST")
port = String.to_integer(System.fetch_env!("IRCXD_IRSSI_PORT"))
channel = System.fetch_env!("IRCXD_IRSSI_CHANNEL")
nick = System.fetch_env!("IRCXD_IRSSI_NICK")
message = System.fetch_env!("IRCXD_IRSSI_MESSAGE")
{:ok, pid} = Ircxd.start_link(host: host, port: port, tls: false, nick: nick, username: nick, realname: "ircxd manual", caps: ["server-time", "echo-message"], notify: self())
receive do
  {:ircxd, :registered} -> :ok
after
  15_000 -> exit(:registration_timeout)
end
:ok = Ircxd.Client.join(pid, channel)
Process.sleep(500)
:ok = Ircxd.Client.privmsg(pid, channel, message)
Process.sleep(1_000)
'
fi

sleep 2
tmux send-keys -t "${PANE}" -l "/window goto 2"
tmux send-keys -t "${PANE}" C-m
sleep 1
pane="$(tmux capture-pane -pt "${PANE}" -S -200)"

if grep -Fq "${MESSAGE}" <<<"${pane}"; then
  echo "irssi observed message from ${IRCXD_NICK} in ${CHANNEL}: ${MESSAGE}"
else
  echo "irssi did not observe expected message" >&2
  echo "--- irssi pane ---" >&2
  echo "${pane}" >&2
  exit 1
fi
