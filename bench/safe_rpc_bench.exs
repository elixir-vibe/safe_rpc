Code.require_file("support/config.exs", __DIR__)

defmodule SafeRPCBench.EchoServer do
  use SafeRPC.Server

  def init(_opts), do: {:ok, %{}}
  def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
end

socket = Path.join(System.tmp_dir!(), "safe-rpc-bench-#{System.unique_integer([:positive])}.sock")
{:ok, server} = SafeRPCBench.EchoServer.start_link(socket: socket)
{:ok, client} = SafeRPC.Client.start_link(socket: socket)
{:ok, pool} = SafeRPC.ClientPool.start_link(socket: socket, shards: 4)

payloads = %{
  "small" => %{hello: :world},
  "1kb" => :crypto.strong_rand_bytes(1024),
  "64kb" => :crypto.strong_rand_bytes(64 * 1024),
  "1mb" => :crypto.strong_rand_bytes(1024 * 1024)
}

selected_payloads = SafeRPCBench.Config.list("SAFERPC_BENCH_PAYLOADS", "small,1kb,64kb")
parallelism = SafeRPCBench.Config.list("SAFERPC_BENCH_PARALLEL", "1,4,16")

Process.sleep(25)

for payload_name <- selected_payloads,
    parallel <- Enum.map(parallelism, &String.to_integer/1) do
  payload = Map.fetch!(payloads, payload_name)
  name = "serial-#{payload_name}-p#{parallel}"

  Benchee.run(
    %{
      "one-shot" => fn -> SafeRPC.call(socket, :echo, payload) end,
      "persistent client" => fn -> SafeRPC.call(client, :echo, payload) end,
      "client pool" => fn -> SafeRPC.ClientPool.call(pool, payload_name, :echo, payload) end
    },
    SafeRPCBench.Config.options(name, parallel)
  )
end

GenServer.stop(pool)
GenServer.stop(client)
GenServer.stop(server)
