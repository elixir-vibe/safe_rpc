defmodule SafeRPCTest do
  use ExUnit.Case, async: true

  defmodule EchoServer do
    use SafeRPC.Server

    def init(opts), do: {:ok, %{count: Keyword.get(opts, :count, 0)}}

    def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
    def handle_call(:count, _payload, state), do: {:reply, {:ok, state.count}, state}

    def handle_cast(:inc, amount, state), do: {:noreply, %{state | count: state.count + amount}}
  end

  test "calls and casts over Unix sockets" do
    socket = socket_path("echo")
    {:ok, pid} = EchoServer.start_link(socket: socket)

    assert {:ok, %{hello: :world}} = SafeRPC.call(socket, :echo, %{hello: :world})
    assert {:ok, :noreply} = SafeRPC.cast(socket, :inc, 2)
    assert {:ok, 2} = SafeRPC.call(socket, :count)

    GenServer.stop(pid)
  end

  test "uses a persistent client process" do
    socket = socket_path("client")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    assert {:ok, %{hello: :client}} = SafeRPC.call(client, :echo, %{hello: :client})
    assert {:ok, :noreply} = SafeRPC.cast(client, :inc, 3)
    assert {:ok, 3} = SafeRPC.call(client, :count)

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "runs asynchronous requests with Task-like API" do
    socket = socket_path("async")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    request = SafeRPC.async(client, :echo, %{hello: :async})

    assert %SafeRPC.Task{op: :echo} = request
    assert {:ok, {:ok, %{hello: :async}}} = SafeRPC.yield(request, 1_000)

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "awaits asynchronous requests" do
    socket = socket_path("await")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    request = SafeRPC.async(client, :echo, %{hello: :await})

    assert {:ok, %{hello: :await}} = SafeRPC.await(request, 1_000)

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "checks capabilities" do
    socket = socket_path("cap")
    cap = SafeRPC.Capability.new(token: "secret", ops: [:echo])
    {:ok, pid} = EchoServer.start_link(socket: socket, capability: cap)

    assert {:ok, :allowed} = SafeRPC.call(socket, :echo, :allowed, cap: "secret")
    assert {:error, :unauthorized} = SafeRPC.call(socket, :echo, :denied, cap: "bad")
    assert {:error, :unauthorized} = SafeRPC.call(socket, :count, %{}, cap: "secret")

    GenServer.stop(pid)
  end

  test "rejects invalid terms" do
    assert {:error, {:invalid_term, %ArgumentError{}}} =
             SafeRPC.Protocol.decode_request(<<131, 112>>)
  end

  defp socket_path(name) do
    Path.join(System.tmp_dir!(), "safe-rpc-#{name}-#{System.unique_integer([:positive])}.sock")
  end
end
