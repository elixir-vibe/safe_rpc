defmodule SafeRPC.PlugAdapterTest do
  use ExUnit.Case, async: true

  alias SafeRPC.Adapter.HTTP.{Request, Response}

  defmodule Router do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/hello" do
      send_resp(conn, 200, "hello #{conn.host}")
    end

    post "/echo" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send_resp(conn, 201, body)
    end
  end

  defmodule RPCServer do
    use SafeRPC.Adapter.Plug, plug: Router
  end

  test "calls a Plug endpoint from an HTTP envelope" do
    request = %Request{
      method: "GET",
      scheme: "https",
      host: "example.com",
      port: 443,
      path: "/hello"
    }

    assert %Response{status: 200, body: {:full, "hello example.com"}} =
             SafeRPC.Adapter.Plug.call(request, Router)
  end

  test "serves a Plug endpoint over SafeRPC" do
    socket = socket_path("plug")
    {:ok, server} = RPCServer.start_link(socket: socket)

    request = %Request{
      method: "POST",
      scheme: "http",
      host: "example.com",
      port: 80,
      path: "/echo",
      body: {:full, "payload"}
    }

    assert {:ok, %Response{status: 201, body: {:full, "payload"}}} =
             SafeRPC.call(socket, :http_request, request)

    GenServer.stop(server)
  end

  defp socket_path(name) do
    Path.join(
      System.tmp_dir!(),
      "safe-rpc-plug-#{name}-#{System.unique_integer([:positive])}.sock"
    )
  end
end
