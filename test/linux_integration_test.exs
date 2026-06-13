defmodule SafeRPC.LinuxIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias SafeRPC.Adapter.HTTP.{Request, Response}

  defmodule EchoServer do
    use SafeRPC.Server

    def init(_opts), do: {:ok, %{}}
    def handle_call(:echo, payload, state), do: {:reply, {:ok, payload}, state}
  end

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/linux" do
      send_resp(conn, 200, "linux #{conn.host}")
    end
  end

  defmodule PlugServer do
    use SafeRPC.Adapter.Plug, plug: Router
  end

  test "uses Unix sockets on Linux-compatible paths" do
    socket = socket_path("linux")
    {:ok, server} = EchoServer.start_link(socket: socket)
    {:ok, client} = SafeRPC.Client.start_link(socket: socket)

    assert {:ok, :linux} = SafeRPC.call(client, :echo, :linux)
    assert File.exists?(socket)

    GenServer.stop(client)
    GenServer.stop(server)
  end

  test "runs pool and Plug adapter over Unix sockets" do
    socket = socket_path("plug")
    {:ok, server} = PlugServer.start_link(socket: socket)
    {:ok, pool} = SafeRPC.ClientPool.start_link(socket: socket, shards: 4)

    request = %Request{
      method: "GET",
      scheme: "http",
      host: "linux.example",
      port: 80,
      path: "/linux"
    }

    assert {:ok, %Response{status: 200, body: {:full, "linux linux.example"}}} =
             SafeRPC.ClientPool.call(pool, :plug, :http_request, request)

    GenServer.stop(pool)
    GenServer.stop(server)
  end

  defp socket_path(name) do
    base = System.get_env("XDG_RUNTIME_DIR") || System.tmp_dir!()
    Path.join(base, "safe-rpc-integration-#{name}-#{System.unique_integer([:positive])}.sock")
  end
end
