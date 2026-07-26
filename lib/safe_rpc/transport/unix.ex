defmodule SafeRPC.Transport.Unix do
  @moduledoc "Unix domain socket transport for SafeRPC."

  @behaviour SafeRPC.Transport

  alias SafeRPC.Protocol

  @base_socket_opts [:binary, active: false, packet: 4]

  @impl true
  def connect(opts) do
    socket = Keyword.fetch!(opts, :socket)
    timeout = Keyword.get(opts, :connect_timeout, 5_000)
    :gen_tcp.connect({:local, socket}, 0, socket_opts(opts), timeout)
  end

  @impl true
  def listen(opts) do
    socket = Keyword.fetch!(opts, :socket)
    File.rm(socket)
    File.mkdir_p!(Path.dirname(socket))

    with {:ok, listen} <-
           :gen_tcp.listen(0, socket_opts(opts) ++ [ifaddr: {:local, socket}]),
         :ok <- chmod_socket(socket, Keyword.get(opts, :socket_mode)) do
      {:ok, listen}
    end
  end

  defp socket_opts(opts) do
    max_frame_size = Keyword.get(opts, :max_frame_size, Protocol.default_max_frame_size())
    @base_socket_opts ++ [packet_size: max_frame_size]
  end

  defp chmod_socket(_socket, nil), do: :ok
  defp chmod_socket(socket, mode) when is_integer(mode), do: File.chmod(socket, mode)

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
