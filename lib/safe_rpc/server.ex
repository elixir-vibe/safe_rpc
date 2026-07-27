defmodule SafeRPC.Server do
  @moduledoc "GenServer-like Unix socket server for explicit SafeRPC APIs."

  @callback init(keyword()) :: {:ok, term()} | {:stop, term()}
  @callback handle_call(atom(), term(), term()) :: {:reply, term(), term()}
  @callback handle_cast(atom(), term(), term()) :: {:noreply, term()}
  @callback handle_request(map(), term()) :: {:reply, term(), term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour SafeRPC.Server

      def start_link(opts) do
        SafeRPC.Server.start_link(__MODULE__, opts)
      end

      def child_spec(opts) do
        %{
          id: Keyword.get(opts, :id, __MODULE__),
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 5_000
        }
      end

      def handle_cast(_op, _payload, state), do: {:noreply, state}

      def handle_request(%{kind: :call, op: op, payload: payload}, state) do
        handle_call(op, payload, state)
      end

      def handle_request(%{kind: :cast, op: op, payload: payload}, state) do
        case handle_cast(op, payload, state) do
          {:noreply, state} -> {:reply, {:ok, :noreply}, state}
        end
      end

      defoverridable start_link: 1, child_spec: 1, handle_cast: 3, handle_request: 2
    end
  end

  def start_link(handler, opts) do
    with :ok <- validate_options(opts) do
      GenServer.start_link(__MODULE__.Loop, {handler, opts}, name: Keyword.get(opts, :name))
    end
  end

  defp validate_options(opts) do
    execution = Keyword.get(opts, :execution, :serial)
    global_limit = Keyword.get(opts, :max_in_flight, 1_024)
    connection_limit = Keyword.get(opts, :max_in_flight_per_connection, 64)

    cond do
      execution not in [:serial, :concurrent] ->
        {:error, {:invalid_option, :execution, execution}}

      not (is_integer(global_limit) and global_limit > 0) ->
        {:error, {:invalid_option, :max_in_flight, global_limit}}

      not (is_integer(connection_limit) and connection_limit > 0) ->
        {:error, {:invalid_option, :max_in_flight_per_connection, connection_limit}}

      true ->
        :ok
    end
  end

  defmodule Loop do
    use GenServer

    require Logger

    alias SafeRPC.Authorizer.AllowAll
    alias SafeRPC.Server.{Connection, Dispatcher}
    alias SafeRPC.Transport.Unix

    def init({handler, opts}) do
      Process.flag(:trap_exit, true)
      transport = Keyword.get(opts, :transport, Unix)
      socket = Keyword.fetch!(opts, :socket)

      with {:ok, user_state} <- handler.init(opts),
           {:ok, listen} <- transport.listen(opts),
           {:ok, request_supervisor} <- Task.Supervisor.start_link() do
        owner = self()
        acceptor = spawn_link(fn -> accept_loop(owner, transport, listen) end)

        dispatch = %{
          handler: handler,
          user_state: user_state,
          capability: Keyword.get(opts, :capability),
          authorizer: Keyword.get(opts, :authorizer, AllowAll),
          auth_context: Keyword.get(opts, :auth_context),
          execution: Keyword.get(opts, :execution, :serial)
        }

        state = %{
          socket: socket,
          listen: listen,
          transport: transport,
          dispatch: dispatch,
          execution: Keyword.get(opts, :execution, :serial),
          request_supervisor: request_supervisor,
          in_flight: :atomics.new(1, signed: false),
          max_in_flight: Keyword.get(opts, :max_in_flight, 1_024),
          max_in_flight_per_connection: Keyword.get(opts, :max_in_flight_per_connection, 64),
          recv_timeout: Keyword.get(opts, :recv_timeout, 5_000),
          max_frame_size:
            Keyword.get(opts, :max_frame_size, SafeRPC.Protocol.default_max_frame_size()),
          acceptor: acceptor,
          connections: MapSet.new()
        }

        {:ok, state}
      end
    end

    def handle_info({:safe_rpc_accepted, acceptor, client}, %{acceptor: acceptor} = state) do
      opts = [
        owner: self(),
        transport: state.transport,
        socket: client,
        recv_timeout: state.recv_timeout,
        max_frame_size: state.max_frame_size,
        execution: state.execution,
        dispatch: state.dispatch,
        request_supervisor: state.request_supervisor,
        in_flight: state.in_flight,
        max_in_flight: state.max_in_flight,
        max_in_flight_per_connection: state.max_in_flight_per_connection
      ]

      case Connection.start_link(opts) do
        {:ok, pid} ->
          {:noreply, %{state | connections: MapSet.put(state.connections, pid)}}

        {:error, reason} ->
          state.transport.close(client)
          Logger.error("SafeRPC failed to start a connection: #{inspect(reason)}")
          {:noreply, state}
      end
    end

    def handle_info({:safe_rpc_accept_error, acceptor, reason}, %{acceptor: acceptor} = state) do
      {:stop, {:accept_failed, reason}, state}
    end

    def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
      {:stop, {:acceptor_exited, reason}, state}
    end

    def handle_info({:EXIT, supervisor, reason}, %{request_supervisor: supervisor} = state) do
      {:stop, {:request_supervisor_exited, reason}, state}
    end

    def handle_info({:EXIT, pid, _reason}, state) do
      {:noreply, %{state | connections: MapSet.delete(state.connections, pid)}}
    end

    def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
    def handle_info({_ref, {_status, _headers, _body}}, state), do: {:noreply, state}

    def handle_call({:dispatch, request}, _from, state) do
      {reply, user_state} = Dispatcher.dispatch(request, state.dispatch)
      dispatch = %{state.dispatch | user_state: user_state}
      {:reply, reply, %{state | dispatch: dispatch}}
    end

    def terminate(_reason, state) do
      Process.exit(state.acceptor, :shutdown)
      Process.exit(state.request_supervisor, :shutdown)
      Enum.each(state.connections, &Process.exit(&1, :shutdown))
      state.transport.close(state.listen)
      File.rm(state.socket)
      :ok
    end

    defp accept_loop(owner, transport, listen) do
      case transport.accept(listen, :infinity) do
        {:ok, client} ->
          send(owner, {:safe_rpc_accepted, self(), client})
          accept_loop(owner, transport, listen)

        {:error, :closed} ->
          :ok

        {:error, reason} ->
          send(owner, {:safe_rpc_accept_error, self(), reason})
      end
    end
  end
end
