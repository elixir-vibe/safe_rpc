defmodule SafeRPC.Adapter.HTTP.Response do
  @moduledoc "Framework-neutral HTTP response envelope for SafeRPC adapters."

  @type body :: :empty | {:full, iodata()}
  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{status: pos_integer(), headers: [header()], body: body()}

  defstruct [:status, headers: [], body: :empty]

  def text(status, body, headers \\ []) do
    %__MODULE__{status: status, headers: headers, body: {:full, body}}
  end
end
