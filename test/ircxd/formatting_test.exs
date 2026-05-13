defmodule Ircxd.FormattingTest do
  use ExUnit.Case, async: true

  alias Ircxd.Formatting

  test "parses toggled text formatting spans" do
    assert Formatting.parse("plain \x02bold\x02 normal") == [
             %{text: "plain ", style: %{}},
             %{text: "bold", style: %{bold: true}},
             %{text: " normal", style: %{}}
           ]

    assert Formatting.parse("\x1Ditalic\x1D \x1Funder\x1F \x1Estrike\x1E \x11mono\x11 \x16rev") ==
             [
               %{text: "italic", style: %{italic: true}},
               %{text: " ", style: %{}},
               %{text: "under", style: %{underline: true}},
               %{text: " ", style: %{}},
               %{text: "strike", style: %{strikethrough: true}},
               %{text: " ", style: %{}},
               %{text: "mono", style: %{monospace: true}},
               %{text: " ", style: %{}},
               %{text: "rev", style: %{reverse: true}}
             ]
  end

  test "parses mIRC foreground and background color controls" do
    assert Formatting.parse("a \x0304red \x0303,12green on blue\x03 plain") == [
             %{text: "a ", style: %{}},
             %{text: "red ", style: %{foreground: "04"}},
             %{text: "green on blue", style: %{foreground: "03", background: "12"}},
             %{text: " plain", style: %{}}
           ]
  end

  test "keeps comma text when color background is not present" do
    assert Formatting.parse("\x0304, text") == [
             %{text: ", text", style: %{foreground: "04"}}
           ]

    assert Formatting.parse("\x03, text") == [
             %{text: ", text", style: %{}}
           ]
  end

  test "parses hex colors and reset" do
    assert Formatting.parse("\x04ff0000,00ff00hex\x0F plain") == [
             %{
               text: "hex",
               style: %{hex_foreground: "FF0000", hex_background: "00FF00"}
             },
             %{text: " plain", style: %{}}
           ]
  end

  test "strips formatting controls while preserving display text" do
    assert Formatting.strip("Rules: \x02do not\x02 use \x0304red\x03, ok") ==
             "Rules: do not use red, ok"
  end
end
