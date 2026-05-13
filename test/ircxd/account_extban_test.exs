defmodule Ircxd.AccountExtbanTest do
  use ExUnit.Case, async: true

  alias Ircxd.AccountExtban

  test "builds account extban masks from single-letter tokens" do
    isupport = %{"EXTBAN" => "$,ARar", "ACCOUNTEXTBAN" => "R"}

    assert AccountExtban.mask(isupport, "bob") == {:ok, "$R:bob"}
  end

  test "builds account extban masks from named tokens" do
    isupport = %{"EXTBAN" => "~,a", "ACCOUNTEXTBAN" => "a,account"}

    assert AccountExtban.mask(isupport, "bob", "account") == {:ok, "~account:bob"}
  end

  test "rejects missing account extban support" do
    assert AccountExtban.mask(%{"EXTBAN" => "$,ARar"}, "bob") ==
             {:error, :account_extban_not_supported}

    assert AccountExtban.mask(%{"ACCOUNTEXTBAN" => "R"}, "bob") ==
             {:error, :account_extban_not_supported}
  end
end
