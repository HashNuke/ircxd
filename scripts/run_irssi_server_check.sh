#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ircxd-server-irssi.XXXXXX")"

HOST="${IRCXD_SERVER_IRSSI_HOST:-127.0.0.1}"
PORT="${IRCXD_SERVER_IRSSI_PORT:-16667}"
CHANNEL="${IRCXD_SERVER_IRSSI_CHANNEL:-#ircxd-server-${RANDOM}}"
SERVER_SESSION="ircxd-server-${RANDOM}"
IRSSI_SESSION="ircxd-server-irssi-${RANDOM}"
PANE="${IRSSI_SESSION}:0.0"
IRSSI_NICK="irssi${RANDOM}"
IRCXD_NICK="ircxd${RANDOM}"
MESSAGE="ircxd-server-check-${RANDOM}"

cleanup() {
  tmux kill-session -t "${SERVER_SESSION}" 2>/dev/null || true
  tmux kill-session -t "${IRSSI_SESSION}" 2>/dev/null || true
  rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

wait_for_port() {
  local deadline=$((SECONDS + 20))

  while ((SECONDS < deadline)); do
    if (echo >"/dev/tcp/${HOST}/${PORT}") >/dev/null 2>&1; then
      return 0
    fi

    sleep 0.5
  done

  return 1
}

wait_for_pane() {
  local pattern="$1"
  local deadline=$((SECONDS + 20))

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
require_command mix
require_command tmux

if (echo >"/dev/tcp/${HOST}/${PORT}") >/dev/null 2>&1; then
  echo "port ${HOST}:${PORT} is already in use; choose IRCXD_SERVER_IRSSI_PORT" >&2
  exit 1
fi

server_command="cd ${ROOT_DIR} && mix run --no-halt -e '{:ok, _} = Ircxd.Server.start_link(port: ${PORT}, server_name: \"ircxd.test\"); Process.sleep(:infinity)'"
tmux new-session -d -s "${SERVER_SESSION}" "${server_command}"
wait_for_port

tmux new-session -d -s "${IRSSI_SESSION}" \
  "irssi --home=${WORK_DIR} --connect=${HOST} --port=${PORT} --nick=${IRSSI_NICK}"
wait_for_pane "Welcome to Ircxd"

tmux send-keys -t "${PANE}" -l "/join ${CHANNEL}"
tmux send-keys -t "${PANE}" C-m
# Wait for irssi's post-join users line rather than the echoed `/join` input;
# this avoids matching before the server has actually added irssi to the
# channel and remains stable when the notification wraps across lines.
wait_for_pane "[Users ${CHANNEL}]"
tmux send-keys -t "${PANE}" -l "/window goto 2"
tmux send-keys -t "${PANE}" C-m
sleep 1

cd "${ROOT_DIR}"
IRCXD_SERVER_IRSSI_HOST="${HOST}" \
  IRCXD_SERVER_IRSSI_PORT="${PORT}" \
  IRCXD_SERVER_IRSSI_CHANNEL="${CHANNEL}" \
  IRCXD_SERVER_IRSSI_NICK="${IRCXD_NICK}" \
  IRCXD_SERVER_IRSSI_MESSAGE="${MESSAGE}" \
  mix run -e '
host = System.fetch_env!("IRCXD_SERVER_IRSSI_HOST")
port = String.to_integer(System.fetch_env!("IRCXD_SERVER_IRSSI_PORT"))
channel = System.fetch_env!("IRCXD_SERVER_IRSSI_CHANNEL")
nick = System.fetch_env!("IRCXD_SERVER_IRSSI_NICK")
message = System.fetch_env!("IRCXD_SERVER_IRSSI_MESSAGE")

{:ok, client} =
  Ircxd.start_link(
    host: host,
    port: port,
    tls: false,
    nick: nick,
    username: nick,
    realname: "Ircxd irssi check",
    caps: ["echo-message"],
    notify: self()
  )

receive do
  {:ircxd, :registered} -> :ok
after
  15_000 -> exit(:registration_timeout)
end

:ok = Ircxd.Client.join(client, channel)
receive do
  {:ircxd, {:join, %{channel: ^channel}}} -> :ok
after
  10_000 -> exit(:join_timeout)
end

:ok = Ircxd.Client.privmsg(client, channel, message)
Process.sleep(1_000)
'

sleep 1
pane="$(tmux capture-pane -pt "${PANE}" -S -200)"

if grep -Fq "${MESSAGE}" <<<"${pane}"; then
  echo "irssi observed ${IRCXD_NICK}'s message in ${CHANNEL}: ${MESSAGE}"
else
  echo "irssi did not observe the expected message from Ircxd.Server" >&2
  echo "--- irssi pane ---" >&2
  echo "${pane}" >&2
  exit 1
fi
