defmodule SafeRPC.Server.Connection do
  @moduledoc "Per-client SafeRPC server connection loop."

  use GenServer

  alias SafeRPC.Protocol
  alias SafeRPC.Server.Dispatcher

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
      max_frame_size:
        Keyword.get(opts, :max_frame_size, SafeRPC.Protocol.default_max_frame_size()),
      execution: Keyword.fetch!(opts, :execution),
      dispatch: Keyword.fetch!(opts, :dispatch),
      request_supervisor: Keyword.fetch!(opts, :request_supervisor),
      in_flight: Keyword.fetch!(opts, :in_flight),
      max_in_flight: Keyword.fetch!(opts, :max_in_flight),
      max_in_flight_per_connection: Keyword.fetch!(opts, :max_in_flight_per_connection),
      started_at: System.monotonic_time(),
      receiver: spawn_link(fn -> recv_loop(owner, transport, socket) end),
      workers: %{}
    }

    :telemetry.execute(
      [:safe_rpc, :connection, :start],
      %{system_time: System.system_time()},
      %{execution: state.execution, transport: state.transport}
    )

    {:ok, state}
  end

  @impl true
  def handle_info({:safe_rpc_payload, payload}, state) do
    case handle_payload(payload, state) do
      {:ok, state} ->
        send(state.receiver, {:safe_rpc_receive_next, self()})
        {:noreply, state}

      {:stop, reason, state} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:safe_rpc_closed, :closed}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:safe_rpc_closed, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info({:reply, id, reply}, state) do
    state = remove_worker(id, state)
    encoded = Protocol.encode_reply(id, reply)

    with :ok <- Protocol.validate_frame_size(encoded, state.max_frame_size),
         :ok <- state.transport.send(state.socket, encoded, state.recv_timeout) do
      {:noreply, state}
    else
      {:error, :closed} -> {:stop, :normal, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {id, state} = remove_worker_by_pid(pid, state)

    if id && reason != :normal do
      send(self(), {:reply, id, {:error, :internal}})
    end

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:safe_rpc, :connection, :stop],
      %{duration: System.monotonic_time() - state.started_at},
      %{
        execution: state.execution,
        transport: state.transport,
        reason: normalize_stop_reason(reason)
      }
    )

    Enum.each(state.workers, fn {_id, %{pid: pid}} -> Process.exit(pid, :kill) end)
    :atomics.sub(state.in_flight, 1, map_size(state.workers))
    state.transport.close(state.socket)
    :ok
  end

  defp recv_loop(owner, transport, socket) do
    case transport.recv(socket, :infinity) do
      {:ok, payload} ->
        send(owner, {:safe_rpc_payload, payload})

        receive do
          {:safe_rpc_receive_next, ^owner} -> recv_loop(owner, transport, socket)
        end

      {:error, reason} ->
        send(owner, {:safe_rpc_closed, normalize_close_reason(reason)})
    end
  end

  defp normalize_close_reason(:closed), do: :closed
  defp normalize_close_reason(:enotconn), do: :closed
  defp normalize_close_reason(:einval), do: :closed
  defp normalize_close_reason(reason), do: reason

  defp normalize_stop_reason(:normal), do: :normal
  defp normalize_stop_reason(:shutdown), do: :shutdown
  defp normalize_stop_reason({:shutdown, _reason}), do: :shutdown
  defp normalize_stop_reason(_reason), do: :error

  defp handle_payload(payload, state) do
    case Protocol.decode_request(payload) do
      {:ok, %{kind: :cancel, id: id}} ->
        {:ok, cancel_worker(id, state)}

      {:ok, request} ->
        if Map.has_key?(state.workers, request.id) do
          {:stop, :duplicate_request_id, state}
        else
          {:ok, start_worker(request, state)}
        end

      {:error, reason} ->
        {:stop, {:protocol_error, reason}, state}
    end
  end

  defp start_worker(request, state) do
    if map_size(state.workers) >= state.max_in_flight_per_connection or
         not acquire_slot(state.in_flight, state.max_in_flight) do
      send(self(), {:reply, request.id, {:error, :resource_exhausted}})
      state
    else
      connection = self()

      case Task.Supervisor.start_child(state.request_supervisor, fn ->
             reply = dispatch(request, state)
             send(connection, {:reply, request.id, reply})
           end) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          put_in(state.workers[request.id], %{pid: pid, ref: ref})

        {:error, _reason} ->
          :atomics.sub(state.in_flight, 1, 1)
          send(self(), {:reply, request.id, {:error, :unavailable}})
          state
      end
    end
  end

  defp dispatch(request, %{execution: :serial, owner: owner}) do
    GenServer.call(owner, {:dispatch, request}, :infinity)
  end

  defp dispatch(request, %{execution: :concurrent, dispatch: config}) do
    {reply, _user_state} = Dispatcher.dispatch(request, config)
    reply
  end

  defp acquire_slot(counter, limit) do
    current = :atomics.get(counter, 1)

    cond do
      current >= limit -> false
      :atomics.compare_exchange(counter, 1, current, current + 1) == :ok -> true
      true -> acquire_slot(counter, limit)
    end
  end

  defp cancel_worker(id, state) do
    case Map.fetch(state.workers, id) do
      {:ok, %{pid: pid, ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        :atomics.sub(state.in_flight, 1, 1)
        update_in(state.workers, &Map.delete(&1, id))

      :error ->
        state
    end
  end

  defp remove_worker(id, state) when not is_pid(id) do
    case Map.fetch(state.workers, id) do
      {:ok, %{ref: ref}} ->
        Process.demonitor(ref, [:flush])
        :atomics.sub(state.in_flight, 1, 1)

      :error ->
        :ok
    end

    update_in(state.workers, &Map.delete(&1, id))
  end

  defp remove_worker_by_pid(pid, state) do
    {id, _worker} =
      Enum.find(state.workers, {nil, nil}, fn {_id, worker} -> worker.pid == pid end)

    if id do
      :atomics.sub(state.in_flight, 1, 1)
      {id, update_in(state.workers, &Map.delete(&1, id))}
    else
      {nil, state}
    end
  end
end
