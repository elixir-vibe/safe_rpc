defmodule SafeRPC.RuntimeFoundationsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule StatelessServer do
    use SafeRPC.Server

    def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
    def handle_call(:boom, _payload, _state), do: raise("telemetry failure")

    def handle_call(:block, %{id: id}, state) do
      send(state.test_pid, {:request_started, id, self()})

      receive do
        :release -> {:reply, {:ok, id}, state}
      end
    end
  end

  defmodule StatefulServer do
    use SafeRPC.Server

    def init(_opts), do: {:ok, 0}
    def handle_call(:increment, _payload, state), do: {:reply, {:ok, state + 1}, state + 1}
  end

  test "rejects invalid execution and in-flight limits" do
    assert {:error, {:invalid_option, :execution, :parallel}} =
             StatelessServer.start_link(
               socket: socket_path("invalid-execution"),
               execution: :parallel,
               test_pid: self()
             )

    assert {:error, {:invalid_option, :max_in_flight, 0}} =
             StatelessServer.start_link(
               socket: socket_path("invalid-limit"),
               max_in_flight: 0,
               test_pid: self()
             )
  end

  test "concurrent execution runs requests on one connection in parallel" do
    socket = socket_path("concurrent")

    {:ok, server} =
      StatelessServer.start_link(socket: socket, execution: :concurrent, test_pid: self())

    {:ok, client} = SafeRPC.Client.start_link(socket: socket)
    first = Task.async(fn -> SafeRPC.call(client, :block, %{id: 1}) end)
    second = Task.async(fn -> SafeRPC.call(client, :block, %{id: 2}) end)

    assert_receive {:request_started, 1, first_worker}, 1_000
    assert_receive {:request_started, 2, second_worker}, 1_000

    send(first_worker, :release)
    send(second_worker, :release)
    assert Task.await(first) == {:ok, 1}
    assert Task.await(second) == {:ok, 2}

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "per-connection bounds reject excess work without stopping the connection" do
    socket = socket_path("connection-bound")

    {:ok, server} =
      StatelessServer.start_link(
        socket: socket,
        execution: :concurrent,
        test_pid: self(),
        max_in_flight_per_connection: 1
      )

    {:ok, client} = SafeRPC.Client.start_link(socket: socket)
    active = Task.async(fn -> SafeRPC.call(client, :block, %{id: :active}) end)
    assert_receive {:request_started, :active, worker}

    assert SafeRPC.call(client, :echo, :overloaded) == {:error, :resource_exhausted}
    send(worker, :release)
    assert Task.await(active) == {:ok, :active}
    assert SafeRPC.call(client, :echo, :healthy) == {:ok, :healthy}

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "duplicate active request IDs close only that connection" do
    socket = socket_path("duplicate-id")

    {:ok, server} =
      StatelessServer.start_link(socket: socket, execution: :concurrent, test_pid: self())

    {:ok, client} =
      :gen_tcp.connect({:local, socket}, 0, [:binary, active: false, packet: 4], 1_000)

    :ok =
      :gen_tcp.send(client, SafeRPC.Protocol.encode_call(7, nil, :block, %{id: :duplicate}))

    assert_receive {:request_started, :duplicate, _worker}
    :ok = :gen_tcp.send(client, SafeRPC.Protocol.encode_call(7, nil, :echo, :second))
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)

    assert SafeRPC.call(socket, :echo, :healthy) == {:ok, :healthy}
    GenServer.stop(server)
  end

  test "global bounds apply across connections" do
    socket = socket_path("global-bound")

    {:ok, server} =
      StatelessServer.start_link(
        socket: socket,
        execution: :concurrent,
        test_pid: self(),
        max_in_flight: 1
      )

    {:ok, first_client} = SafeRPC.Client.start_link(socket: socket)
    {:ok, second_client} = SafeRPC.Client.start_link(socket: socket)
    active = Task.async(fn -> SafeRPC.call(first_client, :block, %{id: :global}) end)
    assert_receive {:request_started, :global, worker}

    assert SafeRPC.call(second_client, :echo, :overloaded) == {:error, :resource_exhausted}
    send(worker, :release)
    assert Task.await(active) == {:ok, :global}
    assert SafeRPC.call(second_client, :echo, :healthy) == {:ok, :healthy}

    GenServer.stop(first_client)
    GenServer.stop(second_client)
    GenServer.stop(server)
  end

  test "concurrent execution rejects handlers that replace server state" do
    socket = socket_path("stateful")
    {:ok, server} = StatefulServer.start_link(socket: socket, execution: :concurrent)

    assert SafeRPC.call(socket, :increment) ==
             {:error, :stateful_handler_requires_serial_execution}

    GenServer.stop(server)
  end

  test "emits request and connection telemetry without payloads" do
    socket = socket_path("telemetry")
    handler_id = "safe-rpc-runtime-foundations-#{System.unique_integer([:positive])}"

    events = [
      [:safe_rpc, :connection, :start],
      [:safe_rpc, :connection, :stop],
      [:safe_rpc, :request, :start],
      [:safe_rpc, :request, :stop],
      [:safe_rpc, :request, :exception]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} =
      StatelessServer.start_link(socket: socket, execution: :concurrent, test_pid: self())

    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    assert SafeRPC.call(client, :echo, %{secret: "not telemetry"}) ==
             {:ok, %{secret: "not telemetry"}}

    assert_receive {:telemetry, [:safe_rpc, :connection, :start], %{system_time: _}, connection}
    assert connection.execution == :concurrent

    assert_receive {:telemetry, [:safe_rpc, :request, :start], %{system_time: _}, request}
    assert request.operation == :echo
    refute Map.has_key?(request, :payload)

    assert_receive {:telemetry, [:safe_rpc, :request, :stop], %{duration: duration}, stop}
    assert duration >= 0
    assert stop.outcome == :ok

    capture_log(fn ->
      assert SafeRPC.call(client, :boom) == {:error, :internal}
    end)

    assert_receive {:telemetry, [:safe_rpc, :request, :exception], %{duration: _}, exception}
    assert exception.exception_kind == :error
    assert exception.error == RuntimeError
    refute Map.has_key?(exception, :reason)

    GenServer.stop(client)

    assert_receive {:telemetry, [:safe_rpc, :connection, :stop], %{duration: _}, _metadata}
    GenServer.stop(server)
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "safe-rpc-runtime-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
