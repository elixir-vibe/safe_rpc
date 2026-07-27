defmodule SafeRPC.StressTest do
  use ExUnit.Case, async: false

  @moduletag :stress
  @count String.to_integer(System.get_env("SAFERPC_STRESS_COUNT") || "1000")

  defmodule EchoServer do
    use SafeRPC.Server

    def init(_opts), do: {:ok, %{}}
    def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}

    def handle_call(:sleep, payload, state) do
      Process.sleep(payload.ms)
      {:reply, {:ok, payload.id}, state}
    end
  end

  test "handles many concurrent calls on one client" do
    socket = socket_path("calls")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    results =
      1..@count
      |> Task.async_stream(&SafeRPC.call(client, :echo, &1, timeout: 15_000),
        max_concurrency: 100,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == Enum.map(1..@count, &{:ok, &1})

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "handles many async requests on one client" do
    socket = socket_path("async")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    requests = for i <- 1..@count, do: SafeRPC.async(client, :echo, i, timeout: 15_000)
    assert Enum.map(requests, &SafeRPC.await(&1, 30_000)) == Enum.map(1..@count, &{:ok, &1})

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "survives a concurrent cancellation storm and recovers worker slots" do
    socket = socket_path("cancel")

    {:ok, server} =
      EchoServer.start_link(
        socket: socket,
        execution: :concurrent,
        max_in_flight: 64,
        max_in_flight_per_connection: 64
      )

    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    requests =
      for i <- 1..50, do: SafeRPC.async(client, :sleep, %{id: i, ms: 100}, timeout: 5_000)

    requests |> Enum.take(25) |> Enum.each(&SafeRPC.cancel/1)

    Process.sleep(150)
    assert SafeRPC.call(client, :echo, :alive, timeout: 5_000) == {:ok, :alive}

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "bounds the serialized connection mailbox under a request flood" do
    socket = socket_path("mailbox")
    receive_window = 64

    {:ok, server} =
      EchoServer.start_link(
        socket: socket,
        max_in_flight_per_connection: receive_window
      )

    {:ok, client} = SafeRPC.Client.start_link(socket: socket)
    connection = await_connection(server)

    requests =
      for i <- 1..200,
          do: SafeRPC.async(client, :sleep, %{id: i, ms: 1}, timeout: 15_000)

    {:messages, messages} = Process.info(connection, :messages)
    {:memory, connection_memory} = Process.info(connection, :memory)

    queued_payloads = Enum.count(messages, &match?({:safe_rpc_payload, _payload}, &1))
    assert queued_payloads <= receive_window
    assert connection_memory < 10 * 1024 * 1024
    assert Enum.map(requests, &SafeRPC.await(&1, 30_000)) == Enum.map(1..200, &{:ok, &1})

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "routes stress traffic through a sharded pool" do
    socket = socket_path("pool")
    {:ok, server} = EchoServer.start_link(socket: socket)
    Process.sleep(20)
    {:ok, pool} = SafeRPC.ClientPool.start_link(socket: socket, shards: 4)

    results =
      1..@count
      |> Task.async_stream(
        fn i -> SafeRPC.ClientPool.call(pool, rem(i, 32), :echo, i, timeout: 15_000) end,
        max_concurrency: 100,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == Enum.map(1..@count, &{:ok, &1})

    GenServer.stop(pool)
    GenServer.stop(server)
  end

  defp await_connection(server, attempts \\ 100)

  defp await_connection(_server, 0), do: flunk("server did not accept the benchmark client")

  defp await_connection(server, attempts) do
    case :sys.get_state(server).connections |> MapSet.to_list() do
      [connection | _rest] ->
        connection

      [] ->
        Process.sleep(5)
        await_connection(server, attempts - 1)
    end
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "safe-rpc-stress-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
