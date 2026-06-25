defmodule SafeRPC.Server.Connection do
  @moduledoc "Per-client SafeRPC server connection loop."

  use GenServer

  alias SafeRPC.Protocol

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    socket = Keyword.fetch!(opts, :socket)
    owner = self()

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      transport: transport,
      socket: socket,
      recv_timeout: Keyword.get(opts, :recv_timeout, 5_000),
      receiver: spawn_link(fn -> recv_loop(owner, transport, socket) end),
      workers: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:safe_rpc_payload, payload}, state) do
    {:noreply, handle_payload(payload, state)}
  end

  def handle_info({:safe_rpc_closed, :closed}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:safe_rpc_closed, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info({:reply, id, reply}, state) do
    state = remove_worker(id, state)

    case state.transport.send(state.socket, Protocol.encode_reply(id, reply), state.recv_timeout) do
      :ok -> {:noreply, state}
      {:error, :closed} -> {:stop, :normal, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_worker(pid, state)}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.workers, fn {_id, %{pid: pid}} -> Process.exit(pid, :kill) end)
    state.transport.close(state.socket)
    :ok
  end

  defp recv_loop(owner, transport, socket) do
    case transport.recv(socket, :infinity) do
      {:ok, payload} ->
        send(owner, {:safe_rpc_payload, payload})
        recv_loop(owner, transport, socket)

      {:error, reason} ->
        send(owner, {:safe_rpc_closed, normalize_close_reason(reason)})
    end
  end

  defp normalize_close_reason(:closed), do: :closed
  defp normalize_close_reason(:enotconn), do: :closed
  defp normalize_close_reason(:einval), do: :closed
  defp normalize_close_reason(reason), do: reason

  defp handle_payload(payload, state) do
    case Protocol.decode_request(payload) do
      {:ok, %{kind: :cancel, id: id}} -> cancel_worker(id, state)
      {:ok, request} -> start_worker(request, state)
      {:error, _reason} -> state
    end
  end

  defp start_worker(request, state) do
    connection = self()
    owner = state.owner

    {:ok, pid} =
      Task.start(fn ->
        reply = GenServer.call(owner, {:dispatch, request}, :infinity)
        send(connection, {:reply, request.id, reply})
      end)

    ref = Process.monitor(pid)
    put_in(state.workers[request.id], %{pid: pid, ref: ref})
  end

  defp cancel_worker(id, state) do
    case Map.fetch(state.workers, id) do
      {:ok, %{pid: pid, ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        update_in(state.workers, &Map.delete(&1, id))

      :error ->
        state
    end
  end

  defp remove_worker(id, state) when not is_pid(id) do
    case Map.fetch(state.workers, id) do
      {:ok, %{ref: ref}} -> Process.demonitor(ref, [:flush])
      :error -> :ok
    end

    update_in(state.workers, &Map.delete(&1, id))
  end

  defp remove_worker(pid, state) when is_pid(pid) do
    {id, _worker} =
      Enum.find(state.workers, {nil, nil}, fn {_id, worker} -> worker.pid == pid end)

    if id do
      update_in(state.workers, &Map.delete(&1, id))
    else
      state
    end
  end
end
