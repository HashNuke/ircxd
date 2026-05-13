defmodule Ircxd.ISupportTest do
  use ExUnit.Case, async: true

  alias Ircxd.ISupport

  test "parses RPL_ISUPPORT tokens" do
    assert %{
             "CHANTYPES" => "#&",
             "NICKLEN" => "30",
             "SAFELIST" => true,
             "EXCEPTS" => false
           } =
             ISupport.parse_params([
               "nick",
               "CHANTYPES=#&",
               "NICKLEN=30",
               "SAFELIST",
               "-EXCEPTS",
               "are supported by this server"
             ])
  end
end
