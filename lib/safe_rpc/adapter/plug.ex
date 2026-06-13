defmodule SafeRPC.Adapter.Plug do
  @moduledoc "Adapter from SafeRPC HTTP envelopes to Plug endpoints."

  alias Plug.Conn
  alias SafeRPC.Adapter.HTTP.{Request, Response}

  defmacro __using__(opts) do
    plug = Keyword.fetch!(opts, :plug)

    quote do
      use SafeRPC.Server

      def start_link(opts) do
        opts = Keyword.put_new(opts, :plug, unquote(plug))
        SafeRPC.Server.start_link(__MODULE__, opts)
      end

      @impl true
      def init(opts), do: SafeRPC.Adapter.Plug.Service.init(opts)

      @impl true
      def handle_call(op, payload, state) do
        {:reply, SafeRPC.Adapter.Plug.Service.call(op, payload, %{}, state), state}
      end

      @impl true
      def handle_request(%{kind: :call, op: op, payload: payload, meta: meta}, state) do
        {:reply, SafeRPC.Adapter.Plug.Service.call(op, payload, meta, state), state}
      end
    end
  end

  @spec call(Request.t(), module(), keyword()) :: Response.t()
  def call(%Request{} = request, plug, opts \\ []) do
    plug_opts = plug.init(Keyword.get(opts, :plug_opts, []))

    request
    |> conn_from_request()
    |> plug.call(plug_opts)
    |> response_from_conn()
  end

  defp conn_from_request(%Request{} = request) do
    body = request_body(request.body)
    path = path_with_query(request)

    request.method
    |> Plug.Test.conn(path, body)
    |> put_headers(request.headers)
    |> Map.put(:scheme, scheme(request.scheme))
    |> Map.put(:host, request.host)
    |> Map.put(:port, request.port)
    |> put_remote_ip(request.remote_ip)
  end

  defp response_from_conn(%Conn{} = conn) do
    %Response{
      status: conn.status || 200,
      headers: conn.resp_headers,
      body: {:full, conn.resp_body || <<>>}
    }
  end

  defp request_body(:empty), do: <<>>
  defp request_body({:full, body}), do: body

  defp path_with_query(%Request{path: path, query: query}) when query in [nil, "", <<>>], do: path
  defp path_with_query(%Request{path: path, query: query}), do: path <> "?" <> query

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_header(conn, String.downcase(to_string(name)), to_string(value))
    end)
  end

  defp put_header(conn, "host", _value), do: conn
  defp put_header(conn, name, value), do: Conn.put_req_header(conn, name, value)

  defp scheme("http"), do: :http
  defp scheme("https"), do: :https

  defp put_remote_ip(conn, nil), do: conn
  defp put_remote_ip(conn, remote_ip), do: Map.put(conn, :remote_ip, remote_ip)
end
