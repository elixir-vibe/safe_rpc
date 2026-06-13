defmodule SafeRPC.Adapter.HTTP.Response do
  @moduledoc "Framework-neutral HTTP response envelope for SafeRPC adapters."

  defstruct [:status, headers: [], body: :empty]

  def text(status, body, headers \\ []) do
    %__MODULE__{status: status, headers: headers, body: {:full, body}}
  end
end
