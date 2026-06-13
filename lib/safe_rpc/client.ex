defmodule SafeRPC.Client do
  @moduledoc "SafeRPC client process and one-shot client helpers."

  use GenServer

  alias SafeRPC.Protocol
  alias SafeRPC.Transport.Unix

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  def call(client, op), do: call(client, op, %{}, [])
  def call(client, op, payload), do: call(client, op, payload, [])

  def call(client, op, payload, opts) when is_pid(client) or is_atom(client) do
    GenServer.call(
      client,
      {:request, :call, op, payload, opts},
      Keyword.get(opts, :timeout, 5_000) + 1_000
    )
  end

  def call(socket, op, payload, opts) when is_binary(socket) do
    request(socket, :call, op, payload, opts)
  end

  def cast(client, op), do: cast(client, op, %{}, [])
  def cast(client, op, payload), do: cast(client, op, payload, [])

  def cast(client, op, payload, opts) when is_pid(client) or is_atom(client) do
    GenServer.call(
      client,
      {:request, :cast, op, payload, opts},
      Keyword.get(opts, :timeout, 5_000) + 1_000
    )
  end

  def cast(socket, op, payload, opts) when is_binary(socket) do
    request(socket, :cast, op, payload, opts)
  end

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, Unix)

    with {:ok, socket} <- transport.connect(opts) do
      {:ok, %{transport: transport, socket: socket, opts: opts, cap: Keyword.get(opts, :cap)}}
    end
  end

  @impl true
  def handle_call({:request, kind, op, payload, opts}, _from, state) do
    cap = Keyword.get(opts, :cap, state.cap)
    timeout = Keyword.get(opts, :timeout, 5_000)
    {result, state} = request_with_reconnect(state, kind, op, payload, cap, timeout)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    state.transport.close(state.socket)
    :ok
  end

  defp request_with_reconnect(state, kind, op, payload, cap, timeout) do
    case send_request(state.transport, state.socket, kind, op, payload, cap, timeout) do
      {:error, reason} when reason in [:closed, :einval, :enotconn] ->
        state.transport.close(state.socket)

        with {:ok, socket} <- state.transport.connect(state.opts) do
          result = send_request(state.transport, socket, kind, op, payload, cap, timeout)
          {result, %{state | socket: socket}}
        else
          error -> {error, state}
        end

      result ->
        {result, state}
    end
  end

  defp request(socket, kind, op, payload, opts) do
    transport = Keyword.get(opts, :transport, Unix)
    timeout = Keyword.get(opts, :timeout, 5_000)
    cap = Keyword.get(opts, :cap)

    with {:ok, port} <- transport.connect(Keyword.put(opts, :socket, socket)),
         result <- send_request(transport, port, kind, op, payload, cap, timeout),
         :ok <- transport.close(port) do
      result
    end
  end

  defp send_request(transport, socket, kind, op, payload, cap, timeout) do
    id = make_ref()
    encoded = encode(kind, id, cap, op, payload)

    with :ok <- transport.send(socket, encoded, timeout),
         {:ok, response} <- transport.recv(socket, timeout),
         {:ok, result} <- Protocol.decode_reply(response, id) do
      result
    end
  end

  defp encode(:call, id, cap, op, payload), do: Protocol.encode_call(id, cap, op, payload)
  defp encode(:cast, id, cap, op, payload), do: Protocol.encode_cast(id, cap, op, payload)
end
