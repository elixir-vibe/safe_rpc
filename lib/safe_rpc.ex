defmodule SafeRPC do
  @moduledoc "GenServer-like RPC over Erlang external term format for explicit, capability-scoped APIs."

  alias SafeRPC.Client

  defdelegate call(socket, op, payload \\ %{}, opts \\ []), to: Client
  defdelegate cast(socket, op, payload \\ %{}, opts \\ []), to: Client
end
