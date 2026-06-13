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

      def handle_cast(_op, _payload, state), do: {:noreply, state}

      def handle_request(%{kind: :call, op: op, payload: payload}, state) do
        handle_call(op, payload, state)
      end

      def handle_request(%{kind: :cast, op: op, payload: payload}, state) do
        case handle_cast(op, payload, state) do
          {:noreply, state} -> {:reply, {:ok, :noreply}, state}
        end
      end

      defoverridable handle_cast: 3, handle_request: 2
    end
  end

  def start_link(handler, opts) do
    GenServer.start_link(__MODULE__.Loop, {handler, opts}, name: Keyword.get(opts, :name))
  end

  defmodule Loop do
    use GenServer

    alias SafeRPC.Authorizer.AllowAll
    alias SafeRPC.Capability
    alias SafeRPC.Server.Connection
    alias SafeRPC.Transport.Unix

    def init({handler, opts}) do
      transport = Keyword.get(opts, :transport, Unix)
      socket = Keyword.fetch!(opts, :socket)

      with {:ok, user_state} <- handler.init(opts),
           {:ok, listen} <- transport.listen(opts) do
        state = %{
          handler: handler,
          socket: socket,
          listen: listen,
          transport: transport,
          user_state: user_state,
          capability: Keyword.get(opts, :capability),
          authorizer: Keyword.get(opts, :authorizer, AllowAll),
          auth_context: Keyword.get(opts, :auth_context),
          recv_timeout: Keyword.get(opts, :recv_timeout, 5_000)
        }

        send(self(), :accept)
        {:ok, state}
      end
    end

    def handle_info(:accept, state) do
      case state.transport.accept(state.listen, 0) do
        {:ok, client} ->
          {:ok, _pid} =
            Connection.start_link(
              owner: self(),
              transport: state.transport,
              socket: client,
              recv_timeout: state.recv_timeout
            )

          send(self(), :accept)
          {:noreply, state}

        {:error, :timeout} ->
          send(self(), :accept)
          {:noreply, state}

        {:error, reason} ->
          {:stop, reason, state}
      end
    end

    def handle_call({:dispatch, request}, _from, state) do
      {reply, user_state} = dispatch(request, state)
      {:reply, reply, %{state | user_state: user_state}}
    end

    def terminate(_reason, state) do
      state.transport.close(state.listen)
      File.rm(state.socket)
      :ok
    end

    defp dispatch(request, state) do
      with :ok <- authorize_capability(request, state.capability),
           :ok <- state.authorizer.authorize(request, state.auth_context) do
        invoke(request, state)
      else
        {:error, reason} -> {{:error, reason}, state.user_state}
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
