defmodule SafeRPC.Adapter.Plug.Service do
  @moduledoc "SafeRPC adapter service for Plug endpoints."

  @behaviour SafeRPC.Adapter.Service

  alias SafeRPC.Adapter.HTTP.Request

  @impl true
  def init(opts) do
    {:ok, %{plug: Keyword.fetch!(opts, :plug), plug_opts: Keyword.get(opts, :plug_opts, [])}}
  end

  @impl true
  def call(:http_request, %Request{} = request, _meta, state) do
    {:ok, SafeRPC.Adapter.Plug.call(request, state.plug, plug_opts: state.plug_opts)}
  end

  def call(_op, _payload, _meta, _state), do: {:error, :unknown_operation}
end
