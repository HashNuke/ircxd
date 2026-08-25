defmodule Ircxd.ClientClientBatchTest do
  use ExUnit.Case, async: false

  alias Ircxd.Message
  alias Ircxd.ScriptedIrcServer

  test "sends a client-initiated batch when an enabling draft capability is negotiated" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/example-client-batch message-tags"]

           "CAP REQ :draft/example-client-batch message-tags", _state ->
             [":irc.test CAP * ACK :draft/example-client-batch message-tags"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           "BATCH +cb1 draft/example #elixir", _state ->
             []

           "@batch=cb1 PRIVMSG #elixir hello", _state ->
             []

           "@+client=value;batch=cb1 NOTICE #elixir :hello there", _state ->
             []

           "BATCH -cb1", _state ->
             []

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["draft/example-client-batch", "message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert :ok =
             Ircxd.Client.client_batch(
               client,
               "cb1",
               "draft/example",
               ["#elixir"],
               [
                 {"PRIVMSG", ["#elixir", "hello"]},
                 %Message{
                   command: "NOTICE",
                   params: ["#elixir", "hello there"],
                   tags: %{"+client" => "value"}
                 }
               ],
               required_cap: "draft/example-client-batch"
             )

    assert_receive {:scripted_irc_line, "BATCH +cb1 draft/example #elixir"}, 1_000
    assert_receive {:scripted_irc_line, "@batch=cb1 PRIVMSG #elixir hello"}, 1_000

    assert_receive {:scripted_irc_line, "@+client=value;batch=cb1 NOTICE #elixir :hello there"},
                   1_000

    assert_receive {:scripted_irc_line, "BATCH -cb1"}, 1_000
  end

  test "requires an explicit negotiated capability before sending client batches" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state -> [":irc.test CAP * LS :message-tags"]
           "CAP END", _state -> [":irc.test 001 nick :Welcome"]
           _line, _state -> []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert {:error, :missing_client_batch_capability} =
             Ircxd.Client.client_batch(client, "cb1", "draft/example", [], [
               {"PRIVMSG", ["#elixir", "hello"]}
             ])

    assert {:error, {:capability_not_enabled, "draft/example-client-batch"}} =
             Ircxd.Client.client_batch(
               client,
               "cb1",
               "draft/example",
               [],
               [{"PRIVMSG", ["#elixir", "hello"]}],
               required_cap: "draft/example-client-batch"
             )
  end

  test "rejects nested batches and caller-supplied batch tags" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/example-client-batch"]

           "CAP REQ draft/example-client-batch", _state ->
             [":irc.test CAP * ACK :draft/example-client-batch"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["draft/example-client-batch"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    assert {:error, :nested_client_batch} =
             Ircxd.Client.client_batch(
               client,
               "cb1",
               "draft/example",
               [],
               [{"BATCH", ["+nested", "draft/example"]}],
               required_cap: "draft/example-client-batch"
             )

    assert {:error, :reserved_client_batch_tag} =
             Ircxd.Client.client_batch(
               client,
               "cb1",
               "draft/example",
               [],
               [
                 %Message{
                   command: "PRIVMSG",
                   params: ["#elixir", "hello"],
                   tags: %{"batch" => "old"}
                 }
               ],
               required_cap: "draft/example-client-batch"
             )
  end

  test "validates every message before opening a client batch" do
    server =
      start_supervised!(
        {ScriptedIrcServer,
         test_pid: self(),
         script: fn
           "CAP LS 302", _state ->
             [":irc.test CAP * LS :draft/example-client-batch message-tags"]

           "CAP REQ :draft/example-client-batch message-tags", _state ->
             [":irc.test CAP * ACK :draft/example-client-batch message-tags"]

           "CAP END", _state ->
             [":irc.test 001 nick :Welcome"]

           _line, _state ->
             []
         end}
      )

    {:ok, client} =
      Ircxd.start_link(
        host: "127.0.0.1",
        port: ScriptedIrcServer.port(server),
        nick: "nick",
        username: "nick",
        realname: "Nick",
        caps: ["draft/example-client-batch", "message-tags"],
        notify: self()
      )

    assert_receive {:ircxd, :registered}, 1_000

    for {message, error} <- [
          {%Message{command: nil}, :invalid_command},
          {%Message{command: "PRIVMSG", params: [%{}]}, :invalid_param},
          {%Message{command: "PRIVMSG", params: ["#room", "hello"], tags: nil}, :invalid_tags}
        ] do
      assert {:error, ^error} =
               Ircxd.Client.client_batch(
                 client,
                 "cb-invalid",
                 "draft/example",
                 [],
                 [message],
                 required_cap: "draft/example-client-batch"
               )

      assert Process.alive?(client)
    end

    for reference <- ["", "_", "bad/reference"] do
      assert {:error, :invalid_batch_reference} =
               Ircxd.Client.client_batch(
                 client,
                 reference,
                 "draft/example",
                 [],
                 [{"PRIVMSG", ["#room", "hello"]}],
                 required_cap: "draft/example-client-batch"
               )
    end

    for type <- ["", "bad type", ":bad"] do
      assert {:error, :invalid_batch_type} =
               Ircxd.Client.client_batch(
                 client,
                 "valid-ref",
                 type,
                 [],
                 [{"PRIVMSG", ["#room", "hello"]}],
                 required_cap: "draft/example-client-batch"
               )
    end

    refute Enum.any?(ScriptedIrcServer.lines(server), &String.starts_with?(&1, "BATCH +"))
  end
end
