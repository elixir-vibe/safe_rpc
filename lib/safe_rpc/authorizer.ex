defmodule SafeRPC.Authorizer do
  @moduledoc "Optional authorization hook for SafeRPC requests."

  @callback authorize(map(), term()) :: :ok | {:error, term()}
end
