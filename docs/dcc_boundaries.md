# DCC Boundary Guide

`ircxd` parses and encodes DCC negotiation payloads carried inside CTCP
messages. It does not open peer-to-peer sockets, write files, or decide whether
a transfer should be trusted.

## Consuming DCC Events

DCC payloads are exposed on CTCP `PRIVMSG` and `NOTICE` events:

```elixir
def handle_event({:privmsg, %{dcc: %Ircxd.DCC{} = dcc} = payload}, state) do
  request_user_consent(payload.nick, dcc)
  {:ok, state}
end

def handle_event({:privmsg, %{dcc: {:error, reason}}}, state) do
  log_malformed_dcc(reason)
  {:ok, state}
end
```

The parsed payload includes:

- `type`: DCC command such as `CHAT`, `SEND`, `RESUME`, or `ACCEPT`.
- `argument`: chat token or filename.
- `host` and `port`: normalized peer endpoint data.
- `reverse?`: true when the offered port is `0`.
- `position`: resume/accept offset when present.
- `extra`: remaining command-specific parameters.

## Host-owned Policy

The embedding app owns:

- Whether to accept or reject a DCC offer.
- File path selection and filename sanitization.
- Virus scanning or content inspection.
- Transfer size, rate, and timeout limits.
- Direct TCP connection setup, including reverse/port-0 flows.
- User prompts and audit logging.

`ircxd` intentionally stays at the IRC/CTCP boundary so applications can enforce
their own security model.

## Sending DCC Negotiation Messages

Use the encoder helpers to build CTCP payloads, then send them with normal IRC
message helpers:

```elixir
payload = Ircxd.DCC.encode_send("file.txt", {127, 0, 0, 1}, 9000)
:ok = Ircxd.Client.privmsg(client, "target_nick", payload)
```

The direct file transfer that follows the negotiation remains outside `ircxd`.
