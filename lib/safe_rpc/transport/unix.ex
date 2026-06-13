defmodule SafeRPC.Transport.Unix do
  @moduledoc "Unix domain socket transport for SafeRPC."

  @behaviour SafeRPC.Transport

  @socket_opts [:binary, active: false, packet: 4]

  @impl true
  def connect(opts) do
    socket = Keyword.fetch!(opts, :socket)
    timeout = Keyword.get(opts, :connect_timeout, 5_000)
    :gen_tcp.connect({:local, socket}, 0, @socket_opts, timeout)
  end

  @impl true
  def listen(opts) do
    socket = Keyword.fetch!(opts, :socket)
    File.rm(socket)
    File.mkdir_p!(Path.dirname(socket))
    :gen_tcp.listen(0, @socket_opts ++ [ifaddr: {:local, socket}])
  end

  @impl true
  def accept(listen, timeout), do: :gen_tcp.accept(listen, timeout)

  @impl true
  def send(socket, binary, _timeout), do: :gen_tcp.send(socket, binary)

  @impl true
  def recv(socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  @impl true
  def close(socket) do
    :gen_tcp.close(socket)
    :ok
  end
end
