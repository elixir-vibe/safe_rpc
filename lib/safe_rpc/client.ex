defmodule SafeRPC.Client do
  @moduledoc "One-request-per-connection Unix socket SafeRPC client."

  alias SafeRPC.Protocol

  def call(socket, op, payload \\ %{}, opts \\ []) do
    id = make_ref()
    cap = Keyword.get(opts, :cap)
    request(socket, Protocol.encode_call(id, cap, op, payload), id, opts)
  end

  def cast(socket, op, payload \\ %{}, opts \\ []) do
    id = make_ref()
    cap = Keyword.get(opts, :cap)
    request(socket, Protocol.encode_cast(id, cap, op, payload), id, opts)
  end

  defp request(socket, encoded, id, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, port} <-
           :gen_tcp.connect({:local, socket}, 0, [:binary, active: false, packet: 4], timeout),
         :ok <- :gen_tcp.send(port, encoded),
         {:ok, response} <- :gen_tcp.recv(port, 0, timeout),
         :ok <- :gen_tcp.close(port),
         {:ok, result} <- Protocol.decode_reply(response, id) do
      result
    end
  end
end
