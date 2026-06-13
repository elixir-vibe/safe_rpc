defmodule SafeRPC.Adapter.HTTP.Request do
  @moduledoc "Framework-neutral HTTP request envelope for SafeRPC adapters."

  defstruct [
    :method,
    :scheme,
    :host,
    :port,
    :path,
    query: "",
    headers: [],
    body: :empty,
    remote_ip: nil
  ]
end
