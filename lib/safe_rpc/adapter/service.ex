defmodule SafeRPC.Adapter.Service do
  @moduledoc "Framework-agnostic service behaviour for SafeRPC adapters."

  @callback init(keyword()) :: {:ok, term()} | {:stop, term()}
  @callback call(atom(), term(), map(), term()) :: {:ok, term()} | {:error, term()}
  @callback describe(term()) :: SafeRPC.Descriptor.t() | {:error, term()}

  @optional_callbacks describe: 1
end
