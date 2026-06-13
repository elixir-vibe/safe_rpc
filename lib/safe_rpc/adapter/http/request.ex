defmodule SafeRPC.Adapter.HTTP.Request do
  @moduledoc "Framework-neutral HTTP request envelope for SafeRPC adapters."

  @type body :: :empty | {:full, iodata()}
  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          method: String.t(),
          scheme: String.t(),
          host: String.t(),
          port: pos_integer(),
          path: String.t(),
          query: String.t(),
          headers: [header()],
          body: body(),
          remote_ip: :inet.ip_address() | nil
        }

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
