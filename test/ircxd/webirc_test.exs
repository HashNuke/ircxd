defmodule Ircxd.WebIRCTest do
  use ExUnit.Case, async: true

  alias Ircxd.WebIRC

  describe "options/1" do
    test "serializes WebIRC options with message-tag escaping" do
      assert WebIRC.options(%{
               "secure" => true,
               "local-port" => 6697,
               "remote-port" => 21_726,
               "example" => "semi; space"
             }) == "example=semi\\:\\sspace local-port=6697 remote-port=21726 secure"
    end

    test "keeps option lists in the given order" do
      assert WebIRC.options([{"secure", true}, {"local-port", 6697}]) == "secure local-port=6697"
    end
  end

  describe "params/1" do
    test "builds required and optional WEBIRC parameters" do
      assert WebIRC.params(
               password: "hunter2",
               gateway: "ExampleGateway",
               hostname: "198.51.100.3",
               ip: "198.51.100.3",
               options: [{"secure", true}, {"local-port", 6697}]
             ) == [
               "hunter2",
               "ExampleGateway",
               "198.51.100.3",
               "198.51.100.3",
               "secure local-port=6697"
             ]

      assert WebIRC.params(
               password: "hunter2",
               gateway: "ExampleGateway",
               hostname: "198.51.100.3",
               ip: "198.51.100.3"
             ) == ["hunter2", "ExampleGateway", "198.51.100.3", "198.51.100.3"]
    end
  end
end
