defmodule SafeRPC.Client do
  @moduledoc "SafeRPC client process and one-shot client helpers."

  use GenServer

  alias SafeRPC.Protocol
  alias SafeRPC.Transport.Unix

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def call(client, op), do: call(client, op, %{}, [])
  def call(client, op, payload), do: call(client, op, payload, [])

  def call(client, op, payload, opts) when is_pid(client) or is_atom(client) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(client, {:request, :call, op, payload, opts}, timeout + 1_000)
  end

  def call(socket, op, payload, opts) when is_binary(socket) do
    request(socket, :call, op, payload, opts)
  end

  def cast(client, op), do: cast(client, op, %{}, [])
  def cast(client, op, payload), do: cast(client, op, payload, [])

  def cast(client, op, payload, opts) when is_pid(client) or is_atom(client) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(client, {:request, :cast, op, payload, opts}, timeout + 1_000)
  end

  def cast(socket, op, payload, opts) when is_binary(socket) do
    request(socket, :cast, op, payload, opts)
  end

  def send_request(client, op, payload \\ %{}, opts \\ [])
      when is_pid(client) or is_atom(client) do
    GenServer.call(client, {:send_request, :call, op, payload, opts})
  end

  def cancel(%SafeRPC.Task{client: client, id: id}) do
    GenServer.call(client, {:cancel, id})
  end

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, Unix)

    with {:ok, socket} <- transport.connect(opts) do
      state = %{
        transport: transport,
        socket: socket,
        opts: opts,
        cap: Keyword.get(opts, :cap),
        pending: %{}
      }

      owner = self()
      receiver = spawn_link(fn -> recv_loop(owner, transport, socket) end)
      {:ok, Map.put(state, :receiver, receiver)}
    end
  end

  @impl true
  def handle_call({:request, kind, op, payload, opts}, from, state) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    {id, state} = put_pending(from, op, timeout, state)

    case send_frame(state, kind, id, op, payload, opts) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        {pending, state} = pop_pending(id, state)
        reply(pending.from, {:error, reason})
        {:noreply, state}
    end
  end

  def handle_call({:cancel, id}, _from, state) do
    case state.transport.send(state.socket, Protocol.encode_cancel(id), 5_000) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:send_request, kind, op, payload, opts}, {caller, _tag}, state) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    {id, state} = put_pending({:message, caller, :pending_id}, op, timeout, state)
    state = put_in(state.pending[id].from, {:message, caller, id})

    case send_frame(state, kind, id, op, payload, opts) do
      {:ok, state} ->
        {:reply, {:ok, %SafeRPC.Task{client: self(), id: id, op: op}}, state}

      {:error, reason, state} ->
        {_pending, state} = pop_pending(id, state)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:safe_rpc_reply, payload}, state) do
    {:noreply, handle_reply(payload, state)}
  end

  def handle_info({:safe_rpc_closed, :closed}, state) do
    state = fail_pending(:closed, state)
    {:stop, :normal, state}
  end

  def handle_info({:safe_rpc_closed, reason}, state) do
    state = fail_pending(reason, state)
    {:stop, reason, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case pop_pending(id, state) do
      {nil, state} ->
        {:noreply, state}

      {pending, state} ->
        reply(pending.from, {:error, :timeout})
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.transport.close(state.socket)
    :ok
  end

  defp recv_loop(owner, transport, socket) do
    case transport.recv(socket, :infinity) do
      {:ok, payload} ->
        send(owner, {:safe_rpc_reply, payload})
        recv_loop(owner, transport, socket)

      {:error, reason} ->
        send(owner, {:safe_rpc_closed, reason})
    end
  end

  defp put_pending(from, op, timeout, state) do
    id = make_ref()
    timer = Process.send_after(self(), {:request_timeout, id}, timeout)
    pending = %{from: from, op: op, timer: timer}
    {id, %{state | pending: Map.put(state.pending, id, pending)}}
  end

  defp pop_pending(id, state) do
    {pending, pending_map} = Map.pop(state.pending, id)

    if pending do
      Process.cancel_timer(pending.timer)
    end

    {pending, %{state | pending: pending_map}}
  end

  defp send_frame(state, kind, id, op, payload, opts) do
    cap = Keyword.get(opts, :cap, state.cap)
    meta = Keyword.get(opts, :meta, %{})
    encoded = encode(kind, id, cap, op, payload, meta)

    case state.transport.send(state.socket, encoded, Keyword.get(opts, :timeout, 5_000)) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_reply(payload, state) do
    with {:ok, %{id: id, result: result}} <- Protocol.decode_reply(payload),
         {pending, state} when not is_nil(pending) <- pop_pending(id, state) do
      reply(pending.from, result)
      state
    else
      _error -> state
    end
  end

  defp reply({:message, caller, id}, result), do: send(caller, {SafeRPC.Task, id, result})
  defp reply({:message, caller}, result), do: send(caller, {SafeRPC.Task, result})
  defp reply(from, result), do: GenServer.reply(from, result)

  defp fail_pending(reason, state) do
    Enum.each(state.pending, fn {_id, pending} -> reply(pending.from, {:error, reason}) end)
    %{state | pending: %{}}
  end

  defp request(socket, kind, op, payload, opts) do
    transport = Keyword.get(opts, :transport, Unix)
    timeout = Keyword.get(opts, :timeout, 5_000)
    cap = Keyword.get(opts, :cap)
    meta = Keyword.get(opts, :meta, %{})

    with {:ok, port} <- transport.connect(Keyword.put(opts, :socket, socket)),
         result <- send_blocking_request(transport, port, kind, op, payload, cap, meta, timeout),
         :ok <- transport.close(port) do
      result
    end
  end

  defp send_blocking_request(transport, socket, kind, op, payload, cap, meta, timeout) do
    id = make_ref()
    encoded = encode(kind, id, cap, op, payload, meta)

    with :ok <- transport.send(socket, encoded, timeout),
         {:ok, response} <- transport.recv(socket, timeout),
         {:ok, result} <- Protocol.decode_reply(response, id) do
      result
    end
  end

  defp encode(:call, id, cap, op, payload, meta),
    do: Protocol.encode_call(id, cap, op, payload, meta)

  defp encode(:cast, id, cap, op, payload, meta),
    do: Protocol.encode_cast(id, cap, op, payload, meta)
end
