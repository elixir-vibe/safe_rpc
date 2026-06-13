defmodule SafeRPCBench.EchoServer do
  use SafeRPC.Server

  def init(_opts), do: {:ok, %{}}
  def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
end

socket = Path.join(System.tmp_dir!(), "safe-rpc-bench-#{System.unique_integer([:positive])}.sock")
{:ok, server} = SafeRPCBench.EchoServer.start_link(socket: socket)
{:ok, client} = SafeRPC.Client.start_link(socket: socket)
{:ok, pool} = SafeRPC.ClientPool.start_link(socket: socket, shards: System.schedulers_online())

payloads = %{
  small: %{hello: :world},
  kb_1: :crypto.strong_rand_bytes(1024),
  kb_64: :crypto.strong_rand_bytes(64 * 1024),
  mb_1: :crypto.strong_rand_bytes(1024 * 1024)
}

Enum.each(payloads, fn {name, payload} ->
  Benchee.run(
    %{
      "direct #{name}" => fn -> {:ok, payload} end,
      "one-shot #{name}" => fn -> SafeRPC.call(socket, :echo, payload) end,
      "client #{name}" => fn -> SafeRPC.call(client, :echo, payload) end,
      "pool #{name}" => fn -> SafeRPC.ClientPool.call(pool, name, :echo, payload) end
    },
    parallel: [1, 4, 16],
    time: 5,
    memory_time: 1
  )
end)

GenServer.stop(pool)
GenServer.stop(client)
GenServer.stop(server)
