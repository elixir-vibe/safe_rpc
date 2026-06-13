defmodule SafeRPC.Adapter.Service do
  @moduledoc "Framework-agnostic service behaviour for SafeRPC adapters."

  @callback init(keyword()) :: {:ok, term()} | {:stop, term()}
  @callback call(atom(), term(), map(), term()) :: {:ok, term()} | {:error, term()}
end
