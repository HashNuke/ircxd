defmodule Ircxd.ClientInfoIdentityTest do
  use ExUnit.Case, async: false

  alias Ircxd.Client.Info
  alias Ircxd.ScriptedIrcServer

  defmodule CaptureAdapter do
    @behaviour Ircxd.Client.Adapter

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_event(event, context, owner) do
      send(owner, {:captured_client_event, event, context})
      {:ok, owner}
    end
  end

  test "exposes a secret-free cached snapshot and classifies self identity at event time" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :batch"]

           "CAP REQ batch", _state ->
             [":irc.test CAP * ACK :batch"]

           "CAP END", _state ->
             []

           "WELCOME", _state ->
             [
               ":irc.test 001 Mira :Welcome",
               ":irc.test 005 Mira CASEMAPPING=rfc1459 CHANTYPES=#& :are supported by this server"
             ]

           "NICK NewNick", _state ->
             [
               ":mIRA!user@host NICK NewNick",
               ":newnick!user@host JOIN #room"
             ]

           "TRIGGERCAP", _state ->
             [":irc.test CAP * NEW :echo-message"]

           "CAP REQ echo-message", _state ->
             [":irc.test CAP * ACK :echo-message"]

           "CAP REQ -echo-message", _state ->
             [":irc.test CAP * ACK :-echo-message"]

           "TRIGGERDEL", _state ->
             [":irc.test CAP * DEL :echo-message"]

           "TRIGGER", _state ->
             [
               ":op!user@host KICK #room NEWNICK :bye",
               ":newNICK!user@host MODE NewNick +i",
               ":newnick!user@host TOPIC #room :topic",
               ":alice!user@host PRIVMSG nEwNiCk :hello"
             ]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "mira",
        username: "mira",
        realname: "Mira",
        caps: ["batch"],
        password: "server-secret",
        sasl: {:plain, "mira", "sasl-secret"},
        adapter: {CaptureAdapter, self()},
        notify: self(),
        allow_insecure_auth: true
      )

    assert_receive {:ircxd, {:connected, _details}}, 1_000
    assert_receive {:ircxd, {:cap_ack, ["batch"]}}, 1_000

    assert %Info{
             connected?: true,
             registered?: false,
             desired_nick: "mira",
             current_nick: nil
           } = Ircxd.Client.connection_info(client)

    assert :ok = Ircxd.Client.raw(client, "WELCOME")
    assert_receive {:ircxd, :registered}, 1_000
    assert_receive {:ircxd, {:isupport, _tokens}}, 1_000

    assert %Info{
             connected?: true,
             registered?: true,
             current_nick: "Mira",
             desired_nick: "mira",
             tls?: false,
             transport: :gen_tcp,
             active_caps: active_caps,
             available_caps: %{"batch" => true},
             isupport: %{"CASEMAPPING" => "rfc1459", "CHANTYPES" => "#&"}
           } = Ircxd.Client.connection_info(client)

    assert active_caps == MapSet.new(["batch"])
    refute Map.has_key?(Map.from_struct(Ircxd.Client.connection_info(client)), :password)
    assert Ircxd.Client.same_identifier?(client, "[Nick]", "{nick}")
    assert Ircxd.Client.self_nick?(client, "mIRA")

    assert :ok = Ircxd.Client.raw(client, "TRIGGERCAP")
    assert_receive {:ircxd, {:cap_new, %{"echo-message" => true}}}, 1_000
    assert Ircxd.Client.connection_info(client).available_caps["echo-message"] == true

    assert :ok = Ircxd.Client.request_capabilities(client, ["echo-message"])
    assert_receive {:ircxd, {:cap_ack, ["echo-message"]}}, 1_000
    assert "echo-message" in Ircxd.Client.connection_info(client).active_caps

    assert :ok = Ircxd.Client.disable_capabilities(client, ["echo-message"])
    assert_receive {:ircxd, {:cap_ack, ["-echo-message"]}}, 1_000
    refute "echo-message" in Ircxd.Client.connection_info(client).active_caps

    assert :ok = Ircxd.Client.raw(client, "TRIGGERDEL")
    assert_receive {:ircxd, {:cap_del, ["echo-message"]}}, 1_000
    refute Map.has_key?(Ircxd.Client.connection_info(client).available_caps, "echo-message")

    assert :ok = Ircxd.Client.nick(client, "NewNick")

    assert_receive {:captured_client_event,
                    {:nick, %{source_self?: true, old_nick: "mIRA", new_nick: "NewNick"}},
                    %{client_info: %Info{current_nick: "NewNick"}}},
                   1_000

    assert_receive {:captured_client_event,
                    {:join, %{source_self?: true, nick: "newnick", channel: "#room"}},
                    %{client_info: %Info{current_nick: "NewNick"}}},
                   1_000

    assert :ok = Ircxd.Client.raw(client, "TRIGGER")

    assert_receive {:captured_client_event, {:kick, %{source_self?: false, target_self?: true}},
                    _context},
                   1_000

    assert_receive {:captured_client_event, {:mode, %{source_self?: true, target_self?: true}},
                    _context},
                   1_000

    assert_receive {:captured_client_event, {:topic, %{source_self?: true}}, _context},
                   1_000

    assert_receive {:captured_client_event,
                    {:privmsg, %{source_self?: false, target_self?: true}}, _context},
                   1_000
  end
end
