defmodule SafeRPCTest do
  use ExUnit.Case, async: true

  defmodule MetadataAuthorizer do
    @behaviour SafeRPC.Authorizer

    def authorize(%{meta: %{allow: true}}, _context), do: :ok
    def authorize(_request, _context), do: {:error, :forbidden}
  end

  defmodule AdapterEchoService do
    @behaviour SafeRPC.Adapter.Service

    def init(_opts), do: {:ok, %{}}

    def call(:echo, payload, meta, state),
      do: {:ok, %{payload: payload, meta: meta, state: state}}

    def call(:missing, _payload, _meta, _state), do: {:error, :missing}
  end

  defmodule AdapterEchoServer do
    use SafeRPC.Adapter.Server, service: AdapterEchoService
  end

  defmodule NativeService do
    use SafeRPC, service: :native, version: "1"

    @rpc true
    @doc "Return available models."
    @spec models(map(), map(), term()) :: {:ok, [atom()]}
    def models(_payload, _meta, _state), do: {:ok, [:small, :large]}

    @rpc true
    @doc "Return service status."
    @spec status(map(), map(), term()) :: {:ok, map()}
    def status(_payload, meta, state), do: {:ok, %{meta: meta, state: state}}

    def hidden(_payload, _meta, _state), do: {:ok, :hidden}
  end

  defmodule NativeServer do
    use SafeRPC.Adapter.Server, service: NativeService
  end

  defmodule AdapterRoutes do
    def echo(payload, meta, _state), do: {:ok, {payload, meta}}
    def named(op, payload, meta, _state), do: {:ok, {op, payload, meta}}
  end

  defmodule EchoServer do
    use SafeRPC.Server

    def init(opts), do: {:ok, %{count: Keyword.get(opts, :count, 0)}}

    def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
    def handle_call(:count, _payload, state), do: {:reply, {:ok, state.count}, state}

    def handle_call(:sleep, payload, state) do
      Process.sleep(payload.ms)
      {:reply, {:ok, :slept}, state}
    end

    def handle_cast(:inc, amount, state), do: {:noreply, %{state | count: state.count + amount}}
  end

  test "server modules expose a supervisor child spec" do
    socket = socket_path("child-spec")

    assert %{
             id: EchoServer,
             start: {EchoServer, :start_link, [[socket: ^socket]]},
             type: :worker,
             restart: :permanent,
             shutdown: 5_000
           } = EchoServer.child_spec(socket: socket)
  end

  test "applies configured Unix socket mode" do
    socket = socket_path("socket-mode")
    {:ok, pid} = EchoServer.start_link(socket: socket, socket_mode: 0o660)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(socket)
    assert Bitwise.band(mode, 0o777) == 0o660

    GenServer.stop(pid)
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

  test "persistent client replies to pending calls when the server closes" do
    socket = socket_path("client-close")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    task = Task.async(fn -> SafeRPC.call(client, :sleep, %{ms: 1_000}, timeout: 5_000) end)
    GenServer.stop(server)

    assert {:error, _reason} = Task.await(task, 1_000)
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

  test "routes calls through a sharded client pool" do
    socket = socket_path("pool")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, pool} = SafeRPC.ClientPool.start_link(socket: socket, shards: 2)

    assert {:ok, %{hello: :pool}} =
             SafeRPC.ClientPool.call(pool, {:workspace, :alice, :blog}, :echo, %{hello: :pool})

    assert {:ok, :noreply} = SafeRPC.ClientPool.cast(pool, :counter, :inc, 4)
    assert {:ok, 4} = SafeRPC.ClientPool.call(pool, :counter, :count)

    request = SafeRPC.ClientPool.async(pool, :async, :echo, %{hello: :pool_async})
    assert {:ok, %{hello: :pool_async}} = SafeRPC.await(request, 1_000)

    GenServer.stop(pool)
    GenServer.stop(server)
  end

  test "uses stable shard selection" do
    socket = socket_path("pool-stable")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, pool} = SafeRPC.ClientPool.start_link(socket: socket, shards: 4)

    assert SafeRPC.ClientPool.client(pool, :same_key) ==
             SafeRPC.ClientPool.client(pool, :same_key)

    GenServer.stop(pool)
    GenServer.stop(server)
  end

  test "tracks multiple asynchronous requests" do
    socket = socket_path("multi-async")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    first = SafeRPC.async(client, :echo, %{n: 1})
    second = SafeRPC.async(client, :echo, %{n: 2})

    assert {:ok, %{n: 1}} = SafeRPC.await(first, 1_000)
    assert {:ok, %{n: 2}} = SafeRPC.await(second, 1_000)

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

  test "runs an optional authorizer" do
    socket = socket_path("authz")
    {:ok, server} = EchoServer.start_link(socket: socket, authorizer: MetadataAuthorizer)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    assert {:error, :forbidden} = SafeRPC.call(client, :echo, :denied)
    assert {:ok, :allowed} = SafeRPC.call(client, :echo, :allowed, meta: %{allow: true})

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "cancels asynchronous requests" do
    socket = socket_path("cancel")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    request = SafeRPC.async(client, :sleep, %{ms: 1_000}, timeout: 5_000)

    assert :ok = SafeRPC.cancel(request)
    assert nil == SafeRPC.yield(request, 50)

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "exposes @rpc functions through use SafeRPC" do
    socket = socket_path("native")
    {:ok, server} = NativeServer.start_link(socket: socket, booted?: true)

    assert {:ok, [:small, :large]} = SafeRPC.call(socket, {NativeService, :models})

    assert {:ok, %{meta: %{trace_id: "abc"}, state: [socket: ^socket, booted?: true]}} =
             SafeRPC.call(socket, {NativeService, :status}, %{}, meta: %{trace_id: "abc"})

    assert {:error, :unknown_operation} = SafeRPC.call(socket, {NativeService, :hidden})

    GenServer.stop(server)
  end

  test "describes @rpc functions with docs and typespecs" do
    descriptor = NativeService.__safe_rpc_descriptor__()

    assert %SafeRPC.Descriptor{service: :native, module: NativeService, version: "1"} = descriptor
    assert %{ops: ops, meta: %{}} = Map.fetch!(descriptor.modules, NativeService)
    assert %{models: models, status: status} = ops
    assert models.name == :models
    assert models.module == NativeService
    assert models.function == :models
    assert models.arity == 3
    assert models.docs == "Return available models."
    assert is_binary(models.spec)
    assert models.spec =~ "models"
    assert status.docs == "Return service status."
  end

  test "describes services over SafeRPC" do
    socket = socket_path("describe")
    {:ok, server} = NativeServer.start_link(socket: socket)

    assert {:ok, %SafeRPC.Descriptor{service: :native, modules: modules}} =
             SafeRPC.describe(socket)

    assert Map.has_key?(modules[NativeService].ops, :models)
    assert Map.has_key?(modules[NativeService].ops, :status)
    assert is_binary(modules[NativeService].ops.models.spec)

    GenServer.stop(server)
  end

  test "returns unsupported describe for adapter services without descriptors" do
    socket = socket_path("describe-unsupported")
    {:ok, server} = AdapterEchoServer.start_link(socket: socket)

    assert {:error, :unsupported} = SafeRPC.describe(socket)

    GenServer.stop(server)
  end

  test "dispatches through adapter services" do
    socket = socket_path("adapter")
    {:ok, server} = AdapterEchoServer.start_link(socket: socket)

    assert {:ok, %{payload: :hello, meta: %{source: :test}, state: %{}}} =
             SafeRPC.call(socket, :echo, :hello, meta: %{source: :test})

    assert {:error, :missing} = SafeRPC.call(socket, :missing)

    GenServer.stop(server)
  end

  test "dispatches adapter route tables" do
    routes = %{
      echo: {AdapterRoutes, :echo, 3},
      named: {AdapterRoutes, :named, 4}
    }

    assert {:ok, {:payload, %{a: 1}}} =
             SafeRPC.Adapter.Dispatcher.call(routes, :echo, :payload, %{a: 1}, %{})

    assert {:ok, {:named, :payload, %{a: 1}}} =
             SafeRPC.Adapter.Dispatcher.call(routes, :named, :payload, %{a: 1}, %{})

    assert {:error, :unknown_operation} =
             SafeRPC.Adapter.Dispatcher.call(routes, :missing, :payload, %{}, %{})
  end

  test "documents local binding terms as safe ETF" do
    bindings = %{
      catalog: %{
        socket: "/run/apps/catalog/rpc.sock",
        modules: [SafeRPCTest.NativeService],
        listener: :rpc,
        upstream: "unix:/run/apps/catalog/rpc.sock",
        unit: "app-catalog.service"
      }
    }

    assert ^bindings =
             bindings
             |> :erlang.term_to_binary()
             |> :erlang.binary_to_term([:safe])
  end

  test "defines neutral HTTP envelopes" do
    request = %SafeRPC.Adapter.HTTP.Request{
      method: "GET",
      scheme: "https",
      host: "example.com",
      port: 443,
      path: "/",
      headers: [{"accept", "text/plain"}]
    }

    response = SafeRPC.Adapter.HTTP.Response.text(200, "ok")

    assert request.host == "example.com"
    assert response.status == 200
    assert response.body == {:full, "ok"}
  end

  test "rejects invalid terms" do
    assert {:error, {:invalid_term, %ArgumentError{}}} =
             SafeRPC.Protocol.decode_request(<<131, 112>>)
  end

  defp socket_path(name) do
    Path.join(System.tmp_dir!(), "safe-rpc-#{name}-#{System.unique_integer([:positive])}.sock")
  end
end
