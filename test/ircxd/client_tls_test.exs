defmodule Ircxd.ClientTLSTest do
  use ExUnit.Case, async: true

  alias Ircxd.Client

  test "uses the IRC host as the default TLS SNI hostname" do
    assert Client.__tls_connect_options__(%{host: "irc.example.test"})[
             :server_name_indication
           ] == ~c"irc.example.test"
  end

  test "allows overriding the TLS SNI hostname" do
    assert Client.__tls_connect_options__(%{
             host: "127.0.0.1",
             sni: "irc.example.test"
           })[:server_name_indication] == ~c"irc.example.test"
  end

  test "keeps caller supplied TLS options" do
    options =
      Client.__tls_connect_options__(%{
        host: "irc.example.test",
        tls_options: [verify: :verify_peer, depth: 3]
      })

    assert options[:server_name_indication] == ~c"irc.example.test"
    assert options[:verify] == :verify_peer
    assert options[:depth] == 3
  end
end
