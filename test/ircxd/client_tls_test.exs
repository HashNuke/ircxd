defmodule Ircxd.ClientTLSTest do
  use ExUnit.Case, async: true

  alias Ircxd.Client

  test "uses the IRC host as the default TLS SNI hostname" do
    options = Client.__tls_connect_options__(%{host: "irc.example.test"})

    assert options[:server_name_indication] == ~c"irc.example.test"
    assert options[:verify] == :verify_peer
    assert is_list(options[:cacerts])
    assert options[:cacerts] != []
    assert is_function(options[:customize_hostname_check][:match_fun], 2)
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

  test "uses a caller supplied CA file instead of the system trust store" do
    options =
      Client.__tls_connect_options__(%{
        host: "irc.example.test",
        tls_options: [cacertfile: "/custom/ca.pem"]
      })

    assert options[:cacertfile] == "/custom/ca.pem"
    refute Keyword.has_key?(options, :cacerts)
  end

  test "requires an explicit override to disable certificate verification" do
    options =
      Client.__tls_connect_options__(%{
        host: "localhost",
        tls_options: [verify: :verify_none]
      })

    assert options[:verify] == :verify_none
  end
end
