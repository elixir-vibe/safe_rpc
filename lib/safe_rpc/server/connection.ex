defmodule SafeRPC.Server.Connection do
  @moduledoc "Per-client SafeRPC server connection loop."

  use GenServer

  alias SafeRPC.Protocol

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      transport: Keyword.fetch!(opts, :transport),
      socket: Keyword.fetch!(opts, :socket),
      recv_timeout: Keyword.get(opts, :recv_timeout, 5_000)
    }

    send(self(), :recv)
    {:ok, state}
  end

  @impl true
  def handle_info(:recv, state) do
    case state.transport.recv(state.socket, state.recv_timeout) do
      {:ok, payload} ->
        handle_payload(payload, state)
        send(self(), :recv)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.transport.close(state.socket)
    :ok
  end

  defp handle_payload(payload, state) do
    case Protocol.decode_request(payload) do
      {:ok, request} ->
        owner = state.owner
        transport = state.transport
        socket = state.socket
        timeout = state.recv_timeout

        {:ok, _pid} =
          Task.start(fn ->
            reply = GenServer.call(owner, {:dispatch, request}, :infinity)
            transport.send(socket, Protocol.encode_reply(request.id, reply), timeout)
          end)

      {:error, _reason} ->
        :ok
    end
  end
end
