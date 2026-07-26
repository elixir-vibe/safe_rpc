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
    GenServer.start_link(__MODULE__.Loop, {handler, opts}, name: Keyword.get(opts, :name))
  end

  defmodule Loop do
    use GenServer

    require Logger

    alias SafeRPC.Authorizer.AllowAll
    alias SafeRPC.Capability
    alias SafeRPC.Server.Connection
    alias SafeRPC.Transport.Unix

    def init({handler, opts}) do
      Process.flag(:trap_exit, true)
      transport = Keyword.get(opts, :transport, Unix)
      socket = Keyword.fetch!(opts, :socket)

      with {:ok, user_state} <- handler.init(opts),
           {:ok, listen} <- transport.listen(opts) do
        owner = self()
        acceptor = spawn_link(fn -> accept_loop(owner, transport, listen) end)

        state = %{
          handler: handler,
          socket: socket,
          listen: listen,
          transport: transport,
          user_state: user_state,
          capability: Keyword.get(opts, :capability),
          authorizer: Keyword.get(opts, :authorizer, AllowAll),
          auth_context: Keyword.get(opts, :auth_context),
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
        max_frame_size: state.max_frame_size
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

    def handle_info({:EXIT, pid, _reason}, state) do
      {:noreply, %{state | connections: MapSet.delete(state.connections, pid)}}
    end

    def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
    def handle_info({_ref, {_status, _headers, _body}}, state), do: {:noreply, state}

    def handle_call({:dispatch, request}, _from, state) do
      {reply, user_state} = dispatch(request, state)
      {:reply, reply, %{state | user_state: user_state}}
    end

    def terminate(_reason, state) do
      Process.exit(state.acceptor, :shutdown)
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

    defp dispatch(request, state) do
      try do
        with :ok <- authorize_capability(request, state.capability),
             :ok <- state.authorizer.authorize(request, state.auth_context) do
          invoke(request, state)
        else
          {:error, reason} -> {{:error, reason}, state.user_state}
        end
      catch
        kind, reason ->
          Logger.error(fn ->
            banner = Exception.format_banner(kind, reason, __STACKTRACE__)
            "SafeRPC request failed op=#{inspect(request.op)}: #{banner}"
          end)

          {{:error, :internal}, state.user_state}
      end
    end

    defp authorize_capability(_request, nil), do: :ok

    defp authorize_capability(request, capability) do
      if Capability.allowed?(capability, request.cap, request.op) do
        :ok
      else
        {:error, :unauthorized}
      end
    end

    defp invoke(request, state) do
      case state.handler.handle_request(request, state.user_state) do
        {:reply, reply, user_state} -> {reply, user_state}
      end
    end
  end
end
