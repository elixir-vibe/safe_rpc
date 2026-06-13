defmodule SafeRPC.ClientPool do
  @moduledoc "A sharded pool of SafeRPC clients."

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def call(pool, key, op, payload \\ %{}, opts \\ []) do
    pool |> client(key) |> SafeRPC.call(op, payload, opts)
  end

  def cast(pool, key, op, payload \\ %{}, opts \\ []) do
    pool |> client(key) |> SafeRPC.cast(op, payload, opts)
  end

  def async(pool, key, op, payload \\ %{}, opts \\ []) do
    pool |> client(key) |> SafeRPC.async(op, payload, opts)
  end

  def client(pool, key) do
    GenServer.call(pool, {:client, key})
  end

  @impl true
  def init(opts) do
    shard_count = Keyword.get(opts, :shards, System.schedulers_online())

    clients =
      for index <- 0..(shard_count - 1) do
        {:ok, client} = SafeRPC.Client.start_link(Keyword.delete(opts, :name))
        {index, client}
      end
      |> Map.new()

    {:ok, %{clients: clients, shard_count: shard_count}}
  end

  @impl true
  def handle_call({:client, key}, _from, state) do
    shard = :erlang.phash2(key, state.shard_count)
    {:reply, Map.fetch!(state.clients, shard), state}
  end
end
