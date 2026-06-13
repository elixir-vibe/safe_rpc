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

      def handle_cast(op, payload, state), do: {:noreply, state}
      defoverridable handle_cast: 3
    end
  end

  def start_link(handler, opts) do
    GenServer.start_link(__MODULE__.Loop, {handler, opts}, name: Keyword.get(opts, :name))
  end

  defmodule Loop do
    use GenServer

    alias SafeRPC.{Capability, Protocol}

    def init({handler, opts}) do
      socket = Keyword.fetch!(opts, :socket)
      File.rm(socket)
      File.mkdir_p!(Path.dirname(socket))

      with {:ok, user_state} <- handler.init(opts),
           {:ok, listen} <-
             :gen_tcp.listen(0, [:binary, active: false, packet: 4, ifaddr: {:local, socket}]) do
        state = %{
          handler: handler,
          socket: socket,
          listen: listen,
          user_state: user_state,
          capability: Keyword.get(opts, :capability)
        }

        send(self(), :accept)
        {:ok, state}
      end
    end

    def handle_info(:accept, state) do
      case :gen_tcp.accept(state.listen, 0) do
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
      {:ok, payload} = :gen_tcp.recv(client, 0, 5_000)
      {:ok, request} = Protocol.decode_request(payload)
      {reply, user_state} = dispatch(request, state)
      :ok = :gen_tcp.send(client, Protocol.encode_reply(request.id, reply))
      :gen_tcp.close(client)
      {:noreply, %{state | user_state: user_state}}
    end

    def terminate(_reason, state) do
      :gen_tcp.close(state.listen)
      File.rm(state.socket)
      :ok
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
