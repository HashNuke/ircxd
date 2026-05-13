defmodule Ircxd.CTCPTest do
  use ExUnit.Case, async: true

  alias Ircxd.CTCP

  test "encodes CTCP payloads" do
    assert CTCP.encode("ACTION", "waves") == <<1, "ACTION waves", 1>>
    assert CTCP.encode("VERSION") == <<1, "VERSION", 1>>
  end

  test "decodes CTCP payloads" do
    assert {:ok, %CTCP{command: "ACTION", params: "waves"}} =
             CTCP.decode(<<1, "ACTION waves", 1>>)

    assert {:ok, %CTCP{command: "VERSION", params: ""}} = CTCP.decode(<<1, "version", 1>>)
    assert :error = CTCP.decode("normal message")
  end
end
