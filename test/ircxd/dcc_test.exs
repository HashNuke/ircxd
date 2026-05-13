defmodule Ircxd.DCCTest do
  use ExUnit.Case, async: true

  alias Ircxd.CTCP
  alias Ircxd.DCC

  test "parses DCC CHAT queries from CTCP payloads" do
    assert {:ok,
            %DCC{
              type: "CHAT",
              argument: "chat",
              host: "127.0.0.1",
              raw_host: "2130706433",
              port: 9000,
              extra: []
            }} = DCC.parse(%CTCP{command: "DCC", params: "CHAT chat 2130706433 9000"})
  end

  test "parses DCC SEND queries with quoted filenames and extra parameters" do
    assert {:ok,
            %DCC{
              type: "SEND",
              argument: "file name.txt",
              host: "2001:db8::1",
              raw_host: "2001:db8::1",
              port: 0,
              extra: ["12345"]
            }} = DCC.parse("DCC SEND \"file name.txt\" 2001:db8::1 0 12345")
  end

  test "rejects malformed DCC queries" do
    assert {:error, :not_dcc} = DCC.parse(%CTCP{command: "ACTION", params: "waves"})
    assert {:error, :not_enough_params} = DCC.parse("SEND file.txt 2130706433")
    assert {:error, :invalid_port} = DCC.parse("SEND file.txt 2130706433 99999")
    assert {:error, :unterminated_quote} = DCC.parse("SEND \"file name.txt 2130706433 9000")
  end

  test "encodes DCC CHAT and SEND CTCP payloads" do
    assert DCC.encode_chat({127, 0, 0, 1}, 9000) == <<1, "DCC CHAT chat 2130706433 9000", 1>>

    assert DCC.encode_send("file name.txt", "2001:db8::1", 0, [12345]) ==
             <<1, "DCC SEND \"file name.txt\" 2001:db8::1 0 12345", 1>>
  end
end
