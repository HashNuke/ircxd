alias Ircxd.{Casemapping, Formatting, ISupport, Message}

samples = 7
iterations = 100_000

nick_index =
  for index <- 1..1_000, into: %{} do
    nick = "User#{String.pad_leading(Integer.to_string(index), 4, "0")}"
    {Casemapping.normalize(nick, :ascii), index}
  end

workloads = [
  {"message parse: tagged PRIVMSG", fn ->
     Message.parse("@time=2026-05-13T00:00:00.000Z;msgid=abc123 :nick!user@example.test PRIVMSG #elixir :hello world")
   end},
  {"message serialize: tagged PRIVMSG", fn ->
     Message.serialize(%Message{
       tags: %{"time" => "2026-05-13T00:00:00.000Z", "msgid" => "abc123"},
       source: "nick!user@example.test",
       command: "PRIVMSG",
       params: ["#elixir", "hello world"]
     })
   end},
  {"message tag escaping", fn -> Message.escape_tag_value("semi; space cr\r lf\n slash\\") end},
  {"formatting parse: styled text", fn -> Formatting.parse("plain \x02bold\x02 \x0304red\x03") end},
  {"ISUPPORT parse: 005 token set", fn ->
    ISupport.parse_params(["nick", "PREFIX=(ov)@+", "CHANTYPES=#&", "CHANLIMIT=#&:50", "are supported by this server"])
   end},
  {"casemapped nickname index lookup", fn ->
     Map.get(nick_index, Casemapping.normalize("uSER0500", :ascii))
   end}
]

defmodule Ircxd.Benchmark do
  def run(label, fun, samples, iterations) do
    for _ <- 1..2, do: measure(fun, iterations)
    timings = for _ <- 1..samples, do: measure(fun, iterations)
    sorted = Enum.sort(timings)
    median = percentile(sorted, 0.50)
    p95 = percentile(sorted, 0.95)
    ops = iterations / (median / 1_000_000)
    median_ms = Float.round(median / 1000, 2)
    p95_ms = Float.round(p95 / 1000, 2)
    ops = Float.round(ops, 0)
    IO.puts("#{String.pad_trailing(label, 38)} median #{median_ms} ms  p95 #{p95_ms} ms  #{ops} ops/s")
  end

  defp measure(fun, iterations) do
    {time, _result} = :timer.tc(fn -> Enum.each(1..iterations, fn _ -> fun.() end) end)
    time
  end

  defp percentile(values, fraction) do
    index = max(0, ceil(length(values) * fraction) - 1)
    Enum.at(values, index)
  end
end

IO.puts("ircxd microbenchmarks (#{iterations} iterations/sample, #{samples} samples)")
IO.puts("Results are for relative comparisons on the same machine; discard warm-up noise.")
Enum.each(workloads, fn {label, fun} -> Ircxd.Benchmark.run(label, fun, samples, iterations) end)
