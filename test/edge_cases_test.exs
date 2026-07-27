defmodule SafeRPC.EdgeCasesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule EchoServer do
    use SafeRPC.Server

    def init(opts), do: {:ok, Keyword.get(opts, :test_pid)}
    def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
    def handle_call(:die, _payload, _state), do: Process.exit(self(), :kill)

    def handle_call(:block, _payload, test_pid) do
      send(test_pid, {:blocked, self()})
      Process.sleep(:infinity)
    end

    def handle_cast(:notify, payload, test_pid) do
      send(test_pid, {:cast, payload})
      {:noreply, test_pid}
    end
  end

  defmodule InspectPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      details = %{
        host: conn.host,
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        remote_ip: conn.remote_ip,
        scheme: conn.scheme,
        test_header: get_req_header(conn, "x-test"),
        opts: opts
      }

      send_resp(conn, 201, :erlang.term_to_binary(details))
    end
  end

  test "covers convenience client APIs and Task-like timeout behavior" do
    socket = socket_path("convenience")
    {:ok, server} = EchoServer.start_link(socket: socket, test_pid: self())
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    assert {:ok, %{}} = SafeRPC.Client.call(client, :echo)
    assert {:ok, :payload} = SafeRPC.Client.call(client, :echo, :payload)
    assert {:ok, %{}} = SafeRPC.Client.call(socket, :echo)
    assert {:ok, :payload} = SafeRPC.Client.call(socket, :echo, :payload)

    assert {:ok, :noreply} = SafeRPC.Client.cast(client, :notify)
    assert_receive {:cast, %{}}
    assert {:ok, :noreply} = SafeRPC.Client.cast(client, :notify, :payload)
    assert_receive {:cast, :payload}
    assert {:ok, :noreply} = SafeRPC.Client.cast(socket, :notify)
    assert_receive {:cast, %{}}
    assert {:ok, :noreply} = SafeRPC.Client.cast(socket, :notify, :payload)
    assert_receive {:cast, :payload}

    assert {:ok, request} = SafeRPC.Client.send_request(client, :echo)
    assert {:ok, %{}} = SafeRPC.await(request)

    capture_log(fn ->
      assert {:error, :internal} = SafeRPC.prepare(socket)
    end)

    missing = %SafeRPC.Task{client: client, id: -1, op: :missing}
    assert SafeRPC.yield(missing) == nil

    assert catch_exit(SafeRPC.await(missing, 1)) ==
             {:timeout, {SafeRPC, :await, [missing, 1]}}

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "async errors raise and shutdown delegates to cancellation" do
    socket = socket_path("async-errors")

    {:ok, server} =
      EchoServer.start_link(
        socket: socket,
        test_pid: self(),
        execution: :concurrent,
        max_in_flight: 1,
        max_in_flight_per_connection: 1
      )

    {:ok, tiny_client} = SafeRPC.Client.start_link(socket: socket, max_frame_size: 1)

    assert_raise RuntimeError, ~r/SafeRPC async request failed/, fn ->
      SafeRPC.async(tiny_client, :echo)
    end

    GenServer.stop(tiny_client)

    {:ok, client} = SafeRPC.Client.start_link(socket: socket)
    request = SafeRPC.async(client, :block)
    assert_receive {:blocked, worker}
    monitor = Process.monitor(worker)

    assert :ok = SafeRPC.shutdown(request)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert eventually(fn -> SafeRPC.call(client, :echo, :released) == {:ok, :released} end)

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "abnormal concurrent workers return internal errors and release their slots" do
    socket = socket_path("worker-exit")

    {:ok, server} =
      EchoServer.start_link(
        socket: socket,
        test_pid: self(),
        execution: :concurrent,
        max_in_flight: 1,
        max_in_flight_per_connection: 1
      )

    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    assert {:error, :internal} = SafeRPC.call(client, :die)
    assert {:ok, :healthy} = SafeRPC.call(client, :echo, :healthy)

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "malformed protocol frames close only their connection" do
    socket = socket_path("malformed")
    {:ok, server} = EchoServer.start_link(socket: socket, test_pid: self())

    {:ok, client} =
      :gen_tcp.connect({:local, socket}, 0, [:binary, active: false, packet: 4], 1_000)

    assert :ok = :gen_tcp.send(client, :erlang.term_to_binary({:unknown, 1}))
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
    assert {:ok, :healthy} = SafeRPC.call(socket, :echo, :healthy)

    GenServer.stop(server)
  end

  test "prepares default and invalid atom vocabularies" do
    assert :ok = SafeRPC.Atoms.prepare(["ok"])

    assert {:error, {:invalid_atom_vocabulary, :not_a_list}} =
             SafeRPC.Atoms.prepare(:not_a_list)

    assert {:error, {:invalid_atom_name, :not_binary}} =
             SafeRPC.Atoms.prepare([:not_binary])

    assert :ok = SafeRPC.Atoms.prepare(["ok"], allow: [fn name -> name == "ok" end])
  end

  test "covers capability fallbacks" do
    capability = SafeRPC.Capability.new(token: :token, ops: :all)

    refute SafeRPC.Capability.allowed?(capability, nil, :echo)
    assert SafeRPC.Capability.allowed?(capability, :token, :echo)
    refute SafeRPC.Capability.allowed?(capability, :other, :echo)
    refute SafeRPC.Capability.allowed?(:invalid, :token, :echo)
  end

  test "covers protocol defaults and malformed terms" do
    cast = SafeRPC.Protocol.encode_cast(1, nil, :echo, :payload)
    assert {:ok, %{kind: :cast}} = SafeRPC.Protocol.decode_request(cast)
    assert :ok = SafeRPC.Protocol.validate_frame_size(cast)

    invalid_request = :erlang.term_to_binary({:unknown, 1})

    assert {:error, {:invalid_request, {:unknown, 1}}} =
             SafeRPC.Protocol.decode_request(invalid_request)

    invalid_reply = :erlang.term_to_binary({:unknown, 1})

    assert {:error, {:invalid_reply, {:unknown, 1}}} =
             SafeRPC.Protocol.decode_reply(invalid_reply)
  end

  test "adapts query strings, headers, schemes, and remote addresses to Plug" do
    request = %SafeRPC.Adapter.HTTP.Request{
      method: "POST",
      scheme: "https",
      host: "service.example",
      port: 443,
      path: "/inspect",
      query: "page=2",
      headers: [{"host", "ignored.example"}, {"X-Test", "covered"}],
      remote_ip: {127, 0, 0, 1},
      body: {:full, "body"}
    }

    response = SafeRPC.Adapter.Plug.call(request, InspectPlug, plug_opts: [covered: true])
    details = :erlang.binary_to_term(elem(response.body, 1), [:safe])

    assert response.status == 201
    assert details.host == "service.example"
    assert details.path == "/inspect"
    assert details.query == "page=2"
    assert details.scheme == :https
    assert details.remote_ip == {127, 0, 0, 1}
    assert details.test_header == ["covered"]
    assert details.opts == [covered: true]

    assert {:error, :unknown_operation} =
             SafeRPC.Adapter.Plug.Service.call(:unknown, %{}, %{}, %{})
  end

  test "runs service DSL validation and metadata paths at runtime" do
    suffix = System.unique_integer([:positive])
    valid = Module.concat([SafeRPC, EdgeCaseDynamic, "Valid#{suffix}"])

    Code.compile_string("""
    defmodule #{inspect(valid)} do
      use SafeRPC, service: :coverage_dynamic

      @rpc false
      def skipped(_payload, _meta, _state), do: :skipped

      @rpc scope: :read
      @doc false
      @spec fetch(map(), map(), term()) :: {:ok, map()}
      def fetch(payload, _meta, _state), do: {:ok, %{kind: :dynamic, payload: payload}}

      @rpc true
      def plain(_payload, _meta, _state)
      def plain(payload, _meta, _state), do: {:ok, {payload, %URI{scheme: :http}, 123}}
    end
    """)

    assert {:ok, %{kind: :dynamic, payload: %{id: 1}}} =
             valid.call({valid, :fetch}, %{id: 1}, %{}, nil)

    assert {:ok, {:payload, %URI{scheme: :http}, 123}} =
             valid.call({valid, :plain}, :payload, %{}, nil)

    assert %SafeRPC.Descriptor{} = valid.__safe_rpc_descriptor__()
    assert "dynamic" in valid.__safe_rpc_atoms__()

    assert_compile_error(
      suffix,
      "Private",
      """
        @rpc true
        defp hidden(_payload, _meta, _state), do: :hidden
      """,
      ~r/private function/
    )

    assert_compile_error(
      suffix,
      "Arity",
      """
        @rpc true
        def wrong(_payload, _state), do: :wrong
      """,
      ~r/must have arity 3/
    )

    assert_compile_error(
      suffix,
      "Options",
      """
        @rpc :invalid
        def wrong(_payload, _meta, _state), do: :wrong
      """,
      ~r/@rpc expects true or keyword options/
    )
  end

  defp assert_compile_error(suffix, name, body, message) do
    module = Module.concat([SafeRPC, EdgeCaseDynamic, "#{name}#{suffix}"])

    assert_raise ArgumentError, message, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use SafeRPC, service: :coverage_dynamic
        #{body}
      end
      """)
    end
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "safe-rpc-edge-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
