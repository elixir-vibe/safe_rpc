defmodule SafeRPC.Adapter.Service do
  @moduledoc "Framework-agnostic service behaviour for SafeRPC adapters."

  @callback init(keyword()) :: {:ok, term()} | {:stop, term()}
  @callback call(atom(), term(), map(), term()) :: {:ok, term()} | {:error, term()}
  @callback __safe_rpc_describe__(term()) :: SafeRPC.Descriptor.t() | {:error, term()}

  @optional_callbacks __safe_rpc_describe__: 1
end
