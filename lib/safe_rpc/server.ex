defmodule SafeRPC.Server do
  @moduledoc "GenServer-like Unix socket server for explicit SafeRPC APIs."

  @callback init(keyword()) :: {:ok, term()} | {:stop, term()}
  @callback handle_call(atom(), term(), term()) :: {:reply, term(), term()}
  @callback handle_cast(atom(), term(), term()) :: {:noreply, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour SafeRPC.Server

      def start_link(opts) do
        SafeRPC.Server.start_link(__MODULE__, opts)
      end

      def handle_cast(_op, _payload, state), do: {:noreply, state}
      defoverridable handle_cast: 3
    end
  end

  def start_link(handler, opts) do
    GenServer.start_link(__MODULE__.Loop, {handler, opts}, name: Keyword.get(opts, :name))
  end

  defmodule Loop do
    use GenServer

    alias SafeRPC.{Capability, Protocol}
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
          recv_timeout: Keyword.get(opts, :recv_timeout, 5_000)
        }

        send(self(), :accept)
        {:ok, state}
      end
    end

    def handle_info(:accept, state) do
      case state.transport.accept(state.listen, 0) do
        {:ok, client} ->
          GenServer.cast(self(), {:serve, client})
          send(self(), :accept)
          {:noreply, state}

        {:error, :timeout} ->
          send(self(), :accept)
          {:noreply, state}

        {:error, reason} ->
          {:stop, reason, state}
      end
    end

    def handle_cast({:serve, client}, state) do
      {_reply, user_state} = receive_and_dispatch(client, state)
      state.transport.close(client)
      {:noreply, %{state | user_state: user_state}}
    end

    def terminate(_reason, state) do
      state.transport.close(state.listen)
      File.rm(state.socket)
      :ok
    end

    defp receive_and_dispatch(client, state) do
      with {:ok, payload} <- state.transport.recv(client, state.recv_timeout),
           {:ok, request} <- Protocol.decode_request(payload) do
        {reply, user_state} = dispatch(request, state)

        :ok =
          state.transport.send(
            client,
            Protocol.encode_reply(request.id, reply),
            state.recv_timeout
          )

        {reply, user_state}
      else
        {:error, reason} ->
          {{:error, reason}, state.user_state}
      end
    end

    defp dispatch(request, state) do
      if authorized?(request, state.capability) do
        invoke(request, state)
      else
        {{:error, :unauthorized}, state.user_state}
      end
    end

    defp authorized?(_request, nil), do: true

    defp authorized?(request, capability),
      do: Capability.allowed?(capability, request.cap, request.op)

    defp invoke(%{kind: :call} = request, state) do
      case state.handler.handle_call(request.op, request.payload, state.user_state) do
        {:reply, reply, user_state} -> {reply, user_state}
      end
    end

    defp invoke(%{kind: :cast} = request, state) do
      case state.handler.handle_cast(request.op, request.payload, state.user_state) do
        {:noreply, user_state} -> {{:ok, :noreply}, user_state}
      end
    end
  end
end
